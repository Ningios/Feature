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

static UIButton *SBXFindButton(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [(UIWindowScene *)sc windows]) {
            UIButton *b = (UIButton *)[w viewWithTag:kBtnTag];
            if (b) return b;
        }
    }
    return nil;
}
static void SBXAttachGlass(UIButton *b, BOOL force);
static BOOL SBXHasAppLayouts(void);   // 前置声明

static void SBXSetButtonVisible(BOOL vis) {
    static double lastTime = 0; static BOOL lastVis = YES;
    double now = [NSDate date].timeIntervalSince1970;
    if (vis == lastVis && now - lastTime < 0.4) return;    // 去抖，避免转场里反复切
    lastTime = now; lastVis = vis;
    UIButton *b = SBXFindButton();
    if (!b) { SBXLog(@"按钮%@（未找到）", vis ? @"显示" : @"隐藏"); return; }
    if (b.hidden == !vis) { /* 状态未变 */ }
    b.hidden = !vis;
    SBXLog(@"按钮%@", vis ? @"显示" : @"隐藏");
    if (vis && !SBXHasAppLayouts()) { b.hidden = YES; SBXLog(@"没有后台卡片 → 不显示按钮"); return; }
    if (vis) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIButton *bb = SBXFindButton();
            if (bb) SBXAttachGlass(bb, YES);   // 显示后再截底图（viewDidLoad 时是黑的）
        });
    }
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
    SBXSetButtonVisible(NO);   // 清完立刻收按钮（不等下一次布局事件）
    // 兜底：直接把切换器收起（有些卡片已不在 recentAppLayouts 里）
    for (NSString *dn in @[@"dismissAllSwitchersNoninteractivelyAnimated:",
                           @"dismissMainSwitcherNoninteractivelyAnimated:"]) {
        SEL ds = NSSelectorFromString(dn);
        if ([coord respondsToSelector:ds]) {
            void (*df)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
            df(coord, ds, YES);
            SBXLog(@"兜底：%@", dn);
            break;
        }
    }
}

@interface SBXButtonTarget : NSObject
- (void)handleClear:(UIButton *)sender;
@end
@implementation SBXButtonTarget
- (void)handleClear:(UIButton *)sender {
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [g prepare]; [g impactOccurred];
    SBXKillAll();
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
    [b setTitle:@"清除" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
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

// viewDidLoad：建按钮（原版在此创建，hidden/alpha0）
static void (*orig_switcherDidLoad)(id, SEL);
static void hook_switcherDidLoad(id self, SEL _cmd) {
    if (orig_switcherDidLoad) orig_switcherDidLoad(self, _cmd);
    if (!ClearOn()) return;
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = (UIViewController *)self;
    if ([vc.view viewWithTag:kBtnTag]) return;
    double bottom = SBXNum(@"clearBottomOffset", 60, 0, 300);
    UIButton *b = SBXMakeButton();
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
        [b.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [b.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-bottom],
        [b.widthAnchor constraintEqualToConstant:b.bounds.size.width],
        [b.heightAnchor constraintEqualToConstant:b.bounds.size.height],
    ]];
    SBXLog(@"viewDidLoad：已创建按钮 %.0fx%.0f 底距 %.0f", b.bounds.size.width, b.bounds.size.height, bottom);
}

static void (*orig_switcherLayout)(id, SEL);
static void hook_switcherLayout(id self, SEL _cmd) {
    if (orig_switcherLayout) orig_switcherLayout(self, _cmd);
    if (!ClearOn()) return;
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = (UIViewController *)self;
    UIButton *b = (UIButton *)[vc.view viewWithTag:kBtnTag];
    if (b && b.bounds.size.width > 4 && !b.hidden) SBXAttachGlass(b, NO);
}

// viewWillAppear：原版在此显示按钮
static void (*orig_vcWillAppear)(id, SEL, BOOL);
static void hook_vcWillAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_vcWillAppear) orig_vcWillAppear(self, _cmd, animated);
    if (ClearOn()) SBXSetButtonVisible(YES);
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
    if (CardsOn() && SBXAnySwitcherVisible() && !SBXHasAppLayouts()) {
        SBXLog(@"空后台 → 自动退出");
        Class c = NSClassFromString(@"SBMainSwitcherControllerCoordinator");
        id coord = SBXClassCall(c, @"sharedInstanceIfExists");
        SEL ds = NSSelectorFromString(@"dismissMainSwitcherNoninteractivelyAnimated:");
        if (coord && [coord respondsToSelector:ds]) {
            void (*df)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
            df(coord, ds, YES);
        }
    }
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
// 后台滚动视图：离开窗口 → 拆按钮并隐藏；否则若开着按钮功能，0.08s/0.18s 各隐藏一次
static void (*orig_scrollDidMove)(id, SEL);
static void hook_scrollDidMove(id self, SEL _cmd) {
    if (orig_scrollDidMove) orig_scrollDidMove(self, _cmd);
    if (!ClearOn()) return;
    UIView *v = (UIView *)self;
    if (![v isKindOfClass:UIView.class]) return;
    if (v.window == nil) {
        UIButton *b = SBXFindButton();
        if (b) { [b removeFromSuperview]; SBXLog(@"后台滚动视图离开窗口：已拆按钮"); }
        return;
    }
    for (NSNumber *dn in @[@0.08, @0.18]) {
        double d = [dn doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!SBXAnySwitcherVisible()) SBXSetButtonVisible(NO);
        });
    }
}
static void (*orig_setScrollEnabled)(id, SEL, BOOL);
static void hook_setScrollEnabled(id self, SEL _cmd, BOOL enabled) {
    if (orig_setScrollEnabled) orig_setScrollEnabled(self, _cmd, enabled);
    if (!ClearOn()) return;
    if (!enabled) { SBXSetButtonVisible(NO); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!SBXAnySwitcherVisible()) SBXSetButtonVisible(NO);
    });
}


#pragma mark - 假 iPad idiom（网格切换器必须，否则布局/动画半吊子）
// C 方案：只换样式（effectiveSwitcherStyle=2 + Chamois 网格），不伪装 iPad idiom
// 让系统按 iPhone 原生逻辑播动画，避免"啪"地跳变
static _Thread_local int gPadIdiom = 0;
__attribute__((unused)) static BOOL gFakePadIdiom = NO;
static NSInteger (*orig_idiom)(id, SEL);
static NSInteger hook_idiom(id self, SEL _cmd) {
    // TrollPadEx 的做法：平时就是 Pad(1)，只在被包裹的转场入口内退回 Phone
    // 注意 UIUserInterfaceIdiomPad == 1（不是 2，2 是 TV）
    extern BOOL SBXTakeCached(void);
    extern BOOL SBXCardPadCached(void);
    if (SBXTakeCached() && SBXCardPadCached() && gPadIdiom == 0) return 1;
    return orig_idiom ? orig_idiom(self, _cmd) : 0;
}
#pragma mark - ============ B. iPad 卡片后台（照 TrollPadEx 2.0.5 的 118 条 hook）============
// 本段由 TrollPadSB.dylib (arm64) 反汇编逐条还原，不是抄开源 TweakSB.x。
// 与开源版的根本差别：TrollPadEx 让系统**全局 Pad 化**（UIDevice 平时就返回 Pad），
// 只在几个关键转场入口内临时退回 Phone —— 这是动画存在的前提。
// 开源版（iOS 16 时代）里 SBMainWorkspace isMedusaEnabled 等方法在 17.2 上不存在，
// 所以照抄开源版必然"挂不上、没动画"。

// ---- 开关 ----
static BOOL gCardOn = NO;
static BOOL gCardPad = NO;   // 全局 Pad 化
BOOL SBXTakeCached(void) { return gCardOn; }
BOOL SBXCardPadCached(void) { return gCardPad; }    // 主开关（SBXInit 时读一次，避免热路径读偏好）
static BOOL SBXCardPad(void) { return gCardPad; }
static inline BOOL SBXTake(void) { return gCardOn; }

#pragma mark 1) 身份与方向


static NSInteger (*orig_uilayoutDir)(id, SEL);
static NSInteger hook_uilayoutDir(id self, SEL _cmd) {
    if (SBXTake()) return 1;
    return orig_uilayoutDir ? orig_uilayoutDir(self, _cmd) : 0;
}

static NSUInteger (*orig_defaultOrientations)(id, SEL);
static NSUInteger hook_defaultOrientations(id self, SEL _cmd) {
    if (SBXTake()) return 1;
    return orig_defaultOrientations ? orig_defaultOrientations(self, _cmd) : 0;
}

static NSUInteger (*orig_homeScreenOrientations)(id, SEL);
static NSUInteger hook_homeScreenOrientations(id self, SEL _cmd) {
    NSUInteger r = orig_homeScreenOrientations ? orig_homeScreenOrientations(self, _cmd) : 0;
    if (SBXTake()) r |= (1 << 2);   // 允许倒置
    return r;
}

static long (*orig_homeScreenRotationStyle)(id, SEL);
static long hook_homeScreenRotationStyle(id self, SEL _cmd) {
    if (SBXTake()) return 1;
    return orig_homeScreenRotationStyle ? orig_homeScreenRotationStyle(self, _cmd) : 0;
}

static BOOL (*orig_allowedUpsideDown)(id, SEL);
static BOOL hook_allowedUpsideDown(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_allowedUpsideDown ? orig_allowedUpsideDown(self, _cmd) : NO;
}

static long (*orig_orientationMode)(id, SEL);
static long hook_orientationMode(id self, SEL _cmd) {
    if (!SBXTake()) return orig_orientationMode ? orig_orientationMode(self, _cmd) : 0;
    gPadIdiom++;
    long r = 0;
    @try { r = orig_orientationMode ? orig_orientationMode(self, _cmd) : 0; }
    @finally { gPadIdiom--; }
    return r;
}

static id (*orig_defaultOrientAnim)(id, SEL, BOOL);
static id hook_defaultOrientAnim(id self, SEL _cmd, BOOL animatable) {
    if (!SBXTake()) return orig_defaultOrientAnim ? orig_defaultOrientAnim(self, _cmd, animatable) : nil;
    gPadIdiom++;
    id r = nil;
    @try { r = orig_defaultOrientAnim ? orig_defaultOrientAnim(self, _cmd, animatable) : nil; }
    @finally { gPadIdiom--; }
    return r;
}

static id (*orig_appInitContext)(id, SEL, id, id, id, id, BOOL);
static id hook_appInitContext(id self, SEL _cmd, id a, id b, id c, id d, BOOL support) {
    return orig_appInitContext ? orig_appInitContext(self, _cmd, a, b, c, d, SBXTake() ? YES : support) : nil;
}

#pragma mark 2) 切换器样式与尺寸

static long (*orig_switcherStyle)(id, SEL);
static long hook_switcherStyle(id self, SEL _cmd) {
    // TrollPadEx: enabled ? (pad ? 2 : 1) : orig
    if (SBXTake()) return SBXCardPad() ? 2 : 1;
    return orig_switcherStyle ? orig_switcherStyle(self, _cmd) : 0;
}
static long (*orig_switcherStyle2)(id, SEL);
static long hook_switcherStyle2(id self, SEL _cmd) {
    if (SBXTake()) return SBXCardPad() ? 2 : 1;
    return orig_switcherStyle2 ? orig_switcherStyle2(self, _cmd) : 0;
}

static void (*orig_swSettingsDefaults)(id, SEL);
static void hook_swSettingsDefaults(id self, SEL _cmd) {
    if (orig_swSettingsDefaults) orig_swSettingsDefaults(self, _cmd);
    if (!SBXTake() || !SBXCardPad()) return;
    void (*f)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
    SEL s1 = NSSelectorFromString(@"setSpacingBetweenLeadingEdgeAndIcon:");
    SEL s2 = NSSelectorFromString(@"setSpacingBetweenTrailingEdgeAndLabels:");
    if ([self respondsToSelector:s1]) f(self, s1, 0.0);
    if ([self respondsToSelector:s2]) f(self, s2, 0.0);
}

// 五个 setter：接管时写固定值（TrollPadEx 的值）
static double SBXCardScale(void) { return SBXNum(@"cardScaleVal", 0.38, 0.15, 1.2); }
static void (*orig_setGridPageScale)(id, SEL, double);
static void hook_setGridPageScale(id self, SEL _cmd, double v) {
    if (!orig_setGridPageScale) return;
    orig_setGridPageScale(self, _cmd, (SBXTake() && SBXCardPad()) ? SBXCardScale() : v);
}
static void (*orig_setGridVSpacingP)(id, SEL, double);
static void hook_setGridVSpacingP(id self, SEL _cmd, double v) {
    if (!orig_setGridVSpacingP) return;
    orig_setGridVSpacingP(self, _cmd, (SBXTake() && SBXCardPad()) ? 65.0 : v);
}
static void (*orig_setGridVSpacingL)(id, SEL, double);
static void hook_setGridVSpacingL(id self, SEL _cmd, double v) {
    if (!orig_setGridVSpacingL) return;
    orig_setGridVSpacingL(self, _cmd, (SBXTake() && SBXCardPad()) ? 40.0 : v);
}
static void (*orig_setGridHSpacingP)(id, SEL, double);
static void hook_setGridHSpacingP(id self, SEL _cmd, double v) {
    if (!orig_setGridHSpacingP) return;
    orig_setGridHSpacingP(self, _cmd, (SBXTake() && SBXCardPad()) ? 30.0 : v);
}
static void (*orig_setGridHSpacingL)(id, SEL, double);
static void hook_setGridHSpacingL(id self, SEL _cmd, double v) {
    if (!orig_setGridHSpacingL) return;
    orig_setGridHSpacingL(self, _cmd, (SBXTake() && SBXCardPad()) ? 10.0 : v);
}

static void (*orig_setGridWidths)(id, SEL, id);
static void hook_setGridWidths(id self, SEL _cmd, id values) {
    if (SBXTake() && [values isKindOfClass:NSArray.class] && [values count]) {
        NSUInteger maxValue = [[values lastObject] unsignedIntegerValue];
        if (maxValue > 150) {
            NSMutableArray *arr = [NSMutableArray array];
            for (NSUInteger i = 150; i < maxValue; i += 20) [arr addObject:@(i)];
            [arr addObject:@(maxValue)];
            values = arr;
        }
    }
    if (orig_setGridWidths) orig_setGridWidths(self, _cmd, values);
}
static void (*orig_setGridHeights)(id, SEL, id);
static void hook_setGridHeights(id self, SEL _cmd, id values) {
    if (SBXTake() && [values isKindOfClass:NSArray.class] && [values count]) {
        NSUInteger maxValue = [[values lastObject] unsignedIntegerValue];
        if (maxValue > 150) {
            NSMutableArray *arr = [NSMutableArray array];
            for (NSUInteger i = 150; i < maxValue; i += 20) [arr addObject:@(i)];
            [arr addObject:@(maxValue)];
            values = arr;
        }
    }
    if (orig_setGridHeights) orig_setGridHeights(self, _cmd, values);
}
static unsigned long (*orig_maxAppsOnStage)(id, SEL);
static unsigned long hook_maxAppsOnStage(id self, SEL _cmd) {
    if (SBXTake()) return 5;
    return orig_maxAppsOnStage ? orig_maxAppsOnStage(self, _cmd) : 1;
}

static BOOL (*orig_isDevicePad)(id, SEL);
static BOOL hook_isDevicePad(id self, SEL _cmd) {
    if (SBXTake() && SBXCardPad()) return YES;
    return orig_isDevicePad ? orig_isDevicePad(self, _cmd) : NO;
}

#pragma mark 3) 窗口管理 / 多任务能力

static BOOL (*orig_isMedusaEnabled)(id, SEL);
static BOOL hook_isMedusaEnabled(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_isMedusaEnabled ? orig_isMedusaEnabled(self, _cmd) : NO;
}
static long (*orig_medusaCapabilities)(id, SEL);
static long hook_medusaCapabilities(id self, SEL _cmd) {
    if (SBXTake()) return 2;
    return orig_medusaCapabilities ? orig_medusaCapabilities(self, _cmd) : 0;
}
static BOOL (*orig_platformHomeGesture)(id, SEL);
static BOOL hook_platformHomeGesture(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_platformHomeGesture ? orig_platformHomeGesture(self, _cmd) : YES;
}
static BOOL (*orig_isMedusaCapable)(id, SEL);
static BOOL hook_isMedusaCapable(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_isMedusaCapable ? orig_isMedusaCapable(self, _cmd) : NO;
}
static BOOL (*orig_supportsAppType)(id, SEL, int);
static BOOL hook_supportsAppType(id self, SEL _cmd, int type) {
    if (SBXTake()) return YES;
    return orig_supportsAppType ? orig_supportsAppType(self, _cmd, type) : NO;
}
static BOOL (*orig_isFloatingActive)(id, SEL);
static BOOL hook_isFloatingActive(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_isFloatingActive ? orig_isFloatingActive(self, _cmd) : NO;
}
static BOOL (*orig_supportsMultitasking)(id, SEL);
static BOOL hook_supportsMultitasking(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_supportsMultitasking ? orig_supportsMultitasking(self, _cmd) : NO;
}
static long (*orig_windowManagementStyle)(id, SEL);
static long hook_windowManagementStyle(id self, SEL _cmd) {
    if (SBXTake()) return 1;
    return orig_windowManagementStyle ? orig_windowManagementStyle(self, _cmd) : 0;
}

// SBApplication 的 Chamois 系列
static BOOL (*orig_medusaMultitaskingEnabled)(id, SEL);
static BOOL hook_medusaMultitaskingEnabled(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_medusaMultitaskingEnabled ? orig_medusaMultitaskingEnabled(self, _cmd) : NO;
}
static BOOL (*orig_chamoisWindowingEnabled)(id, SEL);
static BOOL hook_chamoisWindowingEnabled(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_chamoisWindowingEnabled ? orig_chamoisWindowingEnabled(self, _cmd) : NO;
}
static BOOL (*orig_chamoisSceneResizing)(id, SEL);
static BOOL hook_chamoisSceneResizing(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_chamoisSceneResizing ? orig_chamoisSceneResizing(self, _cmd) : NO;
}
static BOOL (*orig_chamoisViewResizing)(id, SEL);
static BOOL hook_chamoisViewResizing(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_chamoisViewResizing ? orig_chamoisViewResizing(self, _cmd) : NO;
}
static BOOL (*orig_alwaysMaximizedInChamois)(id, SEL);
static BOOL hook_alwaysMaximizedInChamois(id self, SEL _cmd) {
    if (SBXTake()) return NO;
    return orig_alwaysMaximizedInChamois ? orig_alwaysMaximizedInChamois(self, _cmd) : NO;
}

#pragma mark 4) 控制中心 / Home 手势

static NSUInteger (*orig_defaultPresentationGesture)(id, SEL);
static NSUInteger hook_defaultPresentationGesture(id self, SEL _cmd) {
    if (SBXTake()) return 1;
    return orig_defaultPresentationGesture ? orig_defaultPresentationGesture(self, _cmd) : 0;
}
static BOOL (*orig_homeGestureEnabled)(id, SEL);
static BOOL hook_homeGestureEnabled(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_homeGestureEnabled ? orig_homeGestureEnabled(self, _cmd) : YES;
}
static NSUInteger (*orig_presentingEdge)(id, SEL);
static NSUInteger hook_presentingEdge(id self, SEL _cmd) {
    if (SBXTake()) return 1;
    return orig_presentingEdge ? orig_presentingEdge(self, _cmd) : 0;
}

#pragma mark 5) 转场入口（包裹内退回 Phone）

static void (*orig_overlayTransBegin)(id, SEL, id, id);
static void hook_overlayTransBegin(id self, SEL _cmd, id coord, id ctx) {
    if (!SBXTake()) { if (orig_overlayTransBegin) orig_overlayTransBegin(self, _cmd, coord, ctx); return; }
    gPadIdiom++;
    @try { if (orig_overlayTransBegin) orig_overlayTransBegin(self, _cmd, coord, ctx); }
    @finally { gPadIdiom--; }
}
static void (*orig_loadContent)(id, SEL, id);
static void hook_loadContent(id self, SEL _cmd, id scene) {
    if (!SBXTake()) { if (orig_loadContent) orig_loadContent(self, _cmd, scene); return; }
    gPadIdiom++;
    @try { if (orig_loadContent) orig_loadContent(self, _cmd, scene); }
    @finally { gPadIdiom--; }
}
static void (*orig_updateContentVC)(id, SEL);
static void hook_updateContentVC(id self, SEL _cmd) {
    if (!SBXTake()) { if (orig_updateContentVC) orig_updateContentVC(self, _cmd); return; }
    gPadIdiom++;
    @try { if (orig_updateContentVC) orig_updateContentVC(self, _cmd); }
    @finally { gPadIdiom--; }
}

#pragma mark 6) 窗口管理修饰器（frame 系列，接管后调原实现）

#define SBX_FRAME_HOOK(NAME, SELNAME, SIG, ARGS, CALLARGS) \
static void (*orig_##NAME)SIG; \
static void hook_##NAME SIG { \
    if (orig_##NAME) orig_##NAME CALLARGS; \
}

// 这些方法的返回值类型各异，统一"透传 + 接管标记"
static CGRect (*orig_frameForItem)(id, SEL, id);
static CGRect hook_frameForItem(id self, SEL _cmd, id item) {
    if (orig_frameForItem) return orig_frameForItem(self, _cmd, item);
    return CGRectZero;
}
static CGRect (*orig_frameForLayoutRole)(id, SEL, long, id, CGRect);
static CGRect hook_frameForLayoutRole(id self, SEL _cmd, long role, id layout, CGRect bounds) {
    if (orig_frameForLayoutRole) return orig_frameForLayoutRole(self, _cmd, role, layout, bounds);
    return bounds;
}
static void (*orig_layoutViewModelsIfNeeded)(id, SEL);
static void hook_layoutViewModelsIfNeeded(id self, SEL _cmd) {
    if (orig_layoutViewModelsIfNeeded) orig_layoutViewModelsIfNeeded(self, _cmd);
}
static CGRect (*orig_scaledFrameForRole)(id, SEL, long, id, unsigned long);
static CGRect hook_scaledFrameForRole(id self, SEL _cmd, long role, id layout, unsigned long idx) {
    if (orig_scaledFrameForRole) return orig_scaledFrameForRole(self, _cmd, role, layout, idx);
    return CGRectZero;
}
static CGPoint (*orig_contentOffsetForIndex)(id, SEL, unsigned long, unsigned long);
static CGPoint hook_contentOffsetForIndex(id self, SEL _cmd, unsigned long idx, unsigned long align) {
    if (orig_contentOffsetForIndex) return orig_contentOffsetForIndex(self, _cmd, idx, align);
    return CGPointZero;
}
static CGRect (*orig_frameForIndex)(id, SEL, unsigned long);
static CGRect hook_frameForIndex(id self, SEL _cmd, unsigned long idx) {
    if (orig_frameForIndex) return orig_frameForIndex(self, _cmd, idx);
    return CGRectZero;
}
static CGPoint (*orig_anchorPointForIndex)(id, SEL, unsigned long);
static CGPoint hook_anchorPointForIndex(id self, SEL _cmd, unsigned long idx) {
    if (orig_anchorPointForIndex) return orig_anchorPointForIndex(self, _cmd, idx);
    return CGPointMake(0.5, 0.5);
}
static double (*orig_perspectiveAngleForLayout)(id, SEL, id);
static double hook_perspectiveAngleForLayout(id self, SEL _cmd, id layout) {
    if (orig_perspectiveAngleForLayout) return orig_perspectiveAngleForLayout(self, _cmd, layout);
    return 0.0;
}
static BOOL (*orig_isRTLEnabled)(id, SEL);
static BOOL hook_isRTLEnabled(id self, SEL _cmd) {
    if (SBXTake()) return YES;
    return orig_isRTLEnabled ? orig_isRTLEnabled(self, _cmd) : NO;
}
static double (*orig_stripOriginX)(id, SEL);
static double hook_stripOriginX(id self, SEL _cmd) {
    if (orig_stripOriginX) return orig_stripOriginX(self, _cmd);
    return 0.0;
}
static double (*orig_continuousExposeStripEdge)(id, SEL);
static double hook_continuousExposeStripEdge(id self, SEL _cmd) {
    if (SBXTake() && SBXCardPad()) return 8;
    return orig_continuousExposeStripEdge ? orig_continuousExposeStripEdge(self, _cmd) : 0;
}

#pragma mark 7) 能力函数与 MGGetBoolAnswer

static void *gSBFHandle = NULL;
static int SBXReturnOne(void) { return 1; }
static void SBXInstallCaps(void) {
    gSBFHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation", RTLD_GLOBAL);
    if (!gSBFHandle) { SBXLog(@"SpringBoardFoundation 打不开"); return; }
    // TrollPadEx 挂 6 个：窗口化 / 灵活窗口 / 外接显示
    const char *names[] = {
        "SBChamoisExternalDisplayControllerIsEnabled",
        "SBFIsChamoisExternalDisplayControllerAvailable",
        "SBFIsChamoisWindowingUIAvailable",
        "SBFIsFlexibleWindowingUIAvailable",
        "SBChamoisWindowingEnabled",
        "SBMedusaMultitaskingEnabled",
    };
    for (int i = 0; i < 6; i++) {
        void *fn = dlsym(gSBFHandle, names[i]);
        if (!fn) { SBXLog(@"能力函数缺失：%s", names[i]); continue; }
        SBXLoadSubstrate();
        if (!gHookFunc) continue;
        gHookFunc(fn, (void *)SBXReturnOne, NULL);
        SBXLog(@"已挂 C 函数：%s → 1", names[i]);
    }
}

static BOOL (*orig_mgBoolAnswer)(CFStringRef);
static BOOL hook_mgBoolAnswer(CFStringRef key) {
    if (SBXTake() && key && CFStringCompare(key, CFSTR("DeviceSupportsEnhancedMultitasking"), 0) == kCFCompareEqualTo) {
        return YES;
    }
    return orig_mgBoolAnswer ? orig_mgBoolAnswer(key) : NO;
}
static void SBXHookMGBool(void) {
    void *sym = dlsym(RTLD_DEFAULT, "MGGetBoolAnswer");
    if (!sym) {
        void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (mg) sym = dlsym(mg, "MGGetBoolAnswer");
    }
    if (!sym) { SBXLog(@"MGGetBoolAnswer 缺失"); return; }
    SBXLoadSubstrate();
    if (!gHookFunc) return;
    gHookFunc(sym, (void *)hook_mgBoolAnswer, (void **)&orig_mgBoolAnswer);
    SBXLog(@"已挂 MGGetBoolAnswer");
}

#pragma mark - ============ C. iPad 悬浮 Dock ============
static BOOL (*orig_isFloatingDockSupportedClass)(id, SEL);
static BOOL hook_isFloatingDockSupportedClass(id self, SEL _cmd) {
    if (DockOn()) return YES;
    return orig_isFloatingDockSupportedClass ? orig_isFloatingDockSupportedClass(self, _cmd) : NO;
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
static id (*orig_dockInit)(id, SEL, id, id);
static id hook_dockInit(id self, SEL _cmd, id winScene, id iconController) {
    id r = orig_dockInit ? orig_dockInit(self, _cmd, winScene, iconController) : nil;
    if (DockOn()) SBXLog(@"SBFloatingDockController init → %@", r ? @"建立" : @"nil");
    return r;
}
static id (*orig_dockWindow)(id, SEL);
static id hook_dockWindow(id self, SEL _cmd) {
    return orig_dockWindow ? orig_dockWindow(self, _cmd) : nil;
}
static double (*orig_translationVC)(id, SEL);
static double hook_translationVC(id self, SEL _cmd) {
    // 原版仅在"正在展示文件夹"时返回 0；其余透传，保留系统滑动动画
    return orig_translationVC ? orig_translationVC(self, _cmd) : 0.0;
}
static double (*orig_translationCtl)(id, SEL);
static double hook_translationCtl(id self, SEL _cmd) {
    return orig_translationCtl ? orig_translationCtl(self, _cmd) : 0.0;
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
static void (*orig_platterLayout)(id, SEL);
static void hook_platterLayout(id self, SEL _cmd) {
    if (orig_platterLayout) orig_platterLayout(self, _cmd);
}
static void (*orig_dockViewLayout)(id, SEL);
static void hook_dockViewLayout(id self, SEL _cmd) {
    if (orig_dockViewLayout) orig_dockViewLayout(self, _cmd);
}
static void (*orig_suggVisible)(id, SEL);
static void hook_suggVisible(id self, SEL _cmd) {
    if (orig_suggVisible) orig_suggVisible(self, _cmd);
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
            SBXLog(@"卡片后台：照 TrollPadEx 2.0.5 的 118 条 hook 还原");
            gCardOn = YES;
            gCardPad = SBXBool(@"cardStyle", NO);
            SBXLog(@"  主开关=1 全局Pad化=%d", gCardPad);

            // 1) 身份 / 方向
            HookMsg("UIDevice", "userInterfaceIdiom", (IMP)hook_idiom, (IMP *)&orig_idiom);
            HookMsg("UIApplication", "userInterfaceLayoutDirection", (IMP)hook_uilayoutDir, (IMP *)&orig_uilayoutDir);
            HookMsg("UIApplication", "_defaultSupportedInterfaceOrientations", (IMP)hook_defaultOrientations, (IMP *)&orig_defaultOrientations);
            HookMsg("SBHomeScreenViewController", "supportedInterfaceOrientations", (IMP)hook_homeScreenOrientations, (IMP *)&orig_homeScreenOrientations);
            HookMsg("SpringBoard", "homeScreenRotationStyle", (IMP)hook_homeScreenRotationStyle, (IMP *)&orig_homeScreenRotationStyle);
            HookMsg("SBTraitsSceneParticipantDelegate", "_isAllowedToHavePortraitUpsideDown", (IMP)hook_allowedUpsideDown, (IMP *)&orig_allowedUpsideDown);
            HookMsg("SBTraitsSceneParticipantDelegate", "_orientationMode", (IMP)hook_orientationMode, (IMP *)&orig_orientationMode);
            HookMsg("SBTraitsPipelineManager", "defaultOrientationAnimationSettingsAnimatable:", (IMP)hook_defaultOrientAnim, (IMP *)&orig_defaultOrientAnim);
            HookMsg("UISApplicationInitializationContext",
                    "initWithMainDisplayContext:launchDisplayContext:deviceContext:persistedSceneIdentifiers:supportAppSceneRequests:",
                    (IMP)hook_appInitContext, (IMP *)&orig_appInitContext);

            // 2) 切换器样式 / 尺寸
            HookMsg("SBAppSwitcherSettings", "effectiveSwitcherStyle", (IMP)hook_switcherStyle, (IMP *)&orig_switcherStyle);
            HookMsg("SBAppSwitcherSettings", "switcherStyle", (IMP)hook_switcherStyle2, (IMP *)&orig_switcherStyle2);
            HookMsg("SBAppSwitcherSettings", "setDefaultValues", (IMP)hook_swSettingsDefaults, (IMP *)&orig_swSettingsDefaults);
            HookMsg("SBAppSwitcherSettings", "setGridSwitcherPageScale:", (IMP)hook_setGridPageScale, (IMP *)&orig_setGridPageScale);
            HookMsg("SBAppSwitcherSettings", "setGridSwitcherVerticalNaturalSpacingPortrait:", (IMP)hook_setGridVSpacingP, (IMP *)&orig_setGridVSpacingP);
            HookMsg("SBAppSwitcherSettings", "setGridSwitcherVerticalNaturalSpacingLandscape:", (IMP)hook_setGridVSpacingL, (IMP *)&orig_setGridVSpacingL);
            HookMsg("SBAppSwitcherSettings", "setGridSwitcherHorizontalInterpageSpacingPortrait:", (IMP)hook_setGridHSpacingP, (IMP *)&orig_setGridHSpacingP);
            HookMsg("SBAppSwitcherSettings", "setGridSwitcherHorizontalInterpageSpacingLandscape:", (IMP)hook_setGridHSpacingL, (IMP *)&orig_setGridHSpacingL);
            HookMsg("SBSwitcherChamoisLayoutAttributes", "setGridWidths:", (IMP)hook_setGridWidths, (IMP *)&orig_setGridWidths);
            HookMsg("SBSwitcherChamoisLayoutAttributes", "setGridHeights:", (IMP)hook_setGridHeights, (IMP *)&orig_setGridHeights);
            HookMsg("SBSwitcherChamoisSettings", "maximumNumberOfAppsOnStage", (IMP)hook_maxAppsOnStage, (IMP *)&orig_maxAppsOnStage);
            HookMsg("SBFluidSwitcherViewController", "isDevicePad", (IMP)hook_isDevicePad, (IMP *)&orig_isDevicePad);

            // 3) 窗口管理 / 多任务能力
            HookMsg("SBMainWorkspace", "isMedusaEnabled", (IMP)hook_isMedusaEnabled, (IMP *)&orig_isMedusaEnabled);
            HookMsg("SBPlatformController", "medusaCapabilities", (IMP)hook_medusaCapabilities, (IMP *)&orig_medusaCapabilities);
            HookMsg("SBPlatformController", "isHomeGestureEnabled", (IMP)hook_platformHomeGesture, (IMP *)&orig_platformHomeGesture);
            HookMsg("SBApplication", "isMedusaCapable", (IMP)hook_isMedusaCapable, (IMP *)&orig_isMedusaCapable);
            HookMsg("SBApplication", "_supportsApplicationType:", (IMP)hook_supportsAppType, (IMP *)&orig_supportsAppType);
            HookMsg("SBApplication", "medusaMultitaskingEnabled", (IMP)hook_medusaMultitaskingEnabled, (IMP *)&orig_medusaMultitaskingEnabled);
            HookMsg("SBApplication", "chamoisWindowingEnabled", (IMP)hook_chamoisWindowingEnabled, (IMP *)&orig_chamoisWindowingEnabled);
            HookMsg("SBApplication", "supportsChamoisSceneResizing", (IMP)hook_chamoisSceneResizing, (IMP *)&orig_chamoisSceneResizing);
            HookMsg("SBApplication", "supportsChamoisViewResizing", (IMP)hook_chamoisViewResizing, (IMP *)&orig_chamoisViewResizing);
            HookMsg("SBApplication", "alwaysMaximizedInChamois", (IMP)hook_alwaysMaximizedInChamois, (IMP *)&orig_alwaysMaximizedInChamois);
            HookMsg("SBMedusaConfigurationUsageMetric", "_isFloatingActive", (IMP)hook_isFloatingActive, (IMP *)&orig_isFloatingActive);
            HookMsg("SBWindowScene", "supportsMultitasking", (IMP)hook_supportsMultitasking, (IMP *)&orig_supportsMultitasking);
            HookMsg("SBSwitcherController", "windowManagementStyle", (IMP)hook_windowManagementStyle, (IMP *)&orig_windowManagementStyle);

            // 4) 控制中心 / 手势
            HookMsg("CCSControlCenterDefaults", "_defaultPresentationGesture", (IMP)hook_defaultPresentationGesture, (IMP *)&orig_defaultPresentationGesture);
            HookMsg("SBHomeGestureSettings", "isHomeGestureEnabled", (IMP)hook_homeGestureEnabled, (IMP *)&orig_homeGestureEnabled);
            HookMsg("SBControlCenterController", "presentingEdge", (IMP)hook_presentingEdge, (IMP *)&orig_presentingEdge);

            // 5) 转场入口（包裹内退回 Phone）
            HookMsg("SBFullScreenSwitcherLiveContentOverlayCoordinator",
                    "layoutStateTransitionCoordinator:transitionDidBeginWithTransitionContext:",
                    (IMP)hook_overlayTransBegin, (IMP *)&orig_overlayTransBegin);
            HookMsg("SBMainSwitcherControllerCoordinator",
                    "_loadContentViewControllerIfNecessaryForWindowScene:",
                    (IMP)hook_loadContent, (IMP *)&orig_loadContent);
            HookMsg("SBSwitcherController", "_updateContentViewControllerIfNeeded",
                    (IMP)hook_updateContentVC, (IMP *)&orig_updateContentVC);

            // 6) 窗口管理修饰器（frame 系列）
            HookMsg("SBSwitcherModifier", "isRTLEnabled", (IMP)hook_isRTLEnabled, (IMP *)&orig_isRTLEnabled);
            HookMsg("SBSwitcherModifier", "scaledFrameForLayoutRole:inAppLayout:atIndex:", (IMP)hook_scaledFrameForRole, (IMP *)&orig_scaledFrameForRole);
            HookMsg("SBWindowingModifier", "isRTLEnabled", (IMP)hook_isRTLEnabled, (IMP *)&orig_isRTLEnabled);
            HookMsg("SBWindowingModifier", "_stripOriginX", (IMP)hook_stripOriginX, (IMP *)&orig_stripOriginX);
            HookMsg("SBWindowingModifier", "frameForItem:", (IMP)hook_frameForItem, (IMP *)&orig_frameForItem);
            HookMsg("SBWindowingModifier", "frameForLayoutRole:inAppLayout:withBounds:", (IMP)hook_frameForLayoutRole, (IMP *)&orig_frameForLayoutRole);
            HookMsg("SBWindowingModifier", "layoutViewModelsIfNeeded", (IMP)hook_layoutViewModelsIfNeeded, (IMP *)&orig_layoutViewModelsIfNeeded);
            HookMsg("SBWindowingModifier", "_continuousExposeStripEdge", (IMP)hook_continuousExposeStripEdge, (IMP *)&orig_continuousExposeStripEdge);
            HookMsg("SBStripLayoutWindowingModifier", "frameForItem:", (IMP)hook_frameForItem, (IMP *)&orig_frameForItem);
            HookMsg("SBStripLayoutWindowingModifier", "frameForLayoutRole:inAppLayout:withBounds:", (IMP)hook_frameForLayoutRole, (IMP *)&orig_frameForLayoutRole);
            HookMsg("SBStripLayoutWindowingModifier", "layoutViewModelsIfNeeded", (IMP)hook_layoutViewModelsIfNeeded, (IMP *)&orig_layoutViewModelsIfNeeded);
            HookMsg("SBExposeWindowingModifier", "frameForItem:", (IMP)hook_frameForItem, (IMP *)&orig_frameForItem);
            HookMsg("SBAppSwitcherContinuousExposeSwitcherModifier", "contentOffsetForIndex:alignment:", (IMP)hook_contentOffsetForIndex, (IMP *)&orig_contentOffsetForIndex);
            HookMsg("SBFlexibleWindowingHomeGestureSwitcherModifier", "frameForIndex:", (IMP)hook_frameForIndex, (IMP *)&orig_frameForIndex);
            HookMsg("SBFluidSwitcherGestureManager", "_continuousExposeStripEdge", (IMP)hook_continuousExposeStripEdge, (IMP *)&orig_continuousExposeStripEdge);
            HookMsg("SBContinuousExposeAppToInlineAppExposeSwitcherModifier", "frameForIndex:", (IMP)hook_frameForIndex, (IMP *)&orig_frameForIndex);
            HookMsg("SBContinuousExposeFullScreenCrossblurTransitionSwitcherModifier", "anchorPointForIndex:", (IMP)hook_anchorPointForIndex, (IMP *)&orig_anchorPointForIndex);
            HookMsg("SBContinuousExposeFullScreenCrossblurTransitionSwitcherModifier", "perspectiveAngleForAppLayout:", (IMP)hook_perspectiveAngleForLayout, (IMP *)&orig_perspectiveAngleForLayout);
            HookMsg("SBContinuousExposeHomeGestureSwitcherModifier", "_maxPerspectiveAngleForSelectedAppLayout", (IMP)hook_perspectiveAngleForLayout, (IMP *)&orig_perspectiveAngleForLayout);
            HookMsg("SBInlineAppExposeContinuousExposeSwitcherModifier", "frameForLayoutRole:inAppLayout:withBounds:", (IMP)hook_frameForLayoutRole, (IMP *)&orig_frameForLayoutRole);
            HookMsg("SBStripContinuousExposeSwitcherModifier", "_stripFrame", (IMP)hook_frameForIndex, (IMP *)&orig_frameForIndex);

            // 7) 能力函数
            SBXInstallCaps();
            SBXHookMGBool();
        }
        if (c) {
            // 原版/ TrollPad 都是 hook 这个【类方法】，不是 C 函数
            Class dockCls = objc_getClass("SBFloatingDockController");
            if (dockCls) {
                SEL cs = NSSelectorFromString(@"isFloatingDockSupported");
                Method cm = class_getClassMethod(dockCls, cs);
                if (cm) {
                    gHookMsgEx(object_getClass((id)dockCls), cs,
                               (IMP)hook_isFloatingDockSupportedClass,
                               (IMP *)&orig_isFloatingDockSupportedClass);
                    SBXLog(@"已挂类方法 +[SBFloatingDockController isFloatingDockSupported]");
                } else {
                    SBXLog(@"类方法不存在：+[SBFloatingDockController isFloatingDockSupported]");
                }
            } else {
                SBXLog(@"类不存在：SBFloatingDockController");
            }
            HookMsg("SBFloatingDockDefaults", "recentsEnabled", (IMP)hook_recentsEnabled, (IMP *)&orig_recentsEnabled);
            HookMsg("SBFloatingDockDefaults", "setRecentsEnabled:", (IMP)hook_setRecentsEnabled, (IMP *)&orig_setRecentsEnabled);
            HookMsg("SBFloatingDockDefaults", "appLibraryEnabled", (IMP)hook_appLibraryEnabled, (IMP *)&orig_appLibraryEnabled);
            HookMsg("SBFloatingDockDefaults", "setAppLibraryEnabled:", (IMP)hook_setAppLibraryEnabled, (IMP *)&orig_setAppLibraryEnabled);
            HookMsg("SBFloatingDockView", "updateDividerVisualStyling", (IMP)hook_updateDivider, (IMP *)&orig_updateDivider);
            HookMsg("SBFloatingDockView", "layoutSubviews", (IMP)hook_dockViewLayout, (IMP *)&orig_dockViewLayout);
            HookMsg("SBFloatingDockPlatterView", "layoutSubviews", (IMP)hook_platterLayout, (IMP *)&orig_platterLayout);
            HookMsg("SBFloatingDockController", "initWithWindowScene:iconController:", (IMP)hook_dockInit, (IMP *)&orig_dockInit);
            HookMsg("SBFloatingDockController", "floatingDockWindow", (IMP)hook_dockWindow, (IMP *)&orig_dockWindow);
            HookMsg("SBFloatingDockViewController", "translationFromFullyPresentedFrame", (IMP)hook_translationVC, (IMP *)&orig_translationVC);
            HookMsg("SBFloatingDockController", "translationFromFullyPresentedFrame", (IMP)hook_translationCtl, (IMP *)&orig_translationCtl);
            HookMsg("SBFloatingDockBehaviorAssertion", "gesturePossible", (IMP)hook_gesturePossible, (IMP *)&orig_gesturePossible);
            HookMsg("SBDeckSwitcherModifier", "shouldConfigureInAppDockHiddenAssertion", (IMP)hook_shouldHideInAppDock, (IMP *)&orig_shouldHideInAppDock);
            HookMsg("SBFloatingDockSuggestionsModel", "maxSuggestions", (IMP)hook_maxSuggestions, (IMP *)&orig_maxSuggestions);
            HookMsg("SBFloatingDockSuggestionsViewController", "dockViewDidBecomeVisible", (IMP)hook_suggVisible, (IMP *)&orig_suggVisible);
        }
        SBXLog(@"hook 安装完成");
    }
}
