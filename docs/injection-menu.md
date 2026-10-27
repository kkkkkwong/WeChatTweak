# Runtime injection menu marker

Once the updated runtime is loaded in the main WeChat process, it adds a
`WeChatTweak ✓` menu before Help (or at the end if no Help menu is registered).
Its first item, `✓ 运行时已加载`, opens an information dialog. Disabled rows show
the current WeChat version/build and the revoke-hook installation status.

The marker describes the current process. It does not store a historical
"injected" flag in preferences and does not infer success from a file being
present. Hook status is published after the production hook installer returns:

- Waiting: the target image has not been inspected yet.
- Installed: both the active revoke configuration and original-function pointer
  are set after installation. The menu still says behavior needs testing.
- Unsupported: no runtime configuration matches the build, or the CPU is not
  arm64.
- Failed: the build is recognized, but installation did not establish the hook
  (for example, the required static entry patch is absent).
- Static patch: verified guard/store instructions match a supported silent or
  native-notice profile; no runtime hook is needed for that mode. Behavior still
  requires a real-chat test.

`InjectionMenu.mm` defers all UI work from the library constructor to the main
queue. It requires the main executable to be `WeChat` and the bundle identifier
to be `com.tencent.xinWeChat` or a supported anti-recall clone identifier. It
creates neither `NSApplication` nor a replacement main menu. Launch/activation
notifications and an idempotent one-second timer attach the marker when the host
menu becomes available and restore it after full menu replacement or removal.
The timer runs in common modes and updates status text only when it changes.

The runtime explicitly enables Objective-C ARC and links AppKit in `Package.swift`.
Hook callbacks publish only an atomic enum; they do not manipulate AppKit under
the dyld loader lock.

## Validation

`swift build` succeeds, and all 21 Swift Testing tests pass, including runtime
injection dry runs, repeat injection, instruction preservation, missing-input
preflight, app identity checks, symlink containment, and repairing signatures on
unentitled libraries and generic signed resources. Isolated AppKit fixtures dynamically loaded the actual
built runtime and exercised:

- Constructor execution before `NSApplication` and before the host main menu.
- Exactly one visible marker, before Help.
- A real dyld callback for a synthetic resource `wechat.dylib`: unsupported
  builds report unsupported, and recognized builds lacking a static patch report
  failure. The separate 270115 adaptation now supplies that build's hook config.
- Repeated initialization, an empty replacement menu, complete menu replacement,
  and explicit removal of the marker.
- Status publication from a background thread.
- A helper executable/bundle receiving no marker.

The fixture's installed-status presentation was checked with the status
publisher; this does not establish real-chat anti-recall behavior. No installed
WeChat app was patched or relaunched for these checks.

On 2026-10-28, after installing the 270115 adaptation, the user separately
confirmed that anti-recall worked and the marker was present in their actual
WeChat app. See [the build-specific record](wechat-270115.md) for scope.

## Independent runtime injection

`wechattweak inject-runtime --app <path>` copies the runtime and adds its arm64
`LC_LOAD_DYLIB` command to `Contents/Resources/wechat.dylib`, then uses the existing
signing flow. `--dry-run` performs preflight without copying, modifying or signing.
The source runtime defaults to the CLI's directory; `--runtime-dylib` overrides it.
The command verifies the WeChat bundle identity and target containment, replaces
the runtime atomically, and shares its installation helper with
`patch --custom-recall-label`. It can update an already installed runtime without
adding duplicate load commands.

This command does not select a build-specific patch profile. For build 270115,
`patch --custom-recall-label --config ./config.json` additionally installs the
required entry stubs and recall-ID patch; runtime-only injection alone does not.
Existing supported installations can also receive the rebuilt runtime through
`patch --custom-recall-label`. Fully quit WeChat before installation and restart
afterward. Unlock a protected bundle first, and use a terminal granted macOS App
Management access if required.

Only disposable apps were modified by development checks. The installed app's
injection state may change independently and must be inspected separately.

A disposable copy of the actual 270115 universal app completed runtime injection,
re-signing, and `codesign --verify --deep --strict`. Both arm64 and x86_64 `__text`
SHA-256 hashes remained identical to the original. The arm64 slice contains
exactly one runtime load command; the x86_64 slice contains none. Post-signing
preflight also succeeds. The actual app copy was not launched, so this establishes
static injection/signing integrity; the AppKit fixtures cover the menu behavior.

The original certificate on some nested files was no longer trusted in this
environment. `Signing.swift` now includes unentitled Mach-O files and all other
recognized signed files before signing their containing bundles. This includes
270115's `vk_swiftshader_icd.json`, whose generic signature lives in xattrs. The
regression test invalidates both an unentitled dylib and a generic signed JSON
resource, then verifies that re-signing repairs both and passes deep validation.

References:

- [NSApplication.mainMenu](https://developer.apple.com/documentation/appkit/nsapplication/mainmenu)
- [NSApplication.didFinishLaunchingNotification](https://developer.apple.com/documentation/appkit/nsapplication/didfinishlaunchingnotification)
