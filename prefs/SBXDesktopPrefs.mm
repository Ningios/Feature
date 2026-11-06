// SBXDesktopPrefs —— 设置页控制器（主页 + 白名单子页）
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@property (nonatomic, retain) NSArray *specifiers;
@end

@interface SBXDesktopListController : PSListController
@end

@implementation SBXDesktopListController
- (NSArray *)specifiers {
    if (!self.specifiers) self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return self.specifiers;
}
@end

@interface SBXWhitelistController : PSListController
@end

@implementation SBXWhitelistController
- (NSArray *)specifiers {
    if (!self.specifiers) self.specifiers = [self loadSpecifiersFromPlistName:@"Whitelist" target:self];
    return self.specifiers;
}
@end
