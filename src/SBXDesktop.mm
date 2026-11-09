// SBXDesktop —— Feature 插件（从 SystemX 拆出的三组桌面功能）
// 钩子与行为对照 SystemX 1.5-8 的逆向结果（见 analysis/systemx_impl_notes.md，47 条真实行为）
//   A. 后台一键清除按钮   B. iPad 卡片后台   C. iPad 悬浮 Dock
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define SBDOMAIN "com.ning.feature"
#define LOGPATH  "/var/mobile/Library/Accessibility/feature.log"
#define kBtnTag  0x53425831
#define kBlurTag 0x53425832

static void SBXLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"MM-dd HH:mm:ss"; });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], msg];
    FILE *fp = fopen(LOGPATH, "a");
    if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
}

#pragma mark - substrate / 反射工具
typedef void (*HookMsgEx_t)(Class, SEL, IMP, IMP *);
typedef void (*HookFunc_t)(void *, void *, void **);
static HookMsgEx_t gHookMsgEx = NULL;
static HookFunc_t  gHookFunc  = NULL;
static void SBXLoadSubstrate(void) {
    if (!gHookMsgEx) gHookMsgEx = (HookMsgEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!gHookFunc)  gHookFunc  = (HookFunc_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
}
static id SBXClassCall(Class c, NSString *name) {
    if (!c) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![c respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, sel);
}
static id SBXIdCall(id o, NSString *name) {
    if (!o) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![o respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, sel);
}
static BOOL SBXBoolCall(id o, NSString *name) {
    if (!o) return NO;
    SEL sel = NSSelectorFromString(name);
    if (![o respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, sel);
}

#pragma mark - 偏好
static id SBXPref(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyValue((__bridge CFStringRef)key, CFSTR(SBDOMAIN),
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return v ? (__bridge_transfer id)v : nil;
}
static BOOL SBXBool(NSString *k, BOOL d) { id v = SBXPref(k); return v ? [v boolValue] : d; }
static double SBXNum(NSString *k, double d, double lo, double hi) {
    id v = SBXPref(k); double n = v ? [v doubleValue] : d;
    if (n != n) n = d;
    return MAX(lo, MIN(hi, n));
}
static BOOL ClearOn(void) { return SBXBool(@"clearButton", NO); }
static BOOL CardsOn(void) { return SBXBool(@"cardSwitcher", NO); }
static BOOL DockOn(void)  { return SBXBool(@"floatingDock", NO); }

#pragma mark - 液态玻璃视图（航的着色器）
typedef struct { vector_float4 viewport, geometry, optical, appearance, tint, innerShadow, misc; } LGUniforms;

@interface LGGlassButtonView : MTKView
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLTexture> bgTex;
@property (nonatomic) CGPoint bgOrigin;
@property (nonatomic) CGSize  bgSize;
@property (nonatomic) float scale;
- (void)setBackdropImage:(UIImage *)img origin:(CGPoint)origin;
@end

@implementation LGGlassButtonView
- (id<MTLLibrary>)lgLibrary:(NSError **)err {
    Dl_info info;
    if (dladdr((__bridge void *)[self class], &info) && info.dli_fname) {
        NSString *dir = [NSString stringWithUTF8String:info.dli_fname].stringByDeletingLastPathComponent;
        for (NSString *rel in @[@"../../share/glassclear/default.metallib",
                                @"../share/glassclear/default.metallib"]) {
            NSString *p = [dir stringByAppendingPathComponent:rel];
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return [self.device newLibraryWithFile:p error:err];
        }
    }
    for (NSString *p in @[@"/var/jb/usr/share/glassclear/default.metallib",
                          @"/usr/share/glassclear/default.metallib"])
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return [self.device newLibraryWithFile:p error:err];
    if (err) *err = [NSError errorWithDomain:@"SBXGlass" code:1 userInfo:@{NSLocalizedDescriptionKey: @"no metallib"}];
    return nil;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) return nil;
    self.device = dev; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO; self.framebufferOnly = NO;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm; self.clearColor = MTLClearColorMake(0,0,0,0);
    self.paused = YES; self.enableSetNeedsDisplay = YES;
    self.queue = [dev newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [self lgLibrary:&err];
    if (!lib) { SBXLog(@"metallib 加载失败：%@", err.localizedDescription); return nil; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"lgGlassVertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"lgGlassFragment"];
    if (!d.vertexFunction || !d.fragmentFunction) { SBXLog(@"着色器函数缺失"); return nil; }
    d.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    self.pipeline = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!self.pipeline) { SBXLog(@"管线创建失败：%@", err.localizedDescription); return nil; }
    SBXLog(@"液态玻璃管线就绪");
    return self;
}
- (void)setBackdropImage:(UIImage *)img origin:(CGPoint)origin {
    CGImageRef cg = img.CGImage; if (!cg) return;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg); if (!w || !h) return;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [self.device newTextureWithDescriptor:td]; if (!tex) return;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    void *buf = calloc(w * h * 4, 1);
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:buf bytesPerRow:w * 4];
        CGContextRelease(ctx);
    }
    free(buf); CGColorSpaceRelease(cs);
    self.bgTex = tex; self.bgSize = CGSizeMake(w, h); self.bgOrigin = origin;
    [self setNeedsDisplay];
}
- (void)layoutSubviews { [super layoutSubviews]; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    if (!self.pipeline || !self.bgTex) return;
    id<CAMetalDrawable> dr = self.currentDrawable;
    MTLRenderPassDescriptor *rp = self.currentRenderPassDescriptor;
    if (!dr || !rp) return;
    float s = self.scale > 0 ? self.scale : 3.0f;
    float w = (float)(self.bounds.size.width * s), h = (float)(self.bounds.size.height * s);
    if (w < 2 || h < 2) return;
    LGUniforms u; memset(&u, 0, sizeof(u));
    u.viewport = (vector_float4){ (float)self.bgSize.width, (float)self.bgSize.height,
                                  (float)self.bgOrigin.x * s, (float)self.bgOrigin.y * s };
    u.geometry = (vector_float4){ w, h, h * 0.5f, MAX(3.0f, MIN(h * 0.34f, 14.0f * s)) };
    u.optical = (vector_float4){ 1.5f * s, 1.52f, 0.95f, 10.0f * s };
    u.appearance = (vector_float4){ 1.00f, 1.22f, 0.12f, 8.0f * s };
    u.tint = (vector_float4){ 1, 1, 1, 1 };
    u.innerShadow = (vector_float4){ 0, 0, 0, 3.0f * s };
    id<MTLCommandBuffer> cb = [self.queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:self.pipeline];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentTexture:self.bgTex atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
    [cb presentDrawable:dr];
    [cb commit];
}
@end

#pragma mark - ============ A. 后台一键清除按钮 ============

static char kButtonKey;
static NSHashTable *gButtons = nil;
static NSUInteger gButtonGeneration = 0;
// 对应 SystemBox 的“本轮已点击/已显示过”状态；viewWillAppear 会重置。
static BOOL gButtonUsed = NO;
static BOOL gButtonShown = NO;

static NSHashTable *SBXButtonTable(void) {
    if (!gButtons) gButtons = [NSHashTable weakObjectsHashTable];
    return gButtons;
}

static UIButton *SBXFindButton(void) {
    for (UIButton *b in [SBXButtonTable() allObjects])
        if (b && b.superview) return b;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [(UIWindowScene *)sc windows]) {
            UIButton *b = (UIButton *)[w viewWithTag:kBtnTag];
            if (b) return b;
        }
    }
    return nil;
}

static void SBXRegisterButton(UIButton *b, id owner) {
    if (!b) return;
    [SBXButtonTable() addObject:b];
    if (owner) objc_setAssociatedObject(owner, &kButtonKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIButton *SBXButtonForOwner(id owner) {
    UIButton *b = owner ? objc_getAssociatedObject(owner, &kButtonKey) : nil;
    if (!b && [owner isKindOfClass:UIViewController.class])
        b = [((UIViewController *)owner).view viewWithTag:kBtnTag];
    if (b) SBXRegisterButton(b, owner);
    return b;
}

static void SBXAttachGlass(UIButton *b, BOOL force);
static BOOL SBXHasAppLayouts(void);   // 前置声明

static void SBXSetButtonVisible(BOOL vis) {
    if (!vis) gButtonGeneration++;
    if (vis && (!ClearOn() || gButtonUsed)) vis = NO;
    gButtonShown = vis;
    NSArray *buttons = [SBXButtonTable() allObjects];
    if (!buttons.count) {
        UIButton *b = SBXFindButton();
        if (b) { SBXRegisterButton(b, nil); buttons = [SBXButtonTable() allObjects]; }
    }
    if (!buttons.count) {
        SBXLog(@"按钮%@（未找到）", vis ? @"显示" : @"隐藏");
        return;
    }
    gButtonShown = vis;
    for (UIButton *b in buttons) {
        if (!b) continue;
        [b.layer removeAllAnimations];
        b.transform = CGAffineTransformIdentity;
        b.alpha = vis ? 1.0 : 0.0;
        b.hidden = !vis;
    }
    SBXLog(@"按钮%@", vis ? @"显示" : @"隐藏");
    if (vis) {
        NSUInteger gen = gButtonGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen != gButtonGeneration || gButtonUsed || !ClearOn()) return;
            for (UIButton *b in [SBXButtonTable() allObjects])
                if (b) SBXAttachGlass(b, YES);
        });
    }
}

static void SBXShowClearButtons(void) {
    if (!ClearOn() || gButtonUsed) return;
    SBXSetButtonVisible(YES);
}

static void SBXScheduleClearButtons(UIView *view, NSTimeInterval delay) {
    if (!ClearOn() || !view || view.window == nil || gButtonUsed) return;
    NSUInteger gen = gButtonGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != gButtonGeneration || view.window == nil || !ClearOn() || gButtonUsed) return;
        SBXShowClearButtons();
    });
}

static void SBXRemoveButton(UIButton *b) {
    if (!b) return;
    gButtonGeneration++;
    gButtonShown = NO;
    [b.layer removeAllAnimations];
    [b removeFromSuperview];
    [SBXButtonTable() removeObject:b];
}

static void SBXRemoveAllButtons(void) {
    gButtonGeneration++;
    gButtonShown = NO;
    for (UIButton *b in [SBXButtonTable() allObjects]) {
        [b.layer removeAllAnimations];
        [b removeFromSuperview];
    }
    [SBXButtonTable() removeAllObjects];
}

// 是否还有后台卡片（没有卡片时不该显示清除按钮）
static BOOL SBXHasAppLayouts(void) {
    id coord = SBXClassCall(NSClassFromString(@"SBMainSwitcherControllerCoordinator"), @"sharedInstanceIfExists");
    if (!coord) return NO;
    for (NSString *sel in @[@"recentAppLayouts", @"appLayouts", @"allItems"]) {
        id v = SBXIdCall(coord, sel);
        if ([v isKindOfClass:NSArray.class] && [v count] > 0) return YES;
    }
    return NO;
}

static BOOL SBXAnySwitcherVisible(void) {
    id coord = SBXClassCall(NSClassFromString(@"SBMainSwitcherControllerCoordinator"), @"sharedInstanceIfExists");
    if (coord && [coord respondsToSelector:NSSelectorFromString(@"isAnySwitcherVisible")])
        return SBXBoolCall(coord, @"isAnySwitcherVisible");
    return YES;
}

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPlaying;
- (id)nowPlayingApplication;
@end

static NSString *SBXNowPlaying(void) {
    Class c = NSClassFromString(@"SBMediaController"); if (!c) return nil;
    id mc = SBXClassCall(c, @"sharedInstance"); if (!mc) return nil;
    if (![(SBMediaController *)mc isPlaying]) return nil;
    id app = [(SBMediaController *)mc nowPlayingApplication]; if (!app) return nil;
    id bid = SBXIdCall(app, @"bundleIdentifier");
    return [bid isKindOfClass:NSString.class] ? bid : nil;
}

static void SBXKillAll(void) {
    gButtonUsed = YES;
    SBXSetButtonVisible(NO);
    id coord = SBXClassCall(NSClassFromString(@"SBMainSwitcherControllerCoordinator"), @"sharedInstanceIfExists");
    if (!coord) coord = SBXClassCall(NSClassFromString(@"SBAppSwitcherController"), @"sharedInstanceIfExists");
    if (!coord) { SBXLog(@"清除：找不到控制器"); return; }
    NSArray *layouts = nil;
    for (NSString *sel in @[@"recentAppLayouts", @"appLayouts", @"allItems"]) {
        id v = SBXIdCall(coord, sel);
        if ([v isKindOfClass:NSArray.class] && [v count]) {
            layouts = v; SBXLog(@"清除：来源=%@ (%lu)", sel, (unsigned long)[v count]); break;
        }
    }
    if (!layouts.count) { SBXLog(@"清除：卡片列表为空"); return; }
    // 诊断：第一张卡片到底有哪些能取 bundle id 的接口
    {
        id first = layouts.firstObject;
        SBXLog(@"诊断：layout 类=%@", NSStringFromClass([first class]));
        for (NSString *sel in @[@"bundleIdentifier", @"primaryDisplayItem", @"allItems",
                                 @"displayItems", @"itemForRole:", @"appLayoutByRole"])
            SBXLog(@"  %@ 响应=%@", sel, [first respondsToSelector:NSSelectorFromString(sel)] ? @"YES" : @"NO");
        id items = SBXIdCall(first, @"allItems");
        if ([items isKindOfClass:NSArray.class] && [items count]) {
            id it0 = [items firstObject];
            SBXLog(@"  item 类=%@ bundleIdentifier响应=%@", NSStringFromClass([it0 class]),
                   [it0 respondsToSelector:NSSelectorFromString(@"bundleIdentifier")] ? @"YES" : @"NO");
            id b0 = SBXIdCall(it0, @"bundleIdentifier");
            SBXLog(@"  item.bundleIdentifier=%@", b0 ?: @"(nil)");
        }
        id pd = SBXIdCall(first, @"primaryDisplayItem");
        if (pd) SBXLog(@"  primaryDisplayItem 类=%@ bid=%@", NSStringFromClass([pd class]), SBXIdCall(pd, @"bundleIdentifier") ?: @"(nil)");
    }
    BOOL preserve = SBXBool(@"clearPreserveNowPlaying", YES);
    NSString *nowPlaying = preserve ? SBXNowPlaying() : nil;
    NSSet *wl = nil;
    id raw = SBXPref(@"clearWhitelist");
    if ([raw isKindOfClass:NSString.class] && [(NSString *)raw length]) {
        NSArray *parts = [(NSString *)raw componentsSeparatedByCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@",， \n\r\t"]];
        NSMutableSet *s = [NSMutableSet set];
        for (NSString *p in parts) if (p.length) [s addObject:p];
        wl = s;
    }
    SEL delSel = NSSelectorFromString(@"_deleteAppLayoutsMatchingBundleIdentifier:");
    if (![coord respondsToSelector:delSel]) { SBXLog(@"清除：控制器没有 _deleteAppLayouts…"); return; }
    void (*delFn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    NSUInteger killed = 0, skipped = 0;
    for (id layout in layouts) {
        NSString *bid = nil;
        id v = SBXIdCall(layout, @"bundleIdentifier");
        if ([v isKindOfClass:NSString.class]) bid = v;
        if (!bid) {
            id items = SBXIdCall(layout, @"allItems");
            if ([items isKindOfClass:NSArray.class]) {
                for (id it in items) {
                    id b = SBXIdCall(it, @"bundleIdentifier");
                    if ([b isKindOfClass:NSString.class]) { bid = b; break; }
                }
            }
        }
        if (!bid) {
            id item = SBXIdCall(layout, @"primaryDisplayItem");
            id b = SBXIdCall(item, @"bundleIdentifier");
            if ([b isKindOfClass:NSString.class]) bid = b;
        }
        if (!bid) continue;
        if (nowPlaying && [bid isEqualToString:nowPlaying]) { skipped++; continue; }
        if (wl && [wl containsObject:bid]) { skipped++; continue; }
        delFn(coord, delSel, bid); killed++;
    }
    SBXLog(@"清除完成：清除 %lu 跳过 %lu（保留播放=%@）", (unsigned long)killed, (unsigned long)skipped, nowPlaying ?: @"无");
}

@interface SBXButtonTarget : NSObject
- (void)handleClear:(UIButton *)sender;
@end
@implementation SBXButtonTarget
- (void)handleClear:(UIButton *)sender {
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [g prepare]; [g impactOccurred];
    SBXKillAll();
    // SystemBox 点击后保留一个轻微收缩状态；不改按钮的静态尺寸/高度/位置。
    sender.transform = CGAffineTransformMakeScale(0.94, 0.94);
}
@end
static SBXButtonTarget *gTarget = nil;

static UIButton *SBXMakeButton(void) {
    double size = SBXNum(@"clearButtonSize", 80, 40, 160);
    double font = SBXNum(@"clearFontSize", 16, 8, 40);
    CGFloat w = size * 0.8, h = size * 0.48, r = size * 0.24;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, w, h);
    b.tag = kBtnTag; b.hidden = YES;
    b.clipsToBounds = YES;
    b.layer.cornerRadius = r; b.layer.cornerCurve = kCACornerCurveContinuous;
    b.backgroundColor = UIColor.clearColor;
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:eff];
    blur.frame = b.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO; blur.tag = kBlurTag;
    blur.layer.cornerRadius = r; blur.layer.cornerCurve = kCACornerCurveContinuous; blur.clipsToBounds = YES;
    [b insertSubview:blur atIndex:0];
    b.titleLabel.font = [UIFont systemFontOfSize:font weight:UIFontWeightMedium];
    b.tintColor = UIColor.labelColor;
    UIImage *clearIcon = [UIImage systemImageNamed:@"trash.slash.circle"];
    if (!clearIcon) clearIcon = [UIImage systemImageNamed:@"trash"];
    if (clearIcon) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:font
                                                              weight:UIImageSymbolWeightMedium
                                                               scale:UIImageSymbolScaleMedium];
        clearIcon = [clearIcon imageWithConfiguration:cfg] ?: clearIcon;
        [b setImage:clearIcon forState:UIControlStateNormal];
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        b.accessibilityLabel = @"清除";
    } else {
        // 极旧系统找不到 SF Symbol 时保留文字回退。
        [b setTitle:@"清除" forState:UIControlStateNormal];
        [b setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    }
    if (!gTarget) gTarget = [SBXButtonTarget new];
    [b addTarget:gTarget action:NSSelectorFromString(@"handleClear:") forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static char kGlassKey;
static void SBXAttachGlass(UIButton *b, BOOL force) {
    if (!b) return;
    if (force) {
        LGGlassButtonView *old = objc_getAssociatedObject(b, &kGlassKey);
        if (old) { [old removeFromSuperview]; objc_setAssociatedObject(b, &kGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    } else if (objc_getAssociatedObject(b, &kGlassKey)) return;
    if (!SBXBool(@"clearGlass", NO)) return;
    UIWindow *win = b.window; if (!win) return;
    UIVisualEffectView *blur = (UIVisualEffectView *)[b viewWithTag:kBlurTag];
    CGRect inWin = [b convertRect:b.bounds toView:win];
    CGFloat ba = blur.alpha, bb = b.alpha;
    if (blur) blur.alpha = 0;
    b.alpha = 0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = win.screen.scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:win.bounds format:fmt];
    UIImage *shot = [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
    }];
    b.alpha = bb;
    if (blur) blur.alpha = ba;
    if (!shot) return;
    LGGlassButtonView *g = [[LGGlassButtonView alloc] initWithFrame:b.bounds];
    if (!g) return;
    g.scale = (float)win.screen.scale;
    g.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [g setBackdropImage:shot origin:CGPointMake(inWin.origin.x, inWin.origin.y)];
    [b insertSubview:g atIndex:0];
    if (blur) blur.alpha = 0;
    objc_setAssociatedObject(b, &kGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SBXLog(@"按钮已套液态玻璃");
}

// viewDidLoad：建按钮（外观保持 Feature 当前版本）
static UIButton *SBXEnsureButtonForController(UIViewController *vc) {
    if (!vc || !vc.view || !ClearOn()) return nil;
    UIButton *b = SBXButtonForOwner(vc);
    if (b && b.superview) return b;
    b = SBXMakeButton();
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
        [b.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [b.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-SBXNum(@"clearBottomOffset", 60, 0, 300)],
        [b.widthAnchor constraintEqualToConstant:b.bounds.size.width],
        [b.heightAnchor constraintEqualToConstant:b.bounds.size.height],
    ]];
    SBXRegisterButton(b, vc);
    SBXLog(@"viewDidLoad：已创建按钮 %.0fx%.0f 底距 %.0f", b.bounds.size.width, b.bounds.size.height, SBXNum(@"clearBottomOffset", 60, 0, 300));
    return b;
}

static void (*orig_switcherDidLoad)(id, SEL);
static void hook_switcherDidLoad(id self, SEL _cmd) {
    if (orig_switcherDidLoad) orig_switcherDidLoad(self, _cmd);
    if ([self isKindOfClass:UIViewController.class]) SBXEnsureButtonForController((UIViewController *)self);
}

static void (*orig_switcherLayout)(id, SEL);
static void hook_switcherLayout(id self, SEL _cmd) {
    if (orig_switcherLayout) orig_switcherLayout(self, _cmd);
    if (!ClearOn() || ![self isKindOfClass:UIViewController.class]) return;
    UIButton *b = SBXEnsureButtonForController((UIViewController *)self);
    if (b && b.bounds.size.width > 4 && !b.hidden) SBXAttachGlass(b, NO);
}

// viewWillAppear：原版在此重置本轮状态、确保按钮并显示
static void (*orig_vcWillAppear)(id, SEL, BOOL);
static void hook_vcWillAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_vcWillAppear) orig_vcWillAppear(self, _cmd, animated);
    gButtonUsed = NO;
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = (UIViewController *)self;
    UIButton *b = SBXEnsureButtonForController(vc);
    if (b && ClearOn()) {
        SBXRegisterButton(b, vc);
        SBXShowClearButtons();
    }
}

// 转场：DidBegin 纯透传；WillEnd/DidEnd 后若切换器可见则显示
static void (*orig_trBegin)(id, SEL, id, id);
static void hook_trBegin(id self, SEL _cmd, id coord, id ctx) {
    if (orig_trBegin) orig_trBegin(self, _cmd, coord, ctx);
}
static void (*orig_trWillEnd)(id, SEL, id, id);
static void hook_trWillEnd(id self, SEL _cmd, id coord, id ctx) {
    if (orig_trWillEnd) orig_trWillEnd(self, _cmd, coord, ctx);
    if (ClearOn() && SBXAnySwitcherVisible()) SBXSetButtonVisible(YES);
}
static void (*orig_trDidEnd)(id, SEL, id, id);
static void hook_trDidEnd(id self, SEL _cmd, id coord, id ctx) {
    if (orig_trDidEnd) orig_trDidEnd(self, _cmd, coord, ctx);
    if (ClearOn() && SBXAnySwitcherVisible()) SBXSetButtonVisible(YES);
}
// dismiss*：先隐藏再调原实现（顺序不能反）
static void (*orig_dismissMain)(id, SEL, BOOL);
static void hook_dismissMain(id self, SEL _cmd, BOOL animated) {
    SBXSetButtonVisible(NO);
    if (orig_dismissMain) orig_dismissMain(self, _cmd, animated);
}
static void (*orig_dismissAll)(id, SEL, BOOL);
static void hook_dismissAll(id self, SEL _cmd, BOOL animated) {
    SBXSetButtonVisible(NO);
    if (orig_dismissAll) orig_dismissAll(self, _cmd, animated);
}
// 后台滚动视图：原版离窗拆除；入窗后延迟显示，不主动改变外观。
static void (*orig_scrollDidMove)(id, SEL);
static void hook_scrollDidMove(id self, SEL _cmd) {
    if (orig_scrollDidMove) orig_scrollDidMove(self, _cmd);
    if (!ClearOn() || ![self isKindOfClass:UIView.class]) return;
    UIView *v = (UIView *)self;
    if (!v.window) {
        SBXRemoveAllButtons();
        SBXSetButtonVisible(NO);
        return;
    }
    SBXScheduleClearButtons(v, 0.08);
    SBXScheduleClearButtons(v, 0.18);
}
static void (*orig_setScrollEnabled)(id, SEL, BOOL);
static void hook_setScrollEnabled(id self, SEL _cmd, BOOL enabled) {
    if (orig_setScrollEnabled) orig_setScrollEnabled(self, _cmd, enabled);
    if (!ClearOn()) return;
    if (!enabled) { SBXSetButtonVisible(NO); return; }
    if ([self isKindOfClass:UIView.class]) SBXScheduleClearButtons((UIView *)self, 0.03);
}


#pragma mark - ============ B. iPad 卡片后台（只保留 SystemBox 已证实的网格参数）============
// 卡片开关改变切换器网格参数；仅在加载切换器内容的 TLS 作用域内临时返回 iPad idiom。
// 不全局伪装设备身份、不吞 coordinator 转场，也不改变普通 App→Home 的类型判断。
// SystemBox 的“以 iPad 形式打开 App”仍是独立功能。
static BOOL gCardOn = NO;
static inline BOOL SBXTake(void) { return gCardOn; }

// SystemBox 的关键卡片链：只在加载切换器内容期间临时返回 iPad idiom。
// 不能全局伪装，否则普通 App→Home 也会走 iPad 转场；必须与原方法成对、可回滚。
static _Thread_local int gCardLoadDepth = 0;
static NSInteger (*orig_userInterfaceIdiom)(id, SEL);
static NSInteger hook_userInterfaceIdiom(id self, SEL _cmd) {
    if (SBXTake() && gCardLoadDepth > 0) return UIUserInterfaceIdiomPad;
    return orig_userInterfaceIdiom ? orig_userInterfaceIdiom(self, _cmd)
                                   : UIUserInterfaceIdiomPhone;
}
static id (*orig_loadContent)(id, SEL, id);
static id hook_loadContent(id self, SEL _cmd, id scene) {
    gCardLoadDepth++;
    id result = nil;
    @try {
        result = orig_loadContent ? orig_loadContent(self, _cmd, scene) : nil;
    } @finally {
        gCardLoadDepth--;
    }
    return result;
}

// ---- 1. SBAppSwitcherSettings：样式与尺寸（17.2 头文件全部确认）----
static long (*orig_switcherStyle)(id, SEL);
static long hook_switcherStyle(id self, SEL _cmd) {
    // SystemBox 的卡片开关只改切换器样式；不改设备身份或 coordinator 转场。
    if (SBXTake()) return 2;
    return orig_switcherStyle ? orig_switcherStyle(self, _cmd) : 0;
}
static double (*orig_gridPageScale)(id, SEL);
static double hook_gridPageScale(id self, SEL _cmd) {
    double v = orig_gridPageScale ? orig_gridPageScale(self, _cmd) : 1.0;
    return SBXTake() ? v * SBXNum(@"cardScale", 1.0, 0.1, 2.0) : v;
}
static double (*orig_gridHSpacing)(id, SEL);
static double hook_gridHSpacing(id self, SEL _cmd) {
    double v = orig_gridHSpacing ? orig_gridHSpacing(self, _cmd) : 1.0;
    return SBXTake() ? v * SBXNum(@"cardHSpacing", 1.0, 0.1, 2.0) : v;
}
static double (*orig_gridVSpacing)(id, SEL);
static double hook_gridVSpacing(id self, SEL _cmd) {
    double v = orig_gridVSpacing ? orig_gridVSpacing(self, _cmd) : 1.0;
    return SBXTake() ? v * SBXNum(@"cardVSpacing", 1.0, 0.1, 2.0) : v;
}
static void (*orig_swSettingsDefaults)(id, SEL);
static void hook_swSettingsDefaults(id self, SEL _cmd) {
    if (orig_swSettingsDefaults) orig_swSettingsDefaults(self, _cmd);
    if (!SBXTake()) return;
    void (*f)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
    SEL s1 = NSSelectorFromString(@"setSpacingBetweenLeadingEdgeAndIcon:");
    SEL s2 = NSSelectorFromString(@"setSpacingBetweenTrailingEdgeAndLabels:");
    if ([self respondsToSelector:s1]) f(self, s1, 0.0);
    if ([self respondsToSelector:s2]) f(self, s2, 0.0);
}

// 卡片组不挂设备身份、协调器转场、主屏缩放或滚动偏移。
// 这些入口属于 SystemBox 的其它独立功能；在这里透传也没有价值，反而扩大 App→Home 风险面。

#pragma mark - ============ C. iPad 悬浮 Dock ============
// SystemBox 挂的是 C 函数，不是 SBFloatingDockController 类方法。
static BOOL (*orig_isFloatingDockSupportedFunc)(void);
static BOOL hook_isFloatingDockSupportedFunc(void) {
    if (DockOn()) return YES;
    return orig_isFloatingDockSupportedFunc ? orig_isFloatingDockSupportedFunc() : NO;
}
static BOOL SBXRecentsWanted(void) {
    NSInteger c = (NSInteger)SBXNum(@"dockContent", 0, 0, 3);
    return (c == 0 || c == 2);
}
static BOOL SBXAppLibraryWanted(void) {
    NSInteger c = (NSInteger)SBXNum(@"dockContent", 0, 0, 3);
    return (c == 1 || c == 2);
}
static BOOL (*orig_recentsEnabled)(id, SEL);
static BOOL hook_recentsEnabled(id self, SEL _cmd) {
    if (DockOn()) return SBXRecentsWanted();
    return orig_recentsEnabled ? orig_recentsEnabled(self, _cmd) : NO;
}
static void (*orig_setRecentsEnabled)(id, SEL, BOOL);
static void hook_setRecentsEnabled(id self, SEL _cmd, BOOL v) {
    if (orig_setRecentsEnabled) orig_setRecentsEnabled(self, _cmd, DockOn() ? SBXRecentsWanted() : v);
}
static BOOL (*orig_appLibraryEnabled)(id, SEL);
static BOOL hook_appLibraryEnabled(id self, SEL _cmd) {
    if (DockOn()) return SBXAppLibraryWanted();
    return orig_appLibraryEnabled ? orig_appLibraryEnabled(self, _cmd) : NO;
}
static void (*orig_setAppLibraryEnabled)(id, SEL, BOOL);
static void hook_setAppLibraryEnabled(id self, SEL _cmd, BOOL v) {
    if (orig_setAppLibraryEnabled) orig_setAppLibraryEnabled(self, _cmd, DockOn() ? SBXAppLibraryWanted() : v);
}
static void (*orig_updateDivider)(id, SEL);
static void hook_updateDivider(id self, SEL _cmd) {
    if (DockOn() && SBXBool(@"hideSeparator", NO)) return;   // 原版：直接 return，不调原实现
    if (orig_updateDivider) orig_updateDivider(self, _cmd);
}
static id gDockController = nil;
static id (*orig_dockInit)(id, SEL, id, id);
static id hook_dockInit(id self, SEL _cmd, id winScene, id iconController) {
    id r = orig_dockInit ? orig_dockInit(self, _cmd, winScene, iconController) : nil;
    if (r) gDockController = r;
    if (DockOn()) SBXLog(@"SBFloatingDockController init → %@", r ? @"建立" : @"nil");
    return r;
}
static id (*orig_dockWindow)(id, SEL);
static id hook_dockWindow(id self, SEL _cmd) {
    id r = orig_dockWindow ? orig_dockWindow(self, _cmd) : nil;
    if (r) gDockController = self;
    return r;
}
static BOOL SBXIsPresentingFolder(id o) {
    return o && [o respondsToSelector:NSSelectorFromString(@"isPresentingFolder")] && SBXBoolCall(o, @"isPresentingFolder");
}
static double (*orig_translationVC)(id, SEL);
static double hook_translationVC(id self, SEL _cmd) {
    if (DockOn() && SBXIsPresentingFolder(self)) return 0.0;
    return orig_translationVC ? orig_translationVC(self, _cmd) : 0.0;
}
static double (*orig_translationCtl)(id, SEL);
static double hook_translationCtl(id self, SEL _cmd) {
    if (DockOn() && SBXIsPresentingFolder(self)) return 0.0;
    return orig_translationCtl ? orig_translationCtl(self, _cmd) : 0.0;
}

static BOOL (*orig_recentShouldAdd)(id, SEL, id, id);
static BOOL hook_recentShouldAdd(id self, SEL _cmd, id controller, id item) {
    if (DockOn()) {
        id suggestion = SBXIdCall(self, @"currentAppSuggestion");
        if (suggestion && [suggestion respondsToSelector:NSSelectorFromString(@"isHandoff")] && SBXBoolCall(suggestion, @"isHandoff")) return NO;
    }
    return orig_recentShouldAdd ? orig_recentShouldAdd(self, _cmd, controller, item) : NO;
}
static id (*orig_suggestInit8)(id, SEL, NSUInteger, id, id, id, id, id, id, id, id);
static id hook_suggestInit8(id self, SEL _cmd, NSUInteger n, id a, id b, id c1, id d, id e, id f, id g, id h) {
    NSUInteger nn = DockOn() ? (NSUInteger)SBXNum(@"dockRecentCount", 3, 1, 10) : n;
    return orig_suggestInit8 ? orig_suggestInit8(self, _cmd, nn, a, b, c1, d, e, f, g, h) : nil;
}
static id (*orig_suggestInit7)(id, SEL, NSUInteger, id, id, id, id, id, id, id);
static id hook_suggestInit7(id self, SEL _cmd, NSUInteger n, id a, id b, id c1, id d, id e, id f, id g) {
    NSUInteger nn = DockOn() ? (NSUInteger)SBXNum(@"dockRecentCount", 3, 1, 10) : n;
    return orig_suggestInit7 ? orig_suggestInit7(self, _cmd, nn, a, b, c1, d, e, f, g) : nil;
}
static BOOL (*orig_gesturePossible)(id, SEL);
static BOOL hook_gesturePossible(id self, SEL _cmd) {
    BOOL r = orig_gesturePossible ? orig_gesturePossible(self, _cmd) : NO;
    if (DockOn() && !SBXBool(@"showInApps", NO)) return NO;   // 原版：返回 0
    return r;
}
static BOOL (*orig_shouldHideInAppDock)(id, SEL);
static BOOL hook_shouldHideInAppDock(id self, SEL _cmd) {
    BOOL r = orig_shouldHideInAppDock ? orig_shouldHideInAppDock(self, _cmd) : YES;
    if (DockOn()) r = r || !SBXBool(@"showInSwitcher", NO);   // 原版：按位或
    return r;
}
static unsigned long (*orig_maxSuggestions)(id, SEL);
static unsigned long hook_maxSuggestions(id self, SEL _cmd) {
    if (DockOn()) return (unsigned long)SBXNum(@"dockRecentCount", 3, 1, 10);  // 原版用"最近使用数量"
    return orig_maxSuggestions ? orig_maxSuggestions(self, _cmd) : 3;
}
static void SBXHideDockPart(id v) {
    if (!v) return;
    if ([v respondsToSelector:NSSelectorFromString(@"setHidden:")])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(v, NSSelectorFromString(@"setHidden:"), YES);
    if ([v respondsToSelector:NSSelectorFromString(@"setAlpha:")])
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(v, NSSelectorFromString(@"setAlpha:"), 0.0);
    if ([v respondsToSelector:NSSelectorFromString(@"setUserInteractionEnabled:")])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(v, NSSelectorFromString(@"setUserInteractionEnabled:"), NO);
}

static void SBXApplyDockList(id list, double scale) {
    if (!list) return;
    if ([list respondsToSelector:NSSelectorFromString(@"setClipsToBounds:")])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(list, NSSelectorFromString(@"setClipsToBounds:"), NO);
    if ([list respondsToSelector:NSSelectorFromString(@"setMasksToBounds:")])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(list, NSSelectorFromString(@"setMasksToBounds:"), NO);
    SEL e = NSSelectorFromString(@"enumerateDisplayedIconViewsUsingBlock:");
    if ([list respondsToSelector:e]) {
        void (^block)(id) = ^(id iconView) {
            if (!iconView) return;
            objc_setAssociatedObject(iconView, "SBXDockScale", @(scale), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if ([iconView respondsToSelector:NSSelectorFromString(@"setTransform:")]) {
                CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
                ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(iconView, NSSelectorFromString(@"setTransform:"), t);
            }
        };
        ((void (*)(id, SEL, id))objc_msgSend)(list, e, block);
    }
}

static double SBXDockScale(id o) {
    if (o && [o respondsToSelector:NSSelectorFromString(@"iconContentScale")]) {
        double s = ((double (*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(@"iconContentScale"));
        if (s > 0.01) return s;
    }
    return 1.0;
}

static void (*orig_platterLayout)(id, SEL);
static void hook_platterLayout(id self, SEL _cmd) {
    if (orig_platterLayout) orig_platterLayout(self, _cmd);
    if (DockOn() && SBXBool(@"transparentDock", NO)) {
        SBXHideDockPart(SBXIdCall(self, @"backgroundView"));
        SBXHideDockPart(SBXIdCall(self, @"shadowView"));
    }
}
static void (*orig_dockViewLayout)(id, SEL);
static void hook_dockViewLayout(id self, SEL _cmd) {
    if (orig_dockViewLayout) orig_dockViewLayout(self, _cmd);
    if (!DockOn()) return;
    double s = SBXDockScale(self);
    SBXApplyDockList(SBXIdCall(self, @"userIconListView"), s);
    SBXApplyDockList(SBXIdCall(self, @"recentIconListView"), s);
    id accessory = SBXIdCall(self, @"accessoryIconView");
    if (accessory && [accessory respondsToSelector:NSSelectorFromString(@"setTransform:")]) {
        CGAffineTransform t = CGAffineTransformMakeScale(s, s);
        ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(accessory, NSSelectorFromString(@"setTransform:"), t);
    }
}
static void (*orig_suggVisible)(id, SEL);
static void hook_suggVisible(id self, SEL _cmd) {
    if (orig_suggVisible) orig_suggVisible(self, _cmd);
    if (!DockOn()) return;
    id list = SBXIdCall(self, @"listView");
    if (list) SBXApplyDockList(list, SBXDockScale(list));
}
static void (*orig_dockListConfigure)(id, SEL, id, id);
static void hook_dockListConfigure(id self, SEL _cmd, id iconView, id icon) {
    if (orig_dockListConfigure) orig_dockListConfigure(self, _cmd, iconView, icon);
    if (!DockOn() || !iconView) return;
    objc_setAssociatedObject(iconView, "SBXDockScale", @(SBXDockScale(self)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void (*orig_suggConfigure)(id, SEL, id, id);
static void hook_suggConfigure(id self, SEL _cmd, id iconView, id icon) {
    if (orig_suggConfigure) orig_suggConfigure(self, _cmd, iconView, icon);
    if (!DockOn() || !iconView) return;
    objc_setAssociatedObject(iconView, "SBXDockScale", @1.0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void (*orig_dockTrait)(id, SEL);
static void hook_dockTrait(id self, SEL _cmd) {
    if (orig_dockTrait) orig_dockTrait(self, _cmd);
    if (DockOn() && SBXBool(@"transparentDock", NO)) {
        SBXHideDockPart(SBXIdCall(self, @"backgroundView"));
        SBXHideDockPart(SBXIdCall(self, @"shadowView"));
        if ([self respondsToSelector:NSSelectorFromString(@"setNeedsLayout")])
            ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"setNeedsLayout"));
    }
}

#pragma mark - 安装
static void HookMsg(const char *cls, const char *sel, IMP imp, IMP *orig) {
    Class c = objc_getClass(cls);
    if (!c) { SBXLog(@"类不存在: %s", cls); return; }
    SEL s = NSSelectorFromString([NSString stringWithUTF8String:sel]);
    if (!class_getInstanceMethod(c, s) && !class_getClassMethod(c, s)) { SBXLog(@"方法不存在: %s %s", cls, sel); return; }
    SBXLoadSubstrate();
    if (!gHookMsgEx) { SBXLog(@"substrate 不可用"); return; }
    gHookMsgEx(c, s, imp, orig);
    SBXLog(@"已挂: %s %s", cls, sel);
}

__attribute__((constructor)) static void SBXInit(void) {
    @autoreleasepool {
        BOOL a = ClearOn(), b = CardsOn(), c = DockOn();
        SBXLog(@"==== SBXDesktop 装载：清除按钮=%@ 卡片后台=%@ 悬浮Dock=%@ ====", a?@"开":@"关", b?@"开":@"关", c?@"开":@"关");
        if (!a && !b && !c) { SBXLog(@"三项都未启用，跳过全部 hook"); return; }
        SBXLoadSubstrate();
        if (!gHookMsgEx) { SBXLog(@"substrate 不可用，放弃挂载"); return; }

        if (a) {
            HookMsg("SBFluidSwitcherViewController", "viewDidLoad", (IMP)hook_switcherDidLoad, (IMP *)&orig_switcherDidLoad);
            HookMsg("SBFluidSwitcherViewController", "viewWillAppear:", (IMP)hook_vcWillAppear, (IMP *)&orig_vcWillAppear);
            HookMsg("SBFluidSwitcherViewController", "viewDidLayoutSubviews", (IMP)hook_switcherLayout, (IMP *)&orig_switcherLayout);
            HookMsg("SBMainSwitcherControllerCoordinator",
                    "layoutStateTransitionCoordinator:transitionDidBeginWithTransitionContext:", (IMP)hook_trBegin, (IMP *)&orig_trBegin);
            HookMsg("SBMainSwitcherControllerCoordinator",
                    "layoutStateTransitionCoordinator:transitionWillEndWithTransitionContext:", (IMP)hook_trWillEnd, (IMP *)&orig_trWillEnd);
            HookMsg("SBMainSwitcherControllerCoordinator",
                    "layoutStateTransitionCoordinator:transitionDidEndWithTransitionContext:", (IMP)hook_trDidEnd, (IMP *)&orig_trDidEnd);
            HookMsg("SBMainSwitcherControllerCoordinator", "dismissMainSwitcherNoninteractivelyAnimated:", (IMP)hook_dismissMain, (IMP *)&orig_dismissMain);
            HookMsg("SBMainSwitcherControllerCoordinator", "dismissAllSwitchersNoninteractivelyAnimated:", (IMP)hook_dismissAll, (IMP *)&orig_dismissAll);
            HookMsg("SBAppSwitcherScrollView", "didMoveToWindow", (IMP)hook_scrollDidMove, (IMP *)&orig_scrollDidMove);
            HookMsg("SBAppSwitcherScrollView", "setScrollEnabled:", (IMP)hook_setScrollEnabled, (IMP *)&orig_setScrollEnabled);
        }
        if (b) {
            SBXLog(@"卡片后台：安全网格模式（5 条参数 hook，不接管 App→Home 转场）");
            gCardOn = YES;
            HookMsg("UIDevice", "userInterfaceIdiom", (IMP)hook_userInterfaceIdiom, (IMP *)&orig_userInterfaceIdiom);
            HookMsg("SBMainSwitcherControllerCoordinator", "_loadContentViewControllerIfNecessaryForWindowScene:", (IMP)hook_loadContent, (IMP *)&orig_loadContent);
            HookMsg("SBAppSwitcherSettings", "effectiveSwitcherStyle", (IMP)hook_switcherStyle, (IMP *)&orig_switcherStyle);
            HookMsg("SBAppSwitcherSettings", "gridSwitcherPageScale", (IMP)hook_gridPageScale, (IMP *)&orig_gridPageScale);
            HookMsg("SBAppSwitcherSettings", "gridSwitcherHorizontalInterpageSpacingPortrait", (IMP)hook_gridHSpacing, (IMP *)&orig_gridHSpacing);
            HookMsg("SBAppSwitcherSettings", "gridSwitcherVerticalNaturalSpacingPortrait", (IMP)hook_gridVSpacing, (IMP *)&orig_gridVSpacing);
            HookMsg("SBAppSwitcherSettings", "setDefaultValues", (IMP)hook_swSettingsDefaults, (IMP *)&orig_swSettingsDefaults);

        }
        if (c) {
            void *dockSym = dlsym(RTLD_DEFAULT, "isFloatingDockSupported");
            if (dockSym && gHookFunc) {
                gHookFunc(dockSym, (void *)hook_isFloatingDockSupportedFunc,
                          (void **)&orig_isFloatingDockSupportedFunc);
                SBXLog(@"已挂 C 函数 isFloatingDockSupported");
            } else {
                SBXLog(@"找不到 C 函数 isFloatingDockSupported");
            }
            HookMsg("SBFloatingDockDefaults", "recentsEnabled", (IMP)hook_recentsEnabled, (IMP *)&orig_recentsEnabled);
            HookMsg("SBFloatingDockDefaults", "setRecentsEnabled:", (IMP)hook_setRecentsEnabled, (IMP *)&orig_setRecentsEnabled);
            HookMsg("SBFloatingDockDefaults", "appLibraryEnabled", (IMP)hook_appLibraryEnabled, (IMP *)&orig_appLibraryEnabled);
            HookMsg("SBFloatingDockDefaults", "setAppLibraryEnabled:", (IMP)hook_setAppLibraryEnabled, (IMP *)&orig_setAppLibraryEnabled);
            HookMsg("SBFloatingDockView", "updateDividerVisualStyling", (IMP)hook_updateDivider, (IMP *)&orig_updateDivider);
            HookMsg("SBFloatingDockView", "layoutSubviews", (IMP)hook_dockViewLayout, (IMP *)&orig_dockViewLayout);
            HookMsg("SBFloatingDockPlatterView", "layoutSubviews", (IMP)hook_platterLayout, (IMP *)&orig_platterLayout);
            HookMsg("SBFloatingDockPlatterView", "_dynamicUserInterfaceTraitDidChange", (IMP)hook_dockTrait, (IMP *)&orig_dockTrait);
            HookMsg("SBFloatingDockIconListView", "configureIconView:forIcon:", (IMP)hook_dockListConfigure, (IMP *)&orig_dockListConfigure);
            HookMsg("SBFloatingDockSuggestionsViewController", "configureIconView:forIcon:", (IMP)hook_suggConfigure, (IMP *)&orig_suggConfigure);
            HookMsg("SBFloatingDockController", "initWithWindowScene:iconController:", (IMP)hook_dockInit, (IMP *)&orig_dockInit);
            HookMsg("SBFloatingDockController", "floatingDockWindow", (IMP)hook_dockWindow, (IMP *)&orig_dockWindow);
            HookMsg("SBFloatingDockViewController", "translationFromFullyPresentedFrame", (IMP)hook_translationVC, (IMP *)&orig_translationVC);
            HookMsg("SBFloatingDockController", "translationFromFullyPresentedFrame", (IMP)hook_translationCtl, (IMP *)&orig_translationCtl);
            HookMsg("SBFloatingDockBehaviorAssertion", "gesturePossible", (IMP)hook_gesturePossible, (IMP *)&orig_gesturePossible);
            HookMsg("SBDeckSwitcherModifier", "shouldConfigureInAppDockHiddenAssertion", (IMP)hook_shouldHideInAppDock, (IMP *)&orig_shouldHideInAppDock);
            HookMsg("SBFloatingDockSuggestionsModel", "maxSuggestions", (IMP)hook_maxSuggestions, (IMP *)&orig_maxSuggestions);
            HookMsg("SBFloatingDockSuggestionsModel", "recentDisplayItemsController:shouldAddItem:", (IMP)hook_recentShouldAdd, (IMP *)&orig_recentShouldAdd);
            HookMsg("SBFloatingDockSuggestionsModel", "initWithMaximumNumberOfSuggestions:iconController:recentsController:recentsDataStore:recentsDefaults:floatingDockDefaults:appSuggestionManager:analyticsClient:applicationController:", (IMP)hook_suggestInit8, (IMP *)&orig_suggestInit8);
            HookMsg("SBFloatingDockSuggestionsModel", "initWithMaximumNumberOfSuggestions:iconController:recentsController:recentsDataStore:recentsDefaults:floatingDockDefaults:appSuggestionManager:applicationController:", (IMP)hook_suggestInit7, (IMP *)&orig_suggestInit7);
            HookMsg("SBFloatingDockSuggestionsViewController", "dockViewDidBecomeVisible", (IMP)hook_suggVisible, (IMP *)&orig_suggVisible);
        }
        SBXLog(@"hook 安装完成");
    }
}
