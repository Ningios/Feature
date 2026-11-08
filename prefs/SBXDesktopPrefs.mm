// SBXDesktopPrefs —— 设置页控制器
// 写法对照 SystemX 原版（能正常工作的实现）：
//   - 用 PSListController 的**真 ivar** `_specifiers`（不是自建 ivar）
//   - plist 名字由一个方法提供，再调 loadSpecifiersFromPlistName:target:
//   - 加日志，便于定位"列表为空"的原因
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <string.h>

extern char **environ;

static void SBXPLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [msg stringByAppendingString:@"\n"];
    FILE *f = fopen("/var/mobile/Library/Accessibility/feature-prefs.log", "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

@interface PSListController : UIViewController
{
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface SBXDesktopListController : PSListController
- (NSString *)sbxSpecifierPlistName;
- (void)sbxRespring:(id)spec;
@end

@implementation SBXDesktopListController
- (NSString *)sbxSpecifierPlistName { return @"Root"; }

// 注销按钮：先弹确认，确认后重启 SpringBoard
- (void)sbxRespring:(id)spec {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"注销？"
                                                               message:@"将重启桌面，正在进行的操作会被中断。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) { [weakSelf sbxDoRespring]; }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// ---- 注销：多路兜底 ----
// roothide 的 jbroot 是随机路径，/var/jb 通常不存在；iOS 也没有 /usr/bin/killall。
// 所以先问 libjbroot 要真实路径，最后直接 sysctl 找 SpringBoard 的 pid 发 SIGKILL。
static NSString *SBXJBPath(const char *rel) {
    void *h = dlopen("/usr/lib/libjbroot.dylib", RTLD_LAZY);
    if (!h) h = dlopen("libjbroot.dylib", RTLD_LAZY);
    if (h) {
        const char *(*jbroot)(const char *) = (const char *(*)(const char *))dlsym(h, "jbroot");
        if (jbroot) {
            const char *p = jbroot(rel);
            if (p && *p) return [NSString stringWithUTF8String:p];
        }
    }
    return nil;
}
static pid_t SBXPIDNamed(const char *want) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return 0;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return 0;
    pid_t found = 0;
    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        int n = (int)(size / sizeof(struct kinfo_proc));
        for (int i = 0; i < n; i++) {
            if (!strcmp(procs[i].kp_proc.p_comm, want)) { found = procs[i].kp_proc.p_pid; break; }
        }
    }
    free(procs);
    return found;
}

- (void)sbxDoRespring {
    SBXPLog(@"[注销] 开始重启桌面");
    NSMutableArray *cands = [NSMutableArray array];
    NSString *jb = SBXJBPath("/usr/bin/killall");
    if (jb) { SBXPLog(@"[注销] jbroot killall = %@", jb); [cands addObject:jb]; }
    [cands addObjectsFromArray:@[@"/var/jb/usr/bin/killall", @"/usr/bin/killall", @"/bin/killall"]];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in cands) {
        if (![fm fileExistsAtPath:path]) { SBXPLog(@"[注销] 不存在：%@", path); continue; }
        const char *p = path.fileSystemRepresentation;
        char a0[] = "-9", a1[] = "SpringBoard";
        char *argv[] = {(char *)p, a0, a1, NULL};
        pid_t pid = 0;
        int r = posix_spawn(&pid, p, NULL, NULL, argv, environ);
        SBXPLog(@"[注销] spawn %@ → %d (pid=%d)", path, r, (int)pid);
        if (r == 0) break;
    }
    // 兜底：不靠外部工具，直接杀 SpringBoard
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        pid_t sb = SBXPIDNamed("SpringBoard");
        SBXPLog(@"[注销] 兜底：SpringBoard pid=%d", (int)sb);
        if (sb > 0) {
            int k = kill(sb, SIGKILL);
            SBXPLog(@"[注销] kill(%d, SIGKILL) → %d", (int)sb, k);
        } else {
            SBXPLog(@"[注销] 找不到 SpringBoard 进程");
        }
    });
}

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        NSString *name = [self sbxSpecifierPlistName];
        _specifiers = [self loadSpecifiersFromPlistName:name target:self];
        NSBundle *b = [NSBundle bundleForClass:[self class]];
        NSString *path = [[b bundlePath] stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]];
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
        SBXPLog(@"[主页] plist=%@ count=%lu bundle=%@ 文件存在=%@",
                name, (unsigned long)[_specifiers count], [b bundlePath], exists ? @"YES" : @"NO");
    }
    return _specifiers;
}
@end

@interface SBXWhitelistController : PSListController
- (NSString *)sbxSpecifierPlistName;
@end

@implementation SBXWhitelistController
- (NSString *)sbxSpecifierPlistName { return @"Whitelist"; }

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:[self sbxSpecifierPlistName] target:self];
        SBXPLog(@"[白名单] count=%lu", (unsigned long)[_specifiers count]);
    }
    return _specifiers;
}
@end
