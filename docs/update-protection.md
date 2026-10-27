# Per-app update protection

The inspected `/Applications/WeChat 2.app` is WeChat 4.1.15, build 270115
(`WeChatBundleVersion=4.1.15.35`). It includes `Contents/_MASReceipt` and its
arm64 library contains the App Store check implementation in `app_update_mac.m`.
Patching a check inside WeChat does not control an external App Store installer.

`wechattweak updates --app <path> --lock` sets the user immutable flag
(`UF_IMMUTABLE`, Finder's file lock) on the selected WeChat bundle and its regular
files and directories. Locking only the bundle directory would leave existing
files writable, so the operation covers its contents as well. Parent directory
locks also protect symlink entries; symlink targets are never followed. Regular
files with multiple hard links are rejected to avoid changing files shared with
another app. The bundle identifier must be `com.tencent.xinWeChat`.

The command does not load a patch configuration, edit executable bytes, re-sign
code, alter receipts, access chat data, or change system/App Store preferences.
It is independent of CPU architecture and build-specific patch addresses.

`--unlock` clears the user immutable bit throughout the selected bundle,
including any pre-existing Finder locks. Other file flags are retained. Quit
WeChat and unlock before updating, patching, moving, or deleting it. The owner or
an administrator can change this flag; root-owned installations require `sudo`.

Every item is inspected before any flags change. The implementation uses file
descriptors and checks device/inode identity and flags again before mutation;
a failed change attempts to restore the immutable bits it changed. A
rollback failure is explicitly reported. `--dry-run` performs inspection and
ownership checks without changing flags.

This is filesystem write protection, not an App Store per-app update preference.
It does not suppress update listings or downloads. A privileged installer that
explicitly clears the immutable flag can bypass it, and no live App Store upgrade
has been attempted. Do not describe it as a verified, absolute App Store update
block.

## Validation

Swift Testing exercises actual filesystem operations on disposable app fixtures:
in-place writes, atomic replacement, directory additions, and app renaming are
rejected while locked. Reading remains possible; unlock restores writing.
Repeated operations, dry runs, stale inspection, non-immutable flag preservation,
symlink isolation, hard-link rejection, and bundle identity are also checked.

All 15 tests passed on macOS 27.0.1 / Apple Silicon with:

```sh
swift test --disable-xctest \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

A disposable copy of the installed 270115 universal app was also exercised:
all 551 regular files/directories locked, in-place opening of `wechat.dylib` for
writing failed, adding a file failed, and renaming the app failed. Unlocking
cleared the locks. The SHA-256 hashes of regular files and all symlink targets
(388 entries total) were identical before, during, and after protection.

The original installed app's `codesign --verify --deep --strict` already returned
`CSSMERR_TP_NOT_TRUSTED` before any flags changed. Signature trust and app launch
are therefore not claimed as validated by these checks; content preservation was
verified independently using hashes.

An attempt to lock the installed app through a background administrator helper
was denied by macOS before its first change. Re-inspection reported `unlocked`
(`0/551`), so protection was not enabled on the installed app by that attempt.
TCC logged `kTCCServiceSystemPolicyAppBundles` for the helper process. Run the
command in an interactive terminal with App Management permission (System
Settings > Privacy & Security > App Management); `sudo` alone does not grant TCC
access. No TCC records or global update settings were modified.

References:

- [Apple filesystem security and BSD flags](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemDetails/FileSystemDetails.html)
- [Apple's App Store automatic update setting](https://support.apple.com/zh-cn/102629)
- [Apple's App Management privacy permission](https://support.apple.com/en-au/guide/mac-help/mchl211c911f/mac)
- Local `chflags(1)` and `chflags(2)` manual pages.
