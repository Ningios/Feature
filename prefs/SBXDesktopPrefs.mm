// SBXDesktopPrefs —— 设置页控制器（主页 + 白名单子页）
// 关键：specifiers 的 getter 里必须用 ivar _specifiers；
// 之前写成 self.specifiers 会调回自己 → 无限递归 → 爆栈闪退。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface PSListController : UIViewController
{
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface SBXDesktopListController : PSListController
@end

@implementation SBXDesktopListController
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}
@end

@interface SBXWhitelistController : PSListController
@end

@implementation SBXWhitelistController
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Whitelist" target:self];
    }
    return _specifiers;
}
@end