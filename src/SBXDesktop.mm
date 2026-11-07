// SBXDesktop —— Feature 插件（从 SystemX 拆出的三组桌面功能）
// 钩子清单完全对照 SystemX 逆向映射表（Analysis/hooks.tsv，共 50 条）：
//   A. 后台一键清除按钮   B. iPad 卡片后台   C. iPad 悬浮 Dock
// 语义明确的直接实现；语义不明的先挂上打日志，便于下一轮定行为。
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
#define kSBXClearBtnTag 0x53425831

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

#pragma mark - substrate（运行时取，避免链接依赖）
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
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn((id)c, sel);
}
static id SBXIdCall(id obj, NSString *name) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn(obj, sel);
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
static BOOL ClearOn(void)  { return SBXBool(@"clearButton", NO); }
static BOOL CardsOn(void)  { return SBXBool(@"cardSwitcher", NO); }
static BOOL DockOn(void)   { return SBXBool(@"floatingDock", NO); }

#pragma mark - ============ 0) 液态玻璃（航的着色器）============
typedef struct {
    vector_float4 viewport, geometry, optical, appearance, tint, innerShadow, misc;
} LGUniforms;

@interface LGGlassButtonView : MTKView
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLTexture> bgTex;
@property (nonatomic) CGPoint bgOrigin;
@property (nonatomic) CGSize bgSize;
@property (nonatomic) float scale;
- (void)setBackdropImage:(UIImage *)img origin:(CGPoint)origin;
@end

@implementation LGGlassButtonView
- (id<MTLLibrary>)lgLoadLibrary:(NSError **)err {
    Dl_info info;
    if (dladdr((__bridge void *)[self class], &info) && info.dli_fname) {
        NSString *dir = [NSString stringWithUTF8String:info.dli_fname].stringByDeletingLastPathComponent;
        for (NSString *rel in @[@"../../share/glassclear/default.metallib",
                                @"../share/glassclear/default.metallib"]) {
            NSString *p = [dir stringByAppendingPathComponent:rel];
            if ([[NSFileManager defaultManager] fileExistsAtPath:p])
                return [self.device newLibraryWithFile:p error:err];
        }
    }
    for (NSString *p in @[@"/var/jb/usr/share/glassclear/default.metallib",
                          @"/usr/share/glassclear/default.metallib"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p])
            return [self.device newLibraryWithFile:p error:err];
    }
    if (err) *err = [NSError errorWithDomain:@"SBXGlass" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"metallib not found"}];
    return nil;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return nil;
    self.device = dev;
    self.opaque = NO; self.backgroundColor = UIColor.clearColor; self.userInteractionEnabled = NO;
    self.framebufferOnly = NO; self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.clearColor = MTLClearColorMake(0, 0, 0, 0); self.paused = YES; self.enableSetNeedsDisplay = YES;
    self.queue = [dev newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [self lgLoadLibrary:&err];
    if (!lib) { SBXLog(@"metallib 加载失败：%@", err.localizedDescription); return nil; }
    id<MTLFunction> vf = [lib newFunctionWithName:@"lgGlassVertex"];
    id<MTLFunction> ff = [lib newFunctionWithName:@"lgGlassFragment"];
    if (!vf || !ff) { SBXLog(@"着色器函数缺失"); return nil; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vf; d.fragmentFunction = ff;
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
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
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
    u.optical = (vector_float4){ 0.0f, 1.52f, 0.90f, 10.0f * s };
    u.appearance = (vector_float4){ 0.90f, 1.18f, 0.07f, 7.0f * s };
    u.tint = (vector_float4){ 1, 1, 1, 1 };
    u.innerShadow = (vector_float4){ 0, 0, 0, 2.5f * s };
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

static UIButton *SBXFindClearButton(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [(UIWindowScene *)sc windows]) {
            UIButton *b = (UIButton *)[w viewWithTag:kSBXClearBtnTag];
            if (b) return b;
        }
    }
    return nil;
}

static void SBXSetClearButtonVisible(BOOL vis) {
    UIButton *b = SBXFindClearButton();
    if (b) { b.hidden = !vis; SBXLog(@"清除按钮 %@", vis ? @"显示" : @"隐藏"); }
}

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPlaying;
- (id)nowPlayingApplication;
@end

static NSString *SBXNowPlayingBundleID(void) {
    Class c = NSClassFromString(@"SBMediaController"); if (!c) return nil;
    id mc = SBXClassCall(c, @"sharedInstance"); if (!mc) return nil;
    if (![(SBMediaController *)mc isPlaying]) return nil;
    id app = [(SBMediaController *)mc nowPlayingApplication]; if (!app) return nil;
    id bid = SBXIdCall(app, @"bundleIdentifier");
    return [bid isKindOfClass:NSString.class] ? bid : nil;
}

static void SBXKillAllBackgroundApps(void) {
    id coord = nil;
    for (NSString *cn in @[@"SBMainSwitcherControllerCoordinator", @"SBAppSwitcherController"]) {
        Class c = NSClassFromString(cn); if (!c) continue;
        coord = SBXClassCall(c, @"sharedInstanceIfExists");
        if (!coord) coord = SBXClassCall(c, @"sharedInstance");
        if (coord) { SBXLog(@"清除：控制器=%@", cn); break; }
    }
    if (!coord) { SBXLog(@"清除：找不到控制器"); return; }

    NSArray *layouts = nil;
    for (NSString *sel in @[@"recentAppLayouts", @"appLayouts", @"allItems"]) {
        id v = SBXIdCall(coord, sel);
        if ([v isKindOfClass:NSArray.class] && [v count]) { layouts = v; SBXLog(@"清除：卡片来源=%@ (%lu)", sel, (unsigned long)[v count]); break; }
    }
    if (!layouts.count) { SBXLog(@"清除：没有卡片（recentAppLayouts/appLayouts/allItems 都为空）"); return; }

    BOOL preserve = SBXBool(@"clearPreserveNowPlaying", YES);
    NSString *nowPlaying = preserve ? SBXNowPlayingBundleID() : nil;
    NSSet *whitelist = nil;
    id wlRaw = SBXPref(@"clearWhitelist");
    if ([wlRaw isKindOfClass:NSString.class] && [(NSString *)wlRaw length]) {
        NSArray *parts = [(NSString *)wlRaw componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@",， \n\r\t"]];
        NSMutableSet *s = [NSMutableSet set];
        for (NSString *p in parts) if (p.length) [s addObject:p];
        whitelist = s;
    }
    SEL delSel = NSSelectorFromString(@"_deleteAppLayoutsMatchingBundleIdentifier:");
    void (*delFn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    NSUInteger killed = 0, skipped = 0;
    for (id layout in layouts) {
        NSString *bid = nil;
        id v = SBXIdCall(layout, @"bundleIdentifier");
        if ([v isKindOfClass:NSString.class]) bid = v;
        if (!bid) { id item = SBXIdCall(layout, @"primaryDisplayItem");
                    id b = SBXIdCall(item, @"bundleIdentifier");
                    if ([b isKindOfClass:NSString.class]) bid = b; }
        if (!bid) continue;
        if (nowPlaying && [bid isEqualToString:nowPlaying]) { skipped++; continue; }
        if (whitelist && [whitelist containsObject:bid]) { skipped++; continue; }
        if ([coord respondsToSelector:delSel]) { delFn(coord, delSel, bid); killed++; }
    }
    SBXLog(@"清除完成：清除 %lu 个，跳过 %lu 个（保留播放=%@）",
           (unsigned long)killed, (unsigned long)skipped, nowPlaying ?: @"无");
    if (killed) {
        id c2 = SBXClassCall(NSClassFromString(@"SBMainSwitcherControllerCoordinator"), @"sharedInstanceIfExists");
        if ([c2 respondsToSelector:NSSelectorFromString(@"dismissMainSwitcherNoninteractivelyAnimated:")]) {
            void (*f2)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
            f2(c2, NSSelectorFromString(@"dismissMainSwitcherNoninteractivelyAnimated:"), YES);
            SBXLog(@"已收起后台切换器");
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
    SBXKillAllBackgroundApps();
}
@end
static SBXButtonTarget *gTarget = nil;

static UIButton *SBXMakeClearButton(void) {
    double size = SBXNum(@"clearButtonSize", 80, 40, 160);
    double font = SBXNum(@"clearFontSize", 16, 8, 40);
    CGFloat w = size * 0.8, h = size * 0.48, r = size * 0.24;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, w, h);
    b.tag = kSBXClearBtnTag;
    b.hidden = YES;
    b.clipsToBounds = YES;
    b.layer.cornerRadius = r;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.backgroundColor = UIColor.clearColor;
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:eff];
    blur.frame = b.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    blur.tag = 0x53425832;
    blur.layer.cornerRadius = r;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.clipsToBounds = YES;
    [b insertSubview:blur atIndex:0];
    b.titleLabel.font = [UIFont systemFontOfSize:font weight:UIFontWeightMedium];
    [b setTitle:@"清除" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    if (!gTarget) gTarget = [SBXButtonTarget new];
    [b addTarget:gTarget action:NSSelectorFromString(@"handleClear:") forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// 液态玻璃（失败自动保留系统材质）
static void SBXAttachGlass(UIButton *b) {
    static char kGlassKey;
    if (!b || objc_getAssociatedObject(b, &kGlassKey)) return;
    if (!SBXBool(@"clearGlass", YES)) return;
    UIWindow *win = b.window; if (!win) return;
    UIVisualEffectView *blur = (UIVisualEffectView *)[b viewWithTag:0x53425832];
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
    SBXLog(@"清除按钮已套液态玻璃");
}

// 位置：在 viewDidLoad 里建、layout 里摆（照 SystemX 的钩子表）
static void (*orig_switcherViewDidLoad)(id, SEL);
static void hook_switcherViewDidLoad(id self, SEL _cmd) {
    if (orig_switcherViewDidLoad) orig_switcherViewDidLoad(self, _cmd);
    if (!ClearOn()) return;
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = (UIViewController *)self;
    if ([vc.view viewWithTag:kSBXClearBtnTag]) return;
    UIButton *b = SBXMakeClearButton();
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:b];
    double bottom = SBXNum(@"clearBottomOffset", 60, 0, 300);
    [NSLayoutConstraint activateConstraints:@[
        [b.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [b.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-bottom],
        [b.widthAnchor constraintEqualToConstant:b.bounds.size.width],
        [b.heightAnchor constraintEqualToConstant:b.bounds.size.height],
    ]];
    SBXLog(@"viewDidLoad：已创建清除按钮 %.0fx%.0f 底距 %.0f",
           b.bounds.size.width, b.bounds.size.height, bottom);
}

static void (*orig_vcLayout)(id, SEL);
static void hook_vcLayout(id self, SEL _cmd) {
    if (orig_vcLayout) orig_vcLayout(self, _cmd);
    if (!ClearOn()) return;
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = (UIViewController *)self;
    UIButton *b = (UIButton *)[vc.view viewWithTag:kSBXClearBtnTag];
    if (b && b.bounds.size.width > 4) SBXAttachGlass(b);
}

// 显示/隐藏：协调器转场回调
static void (*orig_trBegin)(id, SEL, id, id);
static void hook_trBegin(id self, SEL _cmd, id coord, id ctx) {
    if (orig_trBegin) orig_trBegin(self, _cmd, coord, ctx);
    if (ClearOn()) SBXSetClearButtonVisible(YES);
}
static void (*orig_trWillEnd)(id, SEL, id, id);
static void hook_trWillEnd(id self, SEL _cmd, id coord, id ctx) {
    if (orig_trWillEnd) orig_trWillEnd(self, _cmd, coord, ctx);
}
static void (*orig_trDidEnd)(id, SEL, id, id);
static void hook_trDidEnd(id self, SEL _cmd, id coord, id ctx) {
    if (orig_trDidEnd) orig_trDidEnd(self, _cmd, coord, ctx);
    if (ClearOn()) SBXSetClearButtonVisible(NO);
}
static id (*orig_loadContent)(id, SEL, id);
static id hook_loadContent(id self, SEL _cmd, id winScene) {
    id r = orig_loadContent ? orig_loadContent(self, _cmd, winScene) : nil;
    if (ClearOn()) SBXLog(@"_loadContentViewControllerIfNecessary → %@", r ? @"有" : @"nil");
    return r;
}

#pragma mark - ============ B. iPad 卡片后台 ============

static BOOL (*orig_isDevicePad)(id, SEL);
static BOOL hook_isDevicePad(id self, SEL _cmd) {
    if (CardsOn()) return YES;
    return orig_isDevicePad ? orig_isDevicePad(self, _cmd) : NO;
}
static long (*orig_switcherStyle)(id, SEL);
static long hook_switcherStyle(id self, SEL _cmd) {
    long v = orig_switcherStyle ? orig_switcherStyle(self, _cmd) : 0;
    if (CardsOn()) SBXLog(@"effectiveSwitcherStyle 原值=%ld", v);
    return v;
}
static double (*orig_gridPageScale)(id, SEL);
static double hook_gridPageScale(id self, SEL _cmd) {
    double v = orig_gridPageScale ? orig_gridPageScale(self, _cmd) : 1.0;
    return CardsOn() ? v * SBXNum(@"cardScale", 1.0, 0.1, 2.0) : v;
}
static double (*orig_gridHSpacing)(id, SEL);
static double hook_gridHSpacing(id self, SEL _cmd) {
    double v = orig_gridHSpacing ? orig_gridHSpacing(self, _cmd) : 1.0;
    return CardsOn() ? v * SBXNum(@"cardHSpacing", 1.0, 0.1, 2.0) : v;
}
static double (*orig_gridVSpacing)(id, SEL);
static double hook_gridVSpacing(id self, SEL _cmd) {
    double v = orig_gridVSpacing ? orig_gridVSpacing(self, _cmd) : 1.0;
    return CardsOn() ? v * SBXNum(@"cardVSpacing", 1.0, 0.1, 2.0) : v;
}
static void (*orig_setDefaultValues)(id, SEL);
static void hook_setDefaultValues(id self, SEL _cmd) {
    if (orig_setDefaultValues) orig_setDefaultValues(self, _cmd);
    if (CardsOn()) SBXLog(@"SBAppSwitcherSettings setDefaultValues 已调用");
}
static void (*orig_homeScaleApp)(id, SEL, double);
static void hook_homeScaleApp(id self, SEL _cmd, double v) {
    if (orig_homeScaleApp) orig_homeScaleApp(self, _cmd, v);
    if (CardsOn()) SBXLog(@"HomeScreenScaleInApplication=%.3f", v);
}
static void (*orig_homeScaleSw)(id, SEL, double);
static void hook_homeScaleSw(id self, SEL _cmd, double v) {
    if (orig_homeScaleSw) orig_homeScaleSw(self, _cmd, v);
    if (CardsOn()) SBXLog(@"HomeScreenScaleInSwitcher=%.3f", v);
}
static BOOL (*orig_gridVisible)(id, SEL);
static BOOL hook_gridVisible(id self, SEL _cmd) {
    if (CardsOn()) return YES;
    return orig_gridVisible ? orig_gridVisible(self, _cmd) : YES;
}
static id (*orig_scrollToBefore)(id, SEL, id);
static id hook_scrollToBefore(id self, SEL _cmd, id layout) {
    if (CardsOn()) return nil;
    return orig_scrollToBefore ? orig_scrollToBefore(self, _cmd, layout) : nil;
}
static void (*orig_scrollEnabled)(id, SEL, BOOL);
static void hook_scrollEnabled(id self, SEL _cmd, BOOL e) {
    if (orig_scrollEnabled) orig_scrollEnabled(self, _cmd, CardsOn() ? YES : e);
}
static void (*orig_scrollDidMove)(id, SEL);
static void hook_scrollDidMove(id self, SEL _cmd) {
    if (orig_scrollDidMove) orig_scrollDidMove(self, _cmd);
    if (CardsOn()) SBXLog(@"SBAppSwitcherScrollView didMoveToWindow");
}
static void (*orig_iconContainerDidMove)(id, SEL);
static void hook_iconContainerDidMove(id self, SEL _cmd) {
    if (orig_iconContainerDidMove) orig_iconContainerDidMove(self, _cmd);
    if (CardsOn()) SBXLog(@"SBFluidSwitcherIconImageContainerView didMoveToWindow");
}

#pragma mark - ============ C. iPad 悬浮 Dock ============

static BOOL (*orig_isFloatingDockSupported)(void);
static BOOL hook_isFloatingDockSupported(void) {
    if (DockOn()) return YES;
    return orig_isFloatingDockSupported ? orig_isFloatingDockSupported() : NO;
}
static BOOL (*orig_recentsEnabled)(id, SEL);
static BOOL hook_recentsEnabled(id self, SEL _cmd) {
    if (!DockOn()) return orig_recentsEnabled ? orig_recentsEnabled(self, _cmd) : NO;
    NSInteger c = (NSInteger)SBXNum(@"dockContent", 0, 0, 3);
    return (c == 0 || c == 2);
}
static void (*orig_setRecentsEnabled)(id, SEL, BOOL);
static void hook_setRecentsEnabled(id self, SEL _cmd, BOOL v) {
    if (orig_setRecentsEnabled) orig_setRecentsEnabled(self, _cmd, DockOn() ? hook_recentsEnabled(self, _cmd) : v);
}
static BOOL (*orig_appLibraryEnabled)(id, SEL);
static BOOL hook_appLibraryEnabled(id self, SEL _cmd) {
    if (!DockOn()) return orig_appLibraryEnabled ? orig_appLibraryEnabled(self, _cmd) : NO;
    NSInteger c = (NSInteger)SBXNum(@"dockContent", 0, 0, 3);
    return (c == 1 || c == 2);
}
static void (*orig_setAppLibraryEnabled)(id, SEL, BOOL);
static void hook_setAppLibraryEnabled(id self, SEL _cmd, BOOL v) {
    if (orig_setAppLibraryEnabled) orig_setAppLibraryEnabled(self, _cmd, DockOn() ? hook_appLibraryEnabled(self, _cmd) : v);
}
static void (*orig_updateDivider)(id, SEL);
static void hook_updateDivider(id self, SEL _cmd) {
    if (DockOn() && SBXBool(@"hideSeparator", NO)) return;
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
    id r = orig_dockWindow ? orig_dockWindow(self, _cmd) : nil;
    if (DockOn()) SBXLog(@"floatingDockWindow → %@", r ? @"有" : @"nil");
    return r;
}
static double (*orig_translationVC)(id, SEL);
static double hook_translationVC(id self, SEL _cmd) {
    if (DockOn()) return 0.0;
    return orig_translationVC ? orig_translationVC(self, _cmd) : 0.0;
}
static double (*orig_translationCtl)(id, SEL);
static double hook_translationCtl(id self, SEL _cmd) {
    if (DockOn()) return 0.0;
    return orig_translationCtl ? orig_translationCtl(self, _cmd) : 0.0;
}
static BOOL (*orig_gesturePossible)(id, SEL);
static BOOL hook_gesturePossible(id self, SEL _cmd) {
    if (DockOn()) return YES;
    return orig_gesturePossible ? orig_gesturePossible(self, _cmd) : NO;
}
static BOOL (*orig_shouldHideInAppDock)(id, SEL);
static BOOL hook_shouldHideInAppDock(id self, SEL _cmd) {
    if (DockOn() && SBXBool(@"showInApps", NO)) return NO;
    return orig_shouldHideInAppDock ? orig_shouldHideInAppDock(self, _cmd) : YES;
}
// 以下为布局/数量相关，先挂上打日志（下一轮按日志定行为）
static void (*orig_dockViewLayout)(id, SEL);
static void hook_dockViewLayout(id self, SEL _cmd) {
    if (orig_dockViewLayout) orig_dockViewLayout(self, _cmd);
    if (DockOn()) SBXLog(@"SBFloatingDockView layoutSubviews");
}
static void (*orig_platterLayout)(id, SEL);
static void hook_platterLayout(id self, SEL _cmd) {
    if (orig_platterLayout) orig_platterLayout(self, _cmd);
    if (DockOn()) SBXLog(@"SBFloatingDockPlatterView layoutSubviews");
}
static void (*orig_platterTrait)(id, SEL);
static void hook_platterTrait(id self, SEL _cmd) {
    if (orig_platterTrait) orig_platterTrait(self, _cmd);
}
static void (*orig_iconListLayout)(id, SEL);
static void hook_iconListLayout(id self, SEL _cmd) {
    if (orig_iconListLayout) orig_iconListLayout(self, _cmd);
}
static void (*orig_suggVisible)(id, SEL);
static void hook_suggVisible(id self, SEL _cmd) {
    if (orig_suggVisible) orig_suggVisible(self, _cmd);
    if (DockOn()) SBXLog(@"SBFloatingDockSuggestionsViewController dockViewDidBecomeVisible");
}
static unsigned long (*orig_maxSuggestions)(id, SEL);
static unsigned long hook_maxSuggestions(id self, SEL _cmd) {
    unsigned long v = orig_maxSuggestions ? orig_maxSuggestions(self, _cmd) : 4;
    if (DockOn()) { v = (unsigned long)SBXNum(@"dockIconCount", 4, 1, 10); SBXLog(@"maxSuggestions → %lu", v); }
    return v;
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
        SBXLog(@"==== SBXDesktop 装载：清除按钮=%@ 卡片后台=%@ 悬浮Dock=%@ ====",
               a ? @"开" : @"关", b ? @"开" : @"关", c ? @"开" : @"关");
        if (!a && !b && !c) { SBXLog(@"三项都未启用，跳过全部 hook"); return; }
        SBXLoadSubstrate();
        if (!gHookMsgEx) { SBXLog(@"substrate 不可用，放弃挂载"); return; }

        if (a) {
            HookMsg("SBFluidSwitcherViewController", "viewDidLoad", (IMP)hook_switcherViewDidLoad, (IMP *)&orig_switcherViewDidLoad);
            HookMsg("SBFluidSwitcherViewController", "viewDidLayoutSubviews", (IMP)hook_vcLayout, (IMP *)&orig_vcLayout);
            HookMsg("SBMainSwitcherControllerCoordinator",
                    "layoutStateTransitionCoordinator:transitionDidBeginWithTransitionContext:", (IMP)hook_trBegin, (IMP *)&orig_trBegin);
            HookMsg("SBMainSwitcherControllerCoordinator",
                    "layoutStateTransitionCoordinator:transitionWillEndWithTransitionContext:", (IMP)hook_trWillEnd, (IMP *)&orig_trWillEnd);
            HookMsg("SBMainSwitcherControllerCoordinator",
                    "layoutStateTransitionCoordinator:transitionDidEndWithTransitionContext:", (IMP)hook_trDidEnd, (IMP *)&orig_trDidEnd);
            HookMsg("SBMainSwitcherControllerCoordinator", "_loadContentViewControllerIfNecessaryForWindowScene:", (IMP)hook_loadContent, (IMP *)&orig_loadContent);
        }
        if (b) {
            HookMsg("SBFluidSwitcherViewController", "isDevicePad", (IMP)hook_isDevicePad, (IMP *)&orig_isDevicePad);
            HookMsg("SBAppSwitcherSettings", "effectiveSwitcherStyle", (IMP)hook_switcherStyle, (IMP *)&orig_switcherStyle);
            HookMsg("SBAppSwitcherSettings", "gridSwitcherPageScale", (IMP)hook_gridPageScale, (IMP *)&orig_gridPageScale);
            HookMsg("SBAppSwitcherSettings", "gridSwitcherHorizontalInterpageSpacingPortrait", (IMP)hook_gridHSpacing, (IMP *)&orig_gridHSpacing);
            HookMsg("SBAppSwitcherSettings", "gridSwitcherVerticalNaturalSpacingPortrait", (IMP)hook_gridVSpacing, (IMP *)&orig_gridVSpacing);
            HookMsg("SBAppSwitcherSettings", "setDefaultValues", (IMP)hook_setDefaultValues, (IMP *)&orig_setDefaultValues);
            HookMsg("SBFluidSwitcherAnimationSettings", "setHomeScreenScaleInApplication:", (IMP)hook_homeScaleApp, (IMP *)&orig_homeScaleApp);
            HookMsg("SBFluidSwitcherAnimationSettings", "setHomeScreenScaleInSwitcher:", (IMP)hook_homeScaleSw, (IMP *)&orig_homeScaleSw);
            HookMsg("_SBGridFloorSwitcherModifier", "isSwitcherWindowVisible", (IMP)hook_gridVisible, (IMP *)&orig_gridVisible);
            HookMsg("_SBGridFloorSwitcherModifier", "appLayoutToScrollToBeforeTransitioning", (IMP)hook_scrollToBefore, (IMP *)&orig_scrollToBefore);
            HookMsg("SBAppSwitcherScrollView", "setScrollEnabled:", (IMP)hook_scrollEnabled, (IMP *)&orig_scrollEnabled);
            HookMsg("SBAppSwitcherScrollView", "didMoveToWindow", (IMP)hook_scrollDidMove, (IMP *)&orig_scrollDidMove);
            HookMsg("SBFluidSwitcherIconImageContainerView", "didMoveToWindow", (IMP)hook_iconContainerDidMove, (IMP *)&orig_iconContainerDidMove);
        }
        if (c) {
            void *sym = dlsym(RTLD_DEFAULT, "isFloatingDockSupported");
            SBXLog(@"isFloatingDockSupported 符号=%p", sym);
            if (sym && gHookFunc) { gHookFunc(sym, (void *)hook_isFloatingDockSupported, (void **)&orig_isFloatingDockSupported); SBXLog(@"已挂 isFloatingDockSupported"); }
            HookMsg("SBFloatingDockDefaults", "recentsEnabled", (IMP)hook_recentsEnabled, (IMP *)&orig_recentsEnabled);
            HookMsg("SBFloatingDockDefaults", "setRecentsEnabled:", (IMP)hook_setRecentsEnabled, (IMP *)&orig_setRecentsEnabled);
            HookMsg("SBFloatingDockDefaults", "appLibraryEnabled", (IMP)hook_appLibraryEnabled, (IMP *)&orig_appLibraryEnabled);
            HookMsg("SBFloatingDockDefaults", "setAppLibraryEnabled:", (IMP)hook_setAppLibraryEnabled, (IMP *)&orig_setAppLibraryEnabled);
            HookMsg("SBFloatingDockView", "updateDividerVisualStyling", (IMP)hook_updateDivider, (IMP *)&orig_updateDivider);
            HookMsg("SBFloatingDockView", "layoutSubviews", (IMP)hook_dockViewLayout, (IMP *)&orig_dockViewLayout);
            HookMsg("SBFloatingDockPlatterView", "layoutSubviews", (IMP)hook_platterLayout, (IMP *)&orig_platterLayout);
            HookMsg("SBFloatingDockPlatterView", "_dynamicUserInterfaceTraitDidChange", (IMP)hook_platterTrait, (IMP *)&orig_platterTrait);
            HookMsg("SBFloatingDockController", "initWithWindowScene:iconController:", (IMP)hook_dockInit, (IMP *)&orig_dockInit);
            HookMsg("SBFloatingDockController", "floatingDockWindow", (IMP)hook_dockWindow, (IMP *)&orig_dockWindow);
            HookMsg("SBFloatingDockViewController", "translationFromFullyPresentedFrame", (IMP)hook_translationVC, (IMP *)&orig_translationVC);
            HookMsg("SBFloatingDockController", "translationFromFullyPresentedFrame", (IMP)hook_translationCtl, (IMP *)&orig_translationCtl);
            HookMsg("SBFloatingDockBehaviorAssertion", "gesturePossible", (IMP)hook_gesturePossible, (IMP *)&orig_gesturePossible);
            HookMsg("SBDeckSwitcherModifier", "shouldConfigureInAppDockHiddenAssertion", (IMP)hook_shouldHideInAppDock, (IMP *)&orig_shouldHideInAppDock);
            HookMsg("SBFloatingDockIconListView", "layoutSubviews", (IMP)hook_iconListLayout, (IMP *)&orig_iconListLayout);
            HookMsg("SBFloatingDockSuggestionsViewController", "dockViewDidBecomeVisible", (IMP)hook_suggVisible, (IMP *)&orig_suggVisible);
            HookMsg("SBFloatingDockSuggestionsModel", "maxSuggestions", (IMP)hook_maxSuggestions, (IMP *)&orig_maxSuggestions);
        }
        SBXLog(@"hook 安装完成");
    }
}
