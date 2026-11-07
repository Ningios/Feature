// SBXDesktopPrefs —— 设置页控制器
// 写法对照 SystemX 原版（能正常工作的实现）：
//   - 用 PSListController 的**真 ivar** `_specifiers`（不是自建 ivar）
//   - plist 名字由一个方法提供，再调 loadSpecifiersFromPlistName:target:
//   - 加日志，便于定位"列表为空"的原因
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <signal.h>

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

- (void)sbxDoRespring {
    SBXPLog(@"[注销] 开始重启桌面");
    // 1) 优先用 killall（rootless 在 /var/jb/usr/bin）
    NSArray *cands = @[@"/var/jb/usr/bin/killall", @"/usr/bin/killall", @"/bin/killall"];
    for (NSString *path in cands) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        const char *p = path.fileSystemRepresentation;
        char a0[] = "-9", a1[] = "SpringBoard";
        char *argv[] = {(char *)p, a0, a1, NULL};
        pid_t pid = 0;
        int r = posix_spawn(&pid, p, NULL, NULL, argv, environ);
        SBXPLog(@"[注销] %@ → %d", path, r);
        if (r == 0) return;
    }
    SBXPLog(@"[注销] 未找到可用的 killall，放弃");
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
