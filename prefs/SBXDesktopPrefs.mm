// SBXDesktopPrefs —— 设置页控制器（主页 + 白名单子页）
// 关键：specifiers 的 getter 里必须用 ivar _specifiers；
// 之前写成 self.specifiers 会调回自己 → 无限递归 → 爆栈闪退。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface SBXDesktopListController : PSListController
{
    NSArray *_sbxSpecs;
}
@end

@implementation SBXDesktopListController
- (NSArray *)specifiers {
    if (!_sbxSpecs) {
        _sbxSpecs = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _sbxSpecs;
}
@end

@interface SBXWhitelistController : PSListController
{
    NSArray *_sbxSpecs;
}
@end

@implementation SBXWhitelistController
- (NSArray *)specifiers {
    if (!_sbxSpecs) {
        _sbxSpecs = [self loadSpecifiersFromPlistName:@"Whitelist" target:self];
    }
    return _sbxSpecs;
}
@end