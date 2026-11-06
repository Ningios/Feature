// SBXDesktop —— 从 SystemX 拆出的「桌面功能」独立插件（三组合一）
//   1) 后台一键清除按钮（自绘按钮 + 删应用卡片 + 保留正在播放 + 白名单 + 字号/尺寸）
//   2) iPad 卡片后台（isDevicePad + 卡片大小/水平间距/垂直间距）
//   3) iPad 悬浮 Dock（悬浮开关 + 后台/应用内显示 + 右侧显示 + 数量 + 隐藏分隔线）
// 只注入 SpringBoard；偏好域 com.ning.feature；带完整设置页。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// substrate 的两个函数在运行时用 dlsym 取，避免链接期依赖 libsubstrate
typedef void (*SBXHookMsgEx_t)(Class, SEL, IMP, IMP *);
typedef void (*SBXHookFunction_t)(void *, void *, void **);
static SBXHookMsgEx_t gHookMsgEx = NULL;
static SBXHookFunction_t gHookFunction = NULL;

static void SBXLoadSubstrate(void) {
    if (!gHookMsgEx) gHookMsgEx = (SBXHookMsgEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!gHookFunction) gHookFunction = (SBXHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
}

#define SBDOMAIN "com.ning.feature"
#define LOGPATH  "/var/mobile/Library/Accessibility/feature.log"

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


// 安全调用实例方法（避免 performSelector 的 ARC 警告）
static id SBXIdCall(id obj, NSString *name) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn(obj, sel);
}

// 安全地调用类方法（避免 performSelector 的 ARC 警告）
static id SBXClassCall(Class c, NSString *name) {
    if (!c) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![c respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn((id)c, sel);
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

#pragma mark - ============ 0) 液态玻璃渲染（航的着色器，Metal）============
// 把航那段自包含的 liquid glass fragment（shader/glass.metal）编译成 metallib，
// 由本类在按钮位置渲染：圆角 SDF + 边缘折射 + 色散 + 边缘高光 + 内阴影 + tint。
// 拿不到 metallib / Metal 不可用时返回 nil，调用方回退系统材质。

typedef struct {
    vector_float4 viewport;      // xy=底图像素尺寸，zw=按钮在底图中的像素原点
    vector_float4 geometry;      // xy=按钮像素尺寸，z=圆角，w=边缘带宽
    vector_float4 optical;       // x=折射高度，y=折射率，z=折射强度，w=采样模糊
    vector_float4 appearance;    // x=高光强度，y=饱和度，z=tint 比例，w=内阴影模糊
    vector_float4 tint;
    vector_float4 innerShadow;
    vector_float4 misc;          // y=高度曲线模式
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
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;
    self.framebufferOnly = NO;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.paused = YES;
    self.enableSetNeedsDisplay = YES;
    self.queue = [dev newCommandQueue];

    NSError *err = nil;
    id<MTLLibrary> lib = [self lgLoadLibrary:&err];
    if (!lib) { SBXLog(@"metallib 加载失败：%@", err.localizedDescription); return nil; }
    id<MTLFunction> vf = [lib newFunctionWithName:@"lgGlassVertex"];
    id<MTLFunction> ff = [lib newFunctionWithName:@"lgGlassFragment"];
    if (!vf || !ff) { SBXLog(@"着色器函数缺失"); return nil; }

    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vf;
    d.fragmentFunction = ff;
    d.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    self.pipeline = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!self.pipeline) { SBXLog(@"管线创建失败：%@", err.localizedDescription); return nil; }
    SBXLog(@"液态玻璃已就绪");
    return self;
}

- (void)setBackdropImage:(UIImage *)img origin:(CGPoint)origin {
    CGImageRef cg = img.CGImage;
    if (!cg) return;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [self.device newTextureWithDescriptor:td];
    if (!tex) return;
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
    self.bgTex = tex;
    self.bgSize = CGSizeMake(w, h);
    self.bgOrigin = origin;
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
    u.viewport    = (vector_float4){ (float)self.bgSize.width, (float)self.bgSize.height,
                                     (float)self.bgOrigin.x * s, (float)self.bgOrigin.y * s };
    float radius  = h * 0.5f;
    float bezel   = MAX(3.0f, MIN(h * 0.34f, 14.0f * s));
    u.geometry    = (vector_float4){ w, h, radius, bezel };
    u.optical     = (vector_float4){ 0.0f, 1.52f, 0.90f, 10.0f * s };
    u.appearance  = (vector_float4){ 0.90f, 1.18f, 0.07f, 7.0f * s };
    u.tint        = (vector_float4){ 1.0f, 1.0f, 1.0f, 1.0f };
    u.innerShadow = (vector_float4){ 0.0f, 0.0f, 0.0f, 2.5f * s };
    u.misc        = (vector_float4){ 0.0f, 0.0f, 0.0f, 0.0f };

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

#pragma mark - ============ 1) 后台一键清除按钮 ============

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPlaying;
- (id)nowPlayingApplication;
@end

static NSString *SBXNowPlayingBundleID(void) {
    Class c = NSClassFromString(@"SBMediaController");
    if (!c) return nil;
    id mc = nil;
    if ([c respondsToSelector:@selector(sharedInstance)]) mc = [c sharedInstance];
    if (!mc) return nil;
    BOOL playing = [(SBMediaController *)mc isPlaying];
    if (!playing) return nil;
    id app = [(SBMediaController *)mc nowPlayingApplication];
    if (!app) return nil;
    id bid = SBXIdCall(app, @"bundleIdentifier");
    if ([bid isKindOfClass:NSString.class]) return bid;
    return nil;
}

static void SBXKillAllBackgroundApps(void) {
    id coord = nil;
    for (NSString *cn in @[@"SBMainSwitcherControllerCoordinator", @"SBAppSwitcherController"]) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        coord = SBXClassCall(c, @"sharedInstanceIfExists");
        if (!coord) coord = SBXClassCall(c, @"sharedInstance");
        if (coord) { SBXLog(@"清除后台：控制器 = %@", cn); break; }
    }
    if (!coord) { SBXLog(@"清除后台：找不到切换器控制器"); return; }

    NSArray *layouts = nil;
    for (NSString *sel in @[@"recentAppLayouts", @"allItems"]) {
        if ([coord respondsToSelector:NSSelectorFromString(sel)]) {
            layouts = [coord valueForKey:sel];
            if (layouts.count) break;
        }
    }
    if (!layouts.count) { SBXLog(@"清除后台：没有卡片"); return; }

    BOOL preserve = SBXBool(@"clearPreserveNowPlaying", YES);
    NSString *nowPlaying = preserve ? SBXNowPlayingBundleID() : nil;
    NSSet *whitelist = nil;
    id wlRaw = SBXPref(@"clearWhitelist");
    if ([wlRaw isKindOfClass:NSArray.class]) {
        whitelist = [NSSet setWithArray:wlRaw];
    } else if ([wlRaw isKindOfClass:NSString.class] && [(NSString *)wlRaw length]) {
        NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@",， \n\r\t"];
        NSArray *parts = [(NSString *)wlRaw componentsSeparatedByCharactersInSet:sep];
        NSMutableSet *s = [NSMutableSet set];
        for (NSString *p in parts) if (p.length) [s addObject:p];
        whitelist = s;
    }

    SEL delSel = NSSelectorFromString(@"_deleteAppLayoutsMatchingBundleIdentifier:");
    NSUInteger killed = 0, skipped = 0;
    for (id layout in layouts) {
        NSString *bid = nil;
        for (NSString *k in @[@"bundleIdentifier", @"primaryDisplayItem"]) {
            @try { id v = [layout valueForKey:k];
                if ([v isKindOfClass:NSString.class]) bid = v;
                else if (v) { id b = [v valueForKey:@"bundleIdentifier"]; if ([b isKindOfClass:NSString.class]) bid = b; }
            } @catch (__unused NSException *e) {}
            if (bid) break;
        }
        if (!bid) continue;
        if (nowPlaying && [bid isEqualToString:nowPlaying]) { skipped++; continue; }
        if (whitelist && [whitelist containsObject:bid]) { skipped++; continue; }
        if ([coord respondsToSelector:delSel]) {
            void (*delFn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
            delFn(coord, delSel, bid);
            killed++;
        }
    }
    SBXLog(@"清除后台：已清除 %lu 个，跳过 %lu 个（保留播放=%@）",
           (unsigned long)killed, (unsigned long)skipped, nowPlaying ?: @"无");
}

static const int kSBXClearBtnTag = 0x53425831;   // 'SBX1'

static UIButton *SBXMakeClearButton(void) {
    double size = SBXNum(@"clearButtonSize", 80, 40, 160);
    double font = SBXNum(@"clearFontSize", 16, 8, 40);
    CGFloat w = size * 0.8, h = size * 0.48, r = size * 0.24;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, w, h);
    b.tag = kSBXClearBtnTag;
    b.clipsToBounds = YES;
    b.layer.cornerRadius = r;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.backgroundColor = UIColor.clearColor;

    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:eff];
    blur.frame = b.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    blur.tag = 0x53425832;                 // 回退用的系统材质（Metal 玻璃成功后会隐藏）
    blur.layer.cornerRadius = r;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.clipsToBounds = YES;
    [b insertSubview:blur atIndex:0];

    b.titleLabel.font = [UIFont systemFontOfSize:font weight:UIFontWeightMedium];
    [b setTitle:@"清除" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    return b;   // 事件由调用方统一挂到单例 target 上
}

@interface SBXDesktopButtonTarget : NSObject
- (void)handleClear:(UIButton *)sender;
@end
@implementation SBXDesktopButtonTarget
- (void)handleClear:(UIButton *)sender {
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [g prepare]; [g impactOccurred];
    SBXKillAllBackgroundApps();
}
@end

static SBXDesktopButtonTarget *gButtonTarget = nil;

// 给按钮套上航的液态玻璃（Metal）。任何一步失败就保持系统材质，不崩。
static void SBXAttachGlassForButton(UIButton *b, UIView *host) {
    static char kGlassKey;
    if (!b || objc_getAssociatedObject(b, &kGlassKey)) return;
    if (!SBXBool(@"clearGlass", YES)) return;
    UIWindow *win = b.window;
    if (!win) return;

    UIVisualEffectView *blur = (UIVisualEffectView *)[b viewWithTag:0x53425832];
    CGRect inWin = [b convertRect:b.bounds toView:win];
    CGFloat blurA = blur.alpha, btnA = b.alpha;
    if (blur) blur.alpha = 0;
    b.alpha = 0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = win.screen.scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:win.bounds format:fmt];
    UIImage *shot = [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
    }];
    b.alpha = btnA;
    if (blur) blur.alpha = blurA;
    if (!shot) { SBXLog(@"截图失败，保留系统材质"); return; }

    LGGlassButtonView *g = [[LGGlassButtonView alloc] initWithFrame:b.bounds];
    if (!g) { SBXLog(@"Metal 不可用，保留系统材质"); return; }
    g.scale = (float)win.screen.scale;
    g.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [g setBackdropImage:shot origin:CGPointMake(inWin.origin.x, inWin.origin.y)];
    [b insertSubview:g atIndex:0];
    if (blur) blur.alpha = 0;        // 系统材质让位
    objc_setAssociatedObject(b, &kGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SBXLog(@"按钮已套液态玻璃 %@", NSStringFromCGRect(b.bounds));
}

static void SBXLayoutClearButton(UIViewController *vc) {
    if (!SBXBool(@"clearButton", NO)) return;
    UIView *host = vc.view;
    if (!host) return;
    UIButton *b = [host viewWithTag:kSBXClearBtnTag];
    if (!b) {
        if (!gButtonTarget) gButtonTarget = [SBXDesktopButtonTarget new];
        b = SBXMakeClearButton();
        // 把 target 指到我们的单例
        [b removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [b addTarget:gButtonTarget action:NSSelectorFromString(@"handleClear:")
            forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:b];
        // 用约束贴底
        b.translatesAutoresizingMaskIntoConstraints = NO;
        double bottom = SBXNum(@"clearBottomOffset", 60, 0, 300);
        [NSLayoutConstraint activateConstraints:@[
            [b.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
            [b.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:-bottom],
            [b.widthAnchor constraintEqualToConstant:b.bounds.size.width],
            [b.heightAnchor constraintEqualToConstant:b.bounds.size.height],
        ]];
        SBXLog(@"已在切换器放置清除按钮 %.0fx%.0f 底距 %.0f", b.bounds.size.width, b.bounds.size.height, bottom);
    }
    b.hidden = NO;
    if (b.bounds.size.width > 4) SBXAttachGlassForButton(b, host);
}

#pragma mark - ============ 2) iPad 卡片后台 ============

static BOOL (*orig_isDevicePad)(id, SEL);
static BOOL hook_isDevicePad(id self, SEL _cmd) {
    if (SBXBool(@"cardSwitcher", NO)) return YES;
    return orig_isDevicePad ? orig_isDevicePad(self, _cmd) : NO;
}

static double (*orig_gridPageScale)(id, SEL);
static double hook_gridPageScale(id self, SEL _cmd) {
    double v = orig_gridPageScale ? orig_gridPageScale(self, _cmd) : 1.0;
    if (!SBXBool(@"cardSwitcher", NO)) return v;
    return v * SBXNum(@"cardScale", 1.0, 0.1, 2.0);
}
static double (*orig_gridHSpacing)(id, SEL);
static double hook_gridHSpacing(id self, SEL _cmd) {
    double v = orig_gridHSpacing ? orig_gridHSpacing(self, _cmd) : 1.0;
    if (!SBXBool(@"cardSwitcher", NO)) return v;
    return v * SBXNum(@"cardHSpacing", 1.0, 0.1, 2.0);
}
static double (*orig_gridVSpacing)(id, SEL);
static double hook_gridVSpacing(id self, SEL _cmd) {
    double v = orig_gridVSpacing ? orig_gridVSpacing(self, _cmd) : 1.0;
    if (!SBXBool(@"cardSwitcher", NO)) return v;
    return v * SBXNum(@"cardVSpacing", 1.0, 0.1, 2.0);
}

#pragma mark - ============ 3) iPad 悬浮 Dock ============

static BOOL (*orig_isFloatingDockSupported)(void);
static BOOL hook_isFloatingDockSupported(void) {
    if (SBXBool(@"floatingDock", NO)) return YES;
    return orig_isFloatingDockSupported ? orig_isFloatingDockSupported() : NO;
}
static void (*orig_updateDivider)(id, SEL);
static void hook_updateDivider(id self, SEL _cmd) {
    if (SBXBool(@"floatingDock", NO) && SBXBool(@"hideSeparator", NO)) return;
    if (orig_updateDivider) orig_updateDivider(self, _cmd);
}
static BOOL (*orig_recentsEnabled)(id, SEL);
static BOOL hook_recentsEnabled(id self, SEL _cmd) {
    if (!SBXBool(@"floatingDock", NO)) return orig_recentsEnabled ? orig_recentsEnabled(self, _cmd) : NO;
    NSInteger c = (NSInteger)SBXNum(@"dockContent", 0, 0, 3);
    return (c == 0 || c == 2);
}
static BOOL (*orig_appLibraryEnabled)(id, SEL);
static BOOL hook_appLibraryEnabled(id self, SEL _cmd) {
    if (!SBXBool(@"floatingDock", NO)) return orig_appLibraryEnabled ? orig_appLibraryEnabled(self, _cmd) : NO;
    NSInteger c = (NSInteger)SBXNum(@"dockContent", 0, 0, 3);
    return (c == 1 || c == 2);
}
static id (*orig_initSuggestions)(id, SEL, NSUInteger, id, id, id, id, id, id, id, id);
static id hook_initSuggestions(id self, SEL _cmd, NSUInteger n, id a1, id a2, id a3, id a4, id a5, id a6, id a7, id a8) {
    NSUInteger nn = n;
    if (SBXBool(@"floatingDock", NO) && n > 0) {
        nn = (NSUInteger)SBXNum(@"dockIconCount", 4, 1, 10);
        SBXLog(@"Dock 建议数量 %lu -> %lu", (unsigned long)n, (unsigned long)nn);
    }
    return orig_initSuggestions ? orig_initSuggestions(self, _cmd, nn, a1, a2, a3, a4, a5, a6, a7, a8) : nil;
}
static BOOL (*orig_shouldHideInAppDock)(id, SEL);
static BOOL hook_shouldHideInAppDock(id self, SEL _cmd) {
    if (SBXBool(@"floatingDock", NO) && SBXBool(@"showInApps", NO)) return NO;
    return orig_shouldHideInAppDock ? orig_shouldHideInAppDock(self, _cmd) : YES;
}

#pragma mark - 安装

static void HookMsg(const char *cls, const char *sel, IMP imp, IMP *orig) {
    Class c = objc_getClass(cls);
    if (!c) { SBXLog(@"类不存在: %s", cls); return; }
    SEL s = NSSelectorFromString([NSString stringWithUTF8String:sel]);
    if (!class_getInstanceMethod(c, s) && !class_getClassMethod(c, s)) {
        SBXLog(@"方法不存在: %s %s", cls, sel); return;
    }
    SBXLoadSubstrate();
    if (!gHookMsgEx) { SBXLog(@"substrate 不可用，无法挂 %s", sel); return; }
    gHookMsgEx(c, s, imp, orig);
    SBXLog(@"已挂: %s %s", cls, sel);
}

// 切换器布局时补按钮
static void (*orig_vcLayout)(id, SEL);
static void hook_vcLayout(id self, SEL _cmd) {
    if (orig_vcLayout) orig_vcLayout(self, _cmd);
    if ([self isKindOfClass:UIViewController.class]) SBXLayoutClearButton((UIViewController *)self);
}

__attribute__((constructor)) static void SBXInit(void) {
    @autoreleasepool {
        SBXLog(@"==== SBXDesktop 装载 ====");
        // 1) 清除按钮
        HookMsg("SBFluidSwitcherViewController", "viewDidLayoutSubviews", (IMP)hook_vcLayout, (IMP *)&orig_vcLayout);
        // 2) iPad 卡片后台
        HookMsg("SBFluidSwitcherViewController", "isDevicePad", (IMP)hook_isDevicePad, (IMP *)&orig_isDevicePad);
        HookMsg("SBAppSwitcherSettings", "gridSwitcherPageScale", (IMP)hook_gridPageScale, (IMP *)&orig_gridPageScale);
        HookMsg("SBAppSwitcherSettings", "gridSwitcherHorizontalInterpageSpacingPortrait", (IMP)hook_gridHSpacing, (IMP *)&orig_gridHSpacing);
        HookMsg("SBAppSwitcherSettings", "gridSwitcherVerticalNaturalSpacingPortrait", (IMP)hook_gridVSpacing, (IMP *)&orig_gridVSpacing);
        // 3) iPad 悬浮 Dock
        void *sym = dlsym(RTLD_DEFAULT, "isFloatingDockSupported");
        SBXLoadSubstrate();
        if (sym && gHookFunction) { gHookFunction(sym, (void *)hook_isFloatingDockSupported, (void **)&orig_isFloatingDockSupported); SBXLog(@"已挂 isFloatingDockSupported"); }
        HookMsg("SBFloatingDockView", "updateDividerVisualStyling", (IMP)hook_updateDivider, (IMP *)&orig_updateDivider);
        HookMsg("SBFloatingDockDefaults", "recentsEnabled", (IMP)hook_recentsEnabled, (IMP *)&orig_recentsEnabled);
        HookMsg("SBFloatingDockDefaults", "appLibraryEnabled", (IMP)hook_appLibraryEnabled, (IMP *)&orig_appLibraryEnabled);
        HookMsg("SBFloatingDockSuggestionsModel", "initWithMaximumNumberOfSuggestions:iconController:recentsController:recentsDataStore:recentsDefaults:floatingDockDefaults:appSuggestionManager:analyticsClient:applicationController:", (IMP)hook_initSuggestions, (IMP *)&orig_initSuggestions);
        HookMsg("SBDeckSwitcherModifier", "shouldConfigureInAppDockHiddenAssertion", (IMP)hook_shouldHideInAppDock, (IMP *)&orig_shouldHideInAppDock);
    }
}
