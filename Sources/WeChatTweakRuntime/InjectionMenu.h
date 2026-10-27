#pragma once

typedef enum {
    WeChatTweakRevokeHookWaiting,
    WeChatTweakRevokeHookInstalled,
    WeChatTweakRevokeHookUnsupported,
    WeChatTweakRevokeHookFailed,
    WeChatTweakRevokeHookStaticPatch,
} WeChatTweakRevokeHookStatus;

#ifdef __cplusplus
extern "C" {
#endif

void wechat_tweak_schedule_injection_menu(void);
void wechat_tweak_set_revoke_hook_status(WeChatTweakRevokeHookStatus status);

#ifdef __cplusplus
}
#endif
