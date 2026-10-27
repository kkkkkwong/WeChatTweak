#import <AppKit/AppKit.h>
#include <atomic>

#include "InjectionMenu.h"

namespace {

std::atomic<WeChatTweakRevokeHookStatus> revokeHookStatus{WeChatTweakRevokeHookWaiting};
NSString *const injectionMenuIdentifier = @"org.wechattweak.injection-marker";

bool isMainWeChatProcess() {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *identifier = [bundle bundleIdentifier];
    return ([[bundle executablePath].lastPathComponent isEqualToString:@"WeChat"] &&
            ([identifier isEqualToString:@"com.tencent.xinWeChat"] ||
             [identifier hasPrefix:@"com.tencent.xinWeChat.antirecall.clone"]));
}

NSString *wechatVersionLabel() {
    NSBundle *bundle = [NSBundle mainBundle];
    id version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    id build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    return [NSString stringWithFormat:@"%@（%@）",
            [version isKindOfClass:[NSString class]] ? version : @"未知版本",
            [build isKindOfClass:[NSString class]] ? build : @"未知构建"];
}

NSString *revokeHookStatusLabel() {
    switch (revokeHookStatus.load(std::memory_order_relaxed)) {
        case WeChatTweakRevokeHookWaiting:
            return @"防撤回：等待初始化";
        case WeChatTweakRevokeHookInstalled:
            return @"防撤回：钩子已安装，效果待实测";
        case WeChatTweakRevokeHookUnsupported:
            return @"防撤回：当前版本或架构未适配";
        case WeChatTweakRevokeHookFailed:
            return @"防撤回：钩子未安装";
        case WeChatTweakRevokeHookStaticPatch:
            return @"防撤回：静态补丁已识别，效果待实测";
    }
    return @"防撤回：状态未知";
}

} // namespace

@interface WCTweakInjectionMenuController : NSObject {
    NSMenuItem *_markerItem;
    NSMenuItem *_hookStatusItem;
    NSTimer *_refreshTimer;
}
- (void)start;
- (void)createMenu;
- (void)refreshMenu:(id)sender;
- (void)showInjectionInfo:(id)sender;
@end

@implementation WCTweakInjectionMenuController

- (void)start {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(refreshMenu:) name:NSApplicationDidFinishLaunchingNotification object:nil];
    [center addObserver:self selector:@selector(refreshMenu:) name:NSApplicationDidBecomeActiveNotification object:nil];
    // Qt can replace the complete menu after launch without an application
    // notification. A cheap, idempotent refresh also handles that case.
    _refreshTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(refreshMenu:) userInfo:nil repeats:YES];
    _refreshTimer.tolerance = 0.25;
    [[NSRunLoop mainRunLoop] addTimer:_refreshTimer forMode:NSRunLoopCommonModes];
    [self refreshMenu:nil];
}

- (void)createMenu {
    // Keep the menu alive even when the host temporarily removes it or replaces
    // its entire main menu.
    _markerItem = [[NSMenuItem alloc] initWithTitle:@"WeChatTweak ✓" action:nil keyEquivalent:@""];
    _markerItem.identifier = injectionMenuIdentifier;
    _markerItem.toolTip = @"当前微信进程已加载 WeChatTweak 运行时";
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"WeChatTweak"];
    submenu.autoenablesItems = NO;
    _markerItem.submenu = submenu;

    NSMenuItem *loadedItem = [[NSMenuItem alloc] initWithTitle:@"✓ 运行时已加载" action:@selector(showInjectionInfo:) keyEquivalent:@""];
    loadedItem.target = self;
    [submenu addItem:loadedItem];

    NSMenuItem *versionItem = [[NSMenuItem alloc] initWithTitle:[@"微信版本：" stringByAppendingString:wechatVersionLabel()] action:nil keyEquivalent:@""];
    versionItem.enabled = NO;
    [submenu addItem:versionItem];

    _hookStatusItem = [[NSMenuItem alloc] initWithTitle:revokeHookStatusLabel() action:nil keyEquivalent:@""];
    _hookStatusItem.enabled = NO;
    [submenu addItem:_hookStatusItem];
}

- (void)refreshMenu:(id)sender {
    if (![NSThread isMainThread]) {
        return;
    }
    // Do not create NSApplication or a menu before WeChat creates its own UI.
    NSMenu *mainMenu = [NSApp mainMenu];
    if (mainMenu == nil || mainMenu.numberOfItems == 0) {
        return;
    }
    if (_markerItem == nil) {
        [self createMenu];
    }
    NSString *status = revokeHookStatusLabel();
    if (![_hookStatusItem.title isEqualToString:status]) {
        _hookStatusItem.title = status;
    }
    for (NSMenuItem *item in mainMenu.itemArray) {
        if ([item.identifier isEqualToString:injectionMenuIdentifier]) {
            return;
        }
    }
    if (_markerItem.menu != nil) {
        [_markerItem.menu removeItem:_markerItem];
    }
    NSInteger index = mainMenu.numberOfItems;
    NSMenu *helpMenu = [NSApp helpMenu];
    if (helpMenu != nil) {
        for (NSMenuItem *item in mainMenu.itemArray) {
            if (item.submenu == helpMenu) {
                index = [mainMenu indexOfItem:item];
                break;
            }
        }
    }
    [mainMenu insertItem:_markerItem atIndex:index];
}

- (void)showInjectionInfo:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"WeChatTweak 已注入";
    alert.informativeText = [NSString stringWithFormat:@"运行时已在当前微信进程中加载。\n微信版本：%@\n%@\n\n此标记表示本次启动已加载插件。", wechatVersionLabel(), revokeHookStatusLabel()];
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_refreshTimer invalidate];
}

@end

void wechat_tweak_schedule_injection_menu(void) {
    // The library constructor and dyld callbacks may run under the loader lock.
    // Defer all AppKit work to the host's main run loop, including bundle checks.
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (!isMainWeChatProcess()) {
                return;
            }
            static dispatch_once_t once;
            static WCTweakInjectionMenuController *controller;
            dispatch_once(&once, ^{
                // The runtime is a process-lifetime LC_LOAD_DYLIB dependency.
                controller = [[WCTweakInjectionMenuController alloc] init];
                [controller start];
            });
        }
    });
}

void wechat_tweak_set_revoke_hook_status(WeChatTweakRevokeHookStatus status) {
    // No AppKit calls or dispatch from a hook-install callback. The menu picks
    // up this status on the main thread during its next refresh.
    revokeHookStatus.store(status, std::memory_order_relaxed);
}
