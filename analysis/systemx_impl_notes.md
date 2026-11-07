# SystemBox.dylib — hook 实现「真实行为说明」(A/B/C 三组)

> 目标：`/tmp/rb/v/orig/Library/MobileSubstrate/DynamicLibraries/SystemBox.dylib`
> 方法：llvm-lipo 抽片 + radare2/capstone 逐条核对 + Ghidra 侧反编译交叉验证。
> 面向「照搬复刻」，每条都给出：条件 / 返回值 / 副作用 / 复刻结论。

---

## 0. 先决结论：用哪个切片

```
fat:  slice#0  cpu=arm64  offset=0x4000   size=0x7b760
      slice#1  cpu=arm64e offset=0x80000  size=0x7f870
__TEXT.__text 两片都是 vmaddr=0x4000 起，vmaddr==fileoff。
```

* **地址表（hooks.tsv 的 imp）对应的是 arm64 切片**。逐条核对：47 个目标地址在 arm64 切片**全部**命中函数序言（`stp x20,x19,[sp,#-0x20]!` / `sub sp,sp,#N`），并且函数边界与 hooks.tsv 的 `orig` 槽位、`${imp}` 替换体一一吻合。
* 在 arm64e 切片里，同样的地址**不是**函数入口（落在函数体中段），因为 arm64e 每个函数多一条 `pacibsp`（共 801 处），整段代码相对 arm64 后移 **+0x239C ~ +0x2540**（实测：`0x1ece4→0x21080`、`0x1f118→0x21518`、`0x1fe30→0x22374`）。
* 按偏移对齐后**两切片逻辑完全等价**（指令逐字节级相同，只多 PAC 序言/`braaz` 代替 `br`）。已抽样验证 `0x1ece4 / 0x1f118 / 0x1f148 / 0x1fe30 / 0x1f4c0` 五个。

**因此下文所有地址 = arm64 切片 VM 地址（也是文件偏移），与 hooks.tsv 一致。**

### 0.1 全局开关位（都在 __bss，运行期由偏好重载函数写入）

偏好重载函数：`0x12b20`（`FUN_00012b20`）—— 每次调用重建整张字典并逐项 `boolValue` 写全局；`0x201a0`(viewWillAppear:) 里会调它，所以**打开一次后台就重载一次偏好**（改设置不必注销/重启）。

| 全局地址 | 读法 | 偏好键（来自 __cstring 的 CFString 字面量） | 取值 |
|---|---|---|---|
| 0x70f30 | ldrb | `openAppsAsPad` | bool |
| 0x70f40 | ldrb | `forceZoomToSystemAperture` | bool |
| 0x70f50 | ldrb | `magicInteractionAnimation` | bool |
| 0x70fa0 | ldrb | `iPadFloatingDockEnabled` | bool |
| 0x717d5 | ldrb | `disableBottomHomeBarSwipe` | bool |
| 0x717d7 | ldrb | `iPadFloatingDockShowInSwitcher` | bool |
| 0x717d8 | ldrb | `iPadFloatingDockShowInApps` | bool |
| 0x717d9 | ldrb | `iPadFloatingDockHideSeparator` | bool |
| 0x717e0 | ldr  | `iPadFloatingDockContent` | int，clamp 0..3，默认 0（0=最近使用 1=App资源库 2=两者 3=都不要） |
| 0x70230 | ldr  | `iPadFloatingDockIconCount` | int，clamp 1..10，默认 4 |
| 0x70238 | ldr  | `iPadFloatingDockRecentCount` | int，clamp 1..10，默认 3 |
| 0x70768 | ldrb | `disableAppLibrary` | bool |
| 0x71108 | ldrb | `iPadCardSwitcherEnabled` | bool |
| 0x702c0 | ldr  | `iPadCardSwitcherSize` | double，clamp 0.5..1.5，默认 1.0 |
| 0x702c8 | ldr  | `iPadCardSwitcherHorizontalSpacing` | double，clamp 0.1..2.0，默认 1.0 |
| 0x702d0 | ldr  | `iPadCardSwitcherVerticalSpacing` | double，clamp 0.1..2.0，默认 1.0 |
| 0x7187c | ldrb | `switcherClearButtonEnabled` | bool |
| 0x7187d | ldrb | `switcherClearButtonPreserveNowPlaying` | bool |
| 0x70e30 | ldrb | `transparentDock` | bool |
| 0x702b0 | ldr  | `switcherClearButtonFontSize` | clamp：`max(8, v)` 再 `min(...,40)`，默认 16 |
| 0x702b8 | ldr  | `switcherClearButtonSize` | clamp：`max(50, v)` 再 `min(...,100)`，默认 80 |

运行期状态位（非偏好）：
* `0x71880` — 清除按钮「代次」计数器（隐藏时 +1，用来作废延迟 block）
* `0x71888` — 「按钮已显示过」标志（=1 表示本轮已弹过按钮）
* `0x71889` — 计算出的「应当显示」结果
* `0x70500` — `NSHashTable weakObjects`，保存所有已创建的清除按钮
* `0x704f8` — 缓存 `SBFloatingDockController` 实例

常量池（__const）：`0x53690=0.1`、`0x536a8=0.8`、`0x536b0=0.08`、`0x536b8=0.18`、`0x536c0=0.03`、`0x53650=0.01`

### 0.2 用到的内部辅助函数（读懂副作用的钥匙）

| 地址 | 语义 |
|---|---|
| 0x3f3c4 | `安装清除按钮(owner, view, self)`：若 `switcherClearButtonEnabled` 且 view 非空，`UIButton buttonWithType:1`，tint=白，背景=clear，`layer.masksToBounds=YES`，插入 `UIVisualEffectView(UIBlurEffect style 2)` 到 index 0，4 条约束，`addTarget:self action:@selector(sb_switcherClearButtonTapped:) forControlEvents:0x40(TouchUpInside)`，加入弱表 `0x70500`，`setHidden:YES`/`setAlpha:0`，`addSubview:`，最后 `setAssociatedObject(self, key, button, 1)` 并调 0x30e54 做样式（圆角=size/2、`setImage:forState:0`=nil、`setTitle:@"✕"`、semibold 字号）。 |
| 0x30e54 | `按钮样式`：宽=size、高=size*0.44、cornerRadius=size/2、title 用符号，字体 semibold。 |
| 0x31044(show) | `刷新清除按钮可见性`：`show=1` 时 `0x71889 = switcherClearButtonEnabled ? !0x71888 : 0`；`show=0` 时 `0x71889=0` 且 `0x71880++`（作废挂起的延时隐藏）。然后遍历弱表：对每个按钮 `layer.removeAllAnimations`、`setTransform:identity`、`setAlpha:(show?1:0)`、`setHidden:(!show)`。 |
| 0x3f184 | `拆除清除按钮`：取关联按钮 → `removeAllAnimations`、`removeFromSuperview`、从 0x70500 移除、清关联对象。 |
| 0x3f258(秒, view) | `延时隐藏`：若 view.window 非空且 `switcherClearButtonEnabled`，抓当前代次 `0x71880`，`dispatch_after(秒*1e9, main_q)` 执行隐藏 block（代次变了就丢弃）。 |
| 0x3f118(obj) | `isPresentingFolder`：respondsToSelector 检查后 `[obj isPresentingFolder]`，否则 0。 |
| 0x3efbc(0/1) | `悬浮 Dock 展示/隐藏`：取 `SBIconController.sharedInstance.floatingDockController`（或缓存 0x704f8）→ `0`:`_dismissFloatingDockIfPresentedAnimated:completionHandler:`，`1`:`_presentFloatingDockIfDismissedAnimated:completionHandler:`（带下划线前缀优先，没有就用不带下划线的），参数 `(1, nil)`。 |
| 0x37e40(obj) | 返回 `iconContentScale`（respondsToSelector 检查，>0.01 才采用，否则 1.0）。 |
| 0x383f4(scale, iconView, 1) | 给单个 SBIconView 打「悬浮 Dock 内」关联标记 + 记录缩放 + 装/刷 shadowLayer。 |
| 0x38664(listView, scale) | 对 icon list view：`clipsToBounds=NO`、`layer.masksToBounds=NO`，再 `enumerateDisplayedIconViewsUsingBlock:` 对每个 iconView 应用缩放阴影。 |
| 0x374c0(view) | `彻底隐藏`：`setHidden:YES`、`setAlpha:0`、`setUserInteractionEnabled:NO`。 |
| 0x2fadc(dict,key) | bool 读取（`objectForKeyedSubscript:` + `boolValue`）。 |
| 0x2fe30(min,max,dict,key) | double 读取，默认 1.0，clamp 到 [min,max]。 |

---
## A. 后台「一键清除」按钮

### A.0 0x201a0 的选择器已解出 = `viewWillAppear:`
证据：构造器里替换体地址 `0x201a0`、orig 槽 `0x71168` 的那次 `MSHookMessageEx`（call_addr 0xfcec）在 `0xfcd4` 用 `ldr x1, [x26, 0x778]` 取选择器，而 `x26` 在本段开头 `0xf6f8` 处为 `adrp x26, 0x6f000` → 槽位 `0x6f778` → 指向 `0x58679` = 字符串 **`viewWillAppear:`**。

### A.1 表格

| 地址 | 类 方法 | 条件 | 返回值 | 副作用 | 复刻结论 |
|---|---|---|---|---|---|
| **0x2013c** | `SBFluidSwitcherViewController viewDidLoad` | 无（无条件执行）；内部 0x3f3c4 里才判 `switcherClearButtonEnabled` | void（不覆盖返回值） | 先 `%orig`；取 `self.view`；调 `0x3f3c4(self, view, self)`＝建按钮并 `addSubview` 到 view、注册 `sb_switcherClearButtonTapped:`(TouchUpInside)、初值 hidden/alpha0、加入弱表 | `- (void)viewDidLoad { %orig; [self sbx_installClearButton:self.view]; }`，按钮真身建在 `self.view` 上 |
| **0x201a0** | `SBFluidSwitcherViewController viewWillAppear:`（hooks.tsv 中该选择器为空，本次已解出） | 无外层条件；内部按钮创建/刷新各自判 `switcherClearButtonEnabled` | void | ① `%orig` ② `0x12b20()`＝**重载整套偏好** ③ `0x71888 = 0`（本轮的「已显示过」复位）④ `0x3f3c4` 确保按钮存在 ⑤ `0x31044(1)`＝刷新并**显示**按钮 | `%orig; reloadPrefs(); _shown=NO; ensureButton(); updateClearButtons(YES);` 注意：**这里会顺带重载偏好** |
| **0x17d30** | `SBHomeGestureFinalDestinationSwitcherModifier currentFinalDestination` | `disableBottomHomeBarSwipe(0x717d5) != 0` 且 `%orig ∈ {1,2}` | 条件成立 → **0**；否则 `%orig` | 无 | `NSInteger d=%orig; if((d==1||d==2)&&prefDisableBottomSwipe) return 0; return d;`（asm：`sub x9,x0,1; cmp x9,2; ccmp w8,0,4,lo; csel x0,xzr,x0,ne`） |
| **0x203c4** | `...layoutStateTransitionCoordinator:transitionDidBeginWithTransitionContext:` | 无 | void | **只有 `%orig(...)`（尾调用 `br x2`）** | 纯透传，可忽略（回调用它只是占位） |
| **0x203d0** | `...transitionWillEndWithTransitionContext:` | `switcherClearButtonEnabled && !(0x71888&1) && [self respondsToSelector:@selector(isAnySwitcherVisible)] && [self isAnySwitcherVisible]` | void | 先 `%orig(arg1,arg2,arg3,arg4)`；条件成立 → `0x31044(1)`（弹按钮） | `%orig; if(btnOn && !_shown && [self respondsToSelector:@selector(isAnySwitcherVisible)] && [self isAnySwitcherVisible]) showClearButtons(YES);` |
| **0x20498** | `...transitionDidEndWithTransitionContext:` | 同 0x203d0（两函数逐字节同构） | void | 同 0x203d0 | 同 0x203d0，复制粘贴即可 |
| **0x1fd80** | `SBMainSwitcherControllerCoordinator _loadContentViewControllerIfNecessaryForWindowScene:` | 无（总是执行） | 取 thread-local 计数器（`__tlv_bootstrap`，键 0x70380）**+1** → `%orig` → **-1**（必须成对，异常也要回滚） | `tls_depth++; %orig; tls_depth--;`。它的唯一用途是让 **0x1fd30 `UIDevice userInterfaceIdiom`** 钩子在「正在加载后台内容控制器」期间返回 **1(Pad)**（该钩子条件：`iPadCardSwitcherEnabled && tls_depth!=0`），从而在 iPhone 上按 iPad 方式搭后台界面 |
| **0x20560** | `SBMainSwitcherControllerCoordinator dismissMainSwitcherNoninteractivelyAnimated:` | 无（无条件） | void | 先 `0x31044(0)`（**立即**隐藏按钮、不做动画、代次+1）→ `%orig(...)` | `hideClearButtons(NO); %orig;` 顺序不能反（先隐藏再让系统收后台） |
| **0x205a8** | `SBMainSwitcherControllerCoordinator dismissAllSwitchersNoninteractivelyAnimated:` | 无（无条件） | void | 同 0x20560 | 同 0x20560 |

---

## B. iPad 卡片式后台（iPhone 上伪装 iPad 网格）

| 地址 | 类 方法 | 条件 | 返回值 | 副作用 | 复刻结论 |
|---|---|---|---|---|---|
| **0x1ece4** | `SBFluidSwitcherViewController isDevicePad` | `openAppsAsPad(0x70f30)` | **返回 1**（YES/Pad）；否则 `%orig` | 无 | `if(prefOpenAppsAsPad) return YES; return %orig;`（asm：`ldrb w8,[0x70f30]; cbz; mov w0,#1; ret`） |
| **0x1fe30** | `SBAppSwitcherSettings effectiveSwitcherStyle` | `iPadCardSwitcherEnabled(0x71108)` | **返回 2**；否则 `%orig` | 无 | `if(prefCard) return 2; return %orig;` —— 2 = 网格(grid)样式。（asm：`mov w0,#2; ret`，全库只有 2 处 `mov w0,#2`，这是其中一处） |
| **0x1fe50** | `SBAppSwitcherSettings gridSwitcherPageScale` | `iPadCardSwitcherEnabled` | `%orig * (pref ? iPadCardSwitcherSize(0x702c0) : 1.0)` | 无 | `double s=%orig; return s*(prefCard?prefSize:1.0);`（asm：`fmov d2,1.0; fcsel d1,d2,[0x702c0],eq; fmul d0,d0,d1`） |
| **0x1fe8c** | `... gridSwitcherHorizontalInterpageSpacingPortrait` | 同上 | `%orig * (pref ? HorizontalSpacing(0x702c8) : 1.0)` | 无 | 同上，系数换成 `iPadCardSwitcherHorizontalSpacing` |
| **0x1fec8** | `... gridSwitcherVerticalNaturalSpacingPortrait` | 同上 | `%orig * (pref ? VerticalSpacing(0x702d0) : 1.0)` | 无 | 同上，系数换成 `iPadCardSwitcherVerticalSpacing` |
| **0x1ff04** | `SBAppSwitcherSettings setDefaultValues` | `iPadCardSwitcherEnabled` | void | 先 `%orig`；然后 `NSSelectorFromString(@"setSpacingBetweenLeadingEdgeAndIcon:")` 与 `@"setSpacingBetweenTrailingEdgeAndLabels:"`，各自 `respondsToSelector` 通过后 **`[self sel: 0.0]`**（asm：`fmov d0,xzr` → 参数传 0.0） | `%orig; if(prefCard){ if([self respondsToSelector:sel1]) [self setSpacingBetweenLeadingEdgeAndIcon:0.0]; if(...sel2) [self setSpacingBetweenTrailingEdgeAndLabels:0.0]; }` —— 把网格卡片间距清零 |
| **0x1edac** | `SBFluidSwitcherAnimationSettings setHomeScreenScaleInApplication:` | `magicInteractionAnimation(0x70f50)` | void，但**改写入参**：`d0 = pref ? 0.1 : d0` | 尾调用 `%orig(d0)` | `%orig(prefMagic ? 0.1 : scale);`（asm：`fcsel d0,d0,d1,eq`，d1=常量 0x53690=0.1） |
| **0x1edd0** | `SBFluidSwitcherAnimationSettings setHomeScreenScaleInSwitcher:` | 同上 | 同上 | 同上 | 同上（同一份代码，只是 orig 槽不同） |
| **0x1f148** | `_SBGridFloorSwitcherModifier isSwitcherWindowVisible` | `iPadFloatingDockEnabled(0x70fa0) && !iPadFloatingDockShowInSwitcher(0x717d7) && %orig != 0` | **原样返回 `%orig`**（不改值） | 条件成立时调 `0x3efbc(0)`＝**把悬浮 Dock 收起来** | `BOOL v=%orig; if(dockOn && !showInSwitcher && v) dismissFloatingDock(); return v;` —— 后台窗口可见但 Dock 设置为「不在后台显示」→ 主动收 Dock |
| **0x1f19c** | `_SBGridFloorSwitcherModifier appLayoutToScrollToBeforeTransitioning` | `dockOn && !showInSwitcher && %orig == nil` | 原样返回 `%orig`（布局对象/ nil） | 条件成立时调 `0x3efbc(1)`＝**把悬浮 Dock 弹出来** | `id l=%orig; if(dockOn && !showInSwitcher && !l) presentFloatingDock(); return l;` |
| **0x1ffac** | `SBFluidSwitcherIconImageContainerView didMoveToWindow` | `iPadCardSwitcherEnabled` | void | 先 `%orig`；然后 `CGAffineTransformMakeScale(0.8,0.8)`（常量 0x536a8=0.8）→ `[self setTransform:&t]` | `%orig; if(prefCard) self.transform = CGAffineTransformMakeScale(0.8,0.8);` |
| **0x20018** | `SBAppSwitcherScrollView didMoveToWindow` | 三分支：`self.window == nil` / `switcherClearButtonEnabled` | void | ① `%orig` ② `window==nil` → `0x3f184(self)`（拆掉按钮：removeFromSuperview + 移出弱表）+ `0x31044(0)` ③ 否则若 `switcherClearButtonEnabled` → `0x3f258(0.08, self)` 与 `0x3f258(0.18, self)`（0.08s / 0.18s 后各安排一次「延时隐藏」） | `%orig; if(!self.window){ removeClearButton(self); hideClearButtons(NO);} else if(prefBtn){ scheduleHide(0.08,self); scheduleHide(0.18,self);} ` |
| **0x200a8** | `SBAppSwitcherScrollView setScrollEnabled:` | `self.window != nil && enabled != 0 && switcherClearButtonEnabled`；另一支 `enabled==0` | void | ① `%orig` ② 若 window 且 enabled 且 prefBtn → `0x3f258(0.03, self)`（0.03s 后延时隐藏）③ 否则若 `enabled==0` → `0x31044(0)` 立即隐藏 | `%orig; if(self.window && enabled){ if(prefBtn) scheduleHide(0.03,self);} else if(!enabled){ hideClearButtons(NO);} ` |
| **0x1ed04** | `SBSwitcherModifier shouldZoomToSystemApertureForEvent:activeLayout:` | `forceZoomToSystemAperture(0x70f40)` | 条件成立 → **返回 1**；否则 `%orig` | 无 | `if(prefForceZoomAperture) return YES; return %orig;`（4 参数都先 retain 再 release，复刻时不用管） |

补充：`0x1fd30`（不在本次清单，但与本组强相关）= `UIDevice userInterfaceIdiom`：`if(iPadCardSwitcherEnabled && tls_depth!=0) return 1(Pad); return %orig;` —— 与 `0x1fd80` 配对使用。

---
## C. iPad 悬浮 Dock

| 地址 | 类 方法 | 条件 | 返回值 | 副作用 | 复刻结论 |
|---|---|---|---|---|---|
| **0x1f0f8** | C 函数 `isFloatingDockSupported` | `iPadFloatingDockEnabled(0x70fa0)` | **返回 1**；否则 `%orig`（尾调用 `br x2`） | 无 | `if(prefDock) return 1; return orig();`（asm：`ldrb w8,[0x70fa0]; cbz; mov w0,#1; ret`） |
| **0x1f118** | `SBFloatingDockBehaviorAssertion gesturePossible` | `dockOn && !iPadFloatingDockShowInApps(0x717d8)` | 条件成立 → **返回 0（NO）**；否则 `%orig` | 无 | `if(prefDock && !prefShowInApps) return NO; return %orig;`（asm：`cmp w8,0; ccmp w9,0,0,ne; b.eq 返回0`）—— Dock 想常驻所有 App 时反而把「上滑手势可行」判为 NO |
| **0x1f1f8** | `SBDeckSwitcherModifier shouldConfigureInAppDockHiddenAssertion` | `dockOn` | 返回值**按位或**：`%orig | (prefDock && !ShowInSwitcher(0x717d7))` | 无 | `BOOL r=%orig; if(prefDock) r |= (prefShowInSwitcher==0); return r;`（asm：`tst w8,1; cset w8,eq; orr w0,w0,w8`） |
| **0x1f234** | `SBFloatingDockController initWithWindowScene:iconController:` | 无 | 返回 `%orig` 结果 | 若 `%orig != nil` → `0x704f8 = result`（**缓存 controller 单例指针**，供 0x3efbc 用） | `id c=%orig; if(c) g_dockController=c; return c;`（先 retain 参数、后 release 两个对象） |
| **0x1f2fc** | `SBFloatingDockController floatingDockWindow` | 无 | 返回 `%orig`（窗口） | `objc_storeStrong(&0x704f8, self)` —— 把这个 getter 当「缓存点」：任何一次调用都把 controller 存起来 | `id w=%orig; g_dockController=self; return w;` |
| **0x1f344** | `SBFloatingDockViewController translationFromFullyPresentedFrame` | `dockOn && isPresentingFolder(self)`（0x3f118） | 条件成立 → **返回 0.0**（`fmov d0,xzr`）；否则 `%orig` | 无 | `if(prefDock && [self isPresentingFolder]) return 0.0; return %orig;` — **返回的是单个 CGFloat（double）0.0，不是结构体** |
| **0x1f39c** | `SBFloatingDockController translationFromFullyPresentedFrame` | 与 0x1f344 完全一致（连常量/分支都一样） | 条件成立 → **返回 0.0**；否则 `%orig` | 无 | 同上，逐字节同构，直接抄 |
| **0x1f3f4** | `SBFloatingDockDefaults recentsEnabled` | `dockOn` | 条件成立 → `(iPadFloatingDockContent(0x717e0) & ~2) == 0`（即 content∈{0,2}）；否则 `%orig` | 无 | `if(prefDock) return ((NSInteger)prefContent & ~2) == 0; return %orig;`（asm：`tst x8,-3; cset w0,eq`） |
| **0x1f420** | `SBFloatingDockDefaults setRecentsEnabled:` | `dockOn` | void，**改写入参** `w2 = (content & ~2)==0`，否则原样 | 尾调用 `%orig(args)` | `if(prefDock) value = ((NSInteger)prefContent & ~2)==0; %orig(value);`（强制写入，实际存进去的是计算值） |
| **0x1f44c** | `SBFloatingDockDefaults appLibraryEnabled` | `dockOn` | 条件成立 → `(disableAppLibrary(0x70768)==0 && (content-1) < 2u)`（即 content∈{1,2} 且未禁用资源库）；否则 `%orig` | 无 | `if(prefDock) return (!prefDisableAppLibrary && (prefContent>=1 && prefContent<=2)); return %orig;`（asm：`sub x9,x9,1; cmp w8,0; ccmp x9,2,2,eq; cset w0,lo`） |
| **0x1f488** | `SBFloatingDockDefaults setAppLibraryEnabled:` | `dockOn` | void，**改写入参** `w2 = (!disableAppLibrary && content∈{1,2})` | 尾调用 `%orig(args)` | 同 0x1f420 的写法 |
| **0x1f4c0** | `SBFloatingDockView updateDividerVisualStyling` | `dockOn && iPadFloatingDockHideSeparator(0x717d9)` | void | 条件成立 → **直接 `ret`，完全不调原实现**（分隔线视觉样式不更新＝分隔线保持原样/不被重绘）；否则 `%orig` | `if(prefDock && prefHideSeparator) return; %orig;`（asm：`cmp w8,0; ccmp w9,0,4,ne; b.ne 到 ret`）——**这是「隐藏分隔线」的实现方式：把样式更新整段跳过** |
| **0x1f58c** | `SBFloatingDockSuggestionsModel maxSuggestions` | `dockOn` | 条件成立 → 读全局 `0x70238`＝`iPadFloatingDockRecentCount`（clamp 1..10，默认 3）；否则 `%orig` | 无 | `if(prefDock) return (NSUInteger)prefRecentCount; return %orig;`（asm：`ldr x0,[0x70238]; ret`） |
| **0x1f5b0** | `SBFloatingDockSuggestionsModel recentDisplayItemsController:shouldAddItem:` | `dockOn` 且 `[self.currentAppSuggestion isHandoff]` | 命中 handoff → 返回 **0/NO**（不加入）；否则 `%orig` | 先 retain 两个入参；`respondsToSelector:` 保护 `currentAppSuggestion`/`isHandoff` | `if(prefDock){ id s=[self currentAppSuggestion]; if([s respondsToSelector:@selector(isHandoff)] && [s isHandoff]) return NO; } return %orig;` |
| **0x1f6e4** | `SBFloatingDockSuggestionsViewController initWithNumberOfRecents:iconController:applicationController:layoutStateTransitionCoordinator:suggestionsModel:iconViewProvider:`（7 参 style） | `dockOn` | void；**把 `x2`(numberOfRecents) 换成 `0x70238`** | 尾调用 `%orig` | `if(prefDock) count = prefRecentCount; %orig(...);`（asm：`csel x2, x2, x10, eq`） |
| **0x1f72c** | `SBFloatingDockSuggestionsModel initWithMaximumNumberOfSuggestions:...`（8 参，含 analyticsClient） | `dockOn` | 同上：`x2` = `0x70238` | 尾调用 `%orig`（参数经栈中转） | 同上 |
| **0x1f760** | `SBFloatingDockSuggestionsModel initWithMaximumNumberOfSuggestions:...`（7 参） | `dockOn` | 同上：`x2` = `0x70238` | 尾调用 `%orig`（`ldp/str` 整理栈参数） | 同上 |
| **0x191d4** | `SBFloatingDockIconListView configureIconView:forIcon:` | 无（条件在 0x383f4 内部判） | void | 先 `%orig(self,sel,iconView,icon)`；`s = iconContentScale(self)`（0x37e40）；`0x383f4(s, iconView, 1)`＝给 iconView 打「悬浮 Dock 内」标记并按 s 装阴影层 | `%orig; CGFloat s=iconContentScale(self); sbx_applyFloatingDockIcon(iconView, s);` |
| **0x19270** | `SBFloatingDockIconListView layoutSubviews` | 无 | void | `%orig`；`s = iconContentScale(self)`；`0x38664(self, s)`＝`clipsToBounds/masksToBounds=NO` + 遍历所有已显示 iconView 应用缩放阴影 | `%orig; CGFloat s=iconContentScale(self); sbx_applyIconScaleToIconListView(self, s);` |
| **0x192a4** | `SBFloatingDockSuggestionsViewController configureIconView:forIcon:` | 无 | void | `%orig`；`0x383f4(1.0, iconView, 1)`（**比例固定 1.0**，不是 iconContentScale） | `%orig; sbx_applyFloatingDockIcon(iconView, 1.0);` |
| **0x1933c** | `SBFloatingDockSuggestionsViewController dockViewDidBecomeVisible`（hooks.tsv 名；实为该方法） | `[self respondsToSelector:@selector(listView)]` | void | `%orig`；`lv = self.listView`; `s = iconContentScale(lv)`; `0x38664(lv, s)` | `%orig; if([self respondsToSelector:@selector(listView)]){ id lv=[self listView]; sbx_applyIconScaleToIconListView(lv, iconContentScale(lv)); }` |
| **0x193cc** | `SBFloatingDockView layoutSubviews` | 无 | void | `%orig`；`s = iconContentScale(self)`；对 `self.userIconListView`、`self.recentIconListView` 各调 `0x38664(v, s)`；对 `self.accessoryIconView` 调 `0x383f4(s, v, 1)` | `%orig; CGFloat s=iconContentScale(self); sbx_applyIconScaleToIconListView(self.userIconListView,s); sbx_applyIconScaleToIconListView(self.recentIconListView,s); sbx_applyFloatingDockIcon(self.accessoryIconView, s);` |
| **0x1ded8** | `SBFloatingDockPlatterView layoutSubviews` | `transparentDock(0x70e30)` | void | `%orig`；条件成立 → 对 `self.backgroundView` 与 `self.shadowView` 各调 `0x374c0`（`setHidden:YES` + `setAlpha:0` + `setUserInteractionEnabled:NO`） | `%orig; if(prefTransparentDock){ hideFully(self.backgroundView); hideFully(self.shadowView); }` — 「透明 Dock」＝把 Platter 的底板和阴影藏掉 |
| **0x1df6c** | `SBFloatingDockPlatterView _dynamicUserInterfaceTraitDidChange` | `transparentDock(0x70e30)` | void | `%orig`；条件成立 → 同 0x1ded8 隐藏 backgroundView/shadowView，**再 `setNeedsLayout`** | 同上 + `[self setNeedsLayout];` |

---

## D. 解析情况说明（无「无法解析」项）

* 47 个目标地址**全部**在 arm64 切片命中真实函数（`r2` 反汇编 + `pd` 边界核对 + 与 hooks.tsv 的 `orig` 槽一致），**没有出现「不像函数」的地址**。
* 唯一一处 hooks.tsv 未给出选择器的条目 `0x201a0`，本次已解出为 **`SBFluidSwitcherViewController viewWillAppear:`**（证据见 A.0）。
* 两个切片的关系：arm64 切片地址与 hooks.tsv 完全对齐，arm64e 切片为同一份源码的 PAC 编译（函数整体后移 ≈ +0x239C…+0x2540），逻辑等价。**复刻时按 arm64 切片的地址取函数体即可；若要以 arm64e 为基准，请用「+0x239C…+0x2540 的偏移后地址」重新对表。**

## E. 复刻时的几个易错点

1. `0x203c4` 是**纯透传**，不要给它加逻辑。
2. `0x20498` 与 `0x203d0` **两份实现完全相同**（同一段代码被复制到两个选择器），别以为其中一个多了什么。
3. `0x1edac/0x1edd0/0x1f420/0x1f488/0x1f6e4/0x1f72c/0x1f760` 都是**改写入参后尾调用原实现**，不是"先调原实现再纠正"，顺序相反会失效。
4. `0x1f4c0` 是**条件成立就 `return`（跳过原实现）**，不是调用后修改。
5. `0x1f344/0x1f39c` 返回的是 **CGFloat 0.0**（`fmov d0, xzr`），别写成 `nil`/CGPoint。
6. `0x1f118` 的判空方向：**Dock 开启且「显示在 App 中」为真时返回 NO**；关掉「显示在 App 中」才走原实现。
7. `0x1fd80` 的 thread-local 计数必须用 **try/finally 语义**（+=1 / 原实现 / -=1），否则 `UIDevice.userInterfaceIdiom` 钩子会永久返回 Pad。
8. `0x17d30` 里 `1`、`2` 是枚举值判定（`sub x9,x0,1; cmp x9,2` 无符号比较），等价于 `d==1 || d==2`，不是 `1 <= d <= 2`。
9. `switcherClearButtonPreserveNowPlaying(0x7187d)` 在本次 47 个函数里**没有被读到**（只在偏好重载 `0x12b20` 里写全局）。它真正的消费者是按钮的 action **`0x2026c`（`sb_switcherClearButtonTapped:`，不是 MS hook，而是按钮自己 addTarget 的方法实现）**：`0x71888=1` → `0x31044(0)` 隐藏按钮 → 把按钮缩到 0.94（常量 `0x536c8`）→ 跑 block `0x3fc18`，其中调用 `FUN_00028ea4(DAT_0007187d, DAT_000703d0)`（保留正在播放 + 白名单 `switcherClearButtonWhitelist`）。复刻清除逻辑时这条要一并搬。
