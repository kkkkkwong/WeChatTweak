# WeChatTweak

[![README](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/kkkkkwong/WeChatTweak)
[![README](https://img.shields.io/badge/Telegram-black?logo=telegram&logoColor=white)](https://t.me/wechattweak)
[![README](https://img.shields.io/badge/FAQ-black?logo=googledocs&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak/wiki/FAQ)

用于 macOS 微信的命令行补丁工具。本仓库基于
[Sunny Young 的 WeChatTweak](https://github.com/sunnyyoung/WeChatTweak)，
增加新版微信防撤回适配、运行时菜单标记和单应用更新保护。

## 当前功能

| 功能 | 当前支持与说明 |
| --- | --- |
| 消息防撤回 | 为微信 4.1.13（269602）和 4.1.15.35（270115）提供 arm64 适配，可选静默保留、原生撤回提示或自定义 `[对方已撤回]` 标记。自定义模式保留自己的正常撤回行为。 |
| 菜单栏注入标记 | 运行时加载后显示 `WeChatTweak ✓`，可查看微信版本、构建号和防撤回钩子状态。 |
| 单应用更新保护 | `updates --lock` 锁定指定微信的应用文件，`--unlock` 恢复可修改状态；不更改 App Store 的全局自动更新设置。 |
| 独立运行时注入 | `inject-runtime` 可单独安装或更新菜单标记所需的运行时，无需选择构建补丁配置。 |
| 补丁预检与签名 | `--dry-run` 预检时不修改应用；新增适配会校验原始字节，写入后重新签名。 |
| 原项目功能 | 保留历史构建配置中的禁止自动更新、客户端多开等补丁，具体支持以对应构建的 `config.json` 条目为准。 |

**实测结果：**2026-10-28，使用者确认 App Store 版微信 **4.1.15.35（270115），
Apple Silicon / arm64** 的防撤回及标记正常。其他构建、架构和未逐项测试的模式仍需分别验证。
270115 不包含客户端多开或微信内置更新逻辑的补丁；更新保护使用上述应用文件锁。

## 从源码构建与使用

需要 macOS 12 或更新版本，以及 Swift 6.0 或更新的工具链。先克隆并进入本仓库，再运行：

```bash
swift build

# 查看命令及本地配置支持的构建
.build/debug/wechattweak --help
.build/debug/wechattweak versions --app "/Applications/WeChat 2.app" --config ./config.json

# 预检当前 270115 的自定义防撤回模式，不修改应用
.build/debug/wechattweak patch --app "/Applications/WeChat 2.app" --config ./config.json --custom-recall-label --dry-run

# 完全退出微信、备份应用后执行；按实际安装位置修改 --app
sudo .build/debug/wechattweak patch --app "/Applications/WeChat 2.app" --config ./config.json --custom-recall-label
```

重新启动微信后可查看 `WeChatTweak ✓` 菜单，并用新消息撤回验证效果。
请始终显式传入 `--config ./config.json`：CLI 默认下载原项目配置，可能不包含本仓库新增适配。
CLI 和运行时动态库应来自同一次构建；已加文件锁的应用需先执行 `updates --unlock`。
补丁仅影响之后收到的撤回消息，不会恢复已撤回的历史消息。

原项目仍提供 `brew install sunnyyoung/tap/wechattweak` 和
`brew upgrade wechattweak`，安装的是原项目发行版；使用本仓库新增功能请按上述方式从源码构建。

## 菜单栏注入标记

新版运行时库加载后，会在微信顶部菜单栏显示 **`WeChatTweak ✓`**。展开后可查看：

- `✓ 运行时已加载`：表示当前这次微信启动确实加载了插件；点击可查看注入信息。
- 微信版本和构建号。
- 防撤回状态：等待初始化、钩子已安装或静态补丁已识别（效果待实测）、未适配、钩子未安装。

菜单只出现在微信主进程中；微信重建菜单后会自动补回，重复初始化不会重复添加。
标记证明运行时已加载，防撤回效果仍需用新消息撤回测试确认。

```bash
swift build

# 预检：只验证注入，不修改应用
.build/debug/wechattweak inject-runtime --app "/Applications/WeChat 2.app" --dry-run

# 完全退出微信、备份应用后，注入新版运行时并重新签名
sudo .build/debug/wechattweak inject-runtime --app "/Applications/WeChat 2.app"
```

已安装旧版运行时的微信，需要重新安装这个新版动态库并完全重启，才能显示标记。
`inject-runtime` 支持采用 `Contents/Resources/wechat.dylib` 的 arm64 微信，
不依赖构建补丁配置；可用 `--runtime-dylib` 指定动态库路径，默认从 CLI 同目录读取。
它添加动态库加载命令并重新签名应用，不写入构建专属的防撤回补丁地址。
支持构建的 `patch --custom-recall-label` 流程也会安装同一个运行时。
静态防撤回补丁和应用文件锁独立工作，不会创建这个菜单。
当前本机的构建 **270115 已适配防撤回**，启用方法见下方 4.1.15 说明。
加过应用文件锁时需先解锁；若 macOS 拒绝操作，需允许运行终端的「App 管理」权限。
实现和验证范围见 [菜单标记说明](docs/injection-menu.md)。

## 只阻止微信应用被更新替换

针对当前安装的 **微信 4.1.15（构建号 270115，App Store 版）**，可单独锁定应用文件，
阻止文件写入、删除及应用目录替换。此操作不依赖补丁地址，也不修改微信二进制、签名、
聊天数据或 App Store 的全局自动更新设置。

```bash
swift build --product wechattweak

# 查看指定微信的文件锁状态
.build/debug/wechattweak updates --app "/Applications/WeChat 2.app"

# 单独锁定这个微信；应用归 root 所有时需要 sudo
sudo .build/debug/wechattweak updates --app "/Applications/WeChat 2.app" --lock

# 以后需要更新、重新打补丁、移动或删除微信时，先解锁
sudo .build/debug/wechattweak updates --app "/Applications/WeChat 2.app" --unlock
```

加锁、解锁均支持 `--dry-run` 预检。只处理指定的微信应用目录，不跟随目录内的符号链接；
若发现可能与其他应用共享的硬链接，会拒绝操作。解锁会清除应用内已有的 Finder「已锁定」标记，
其他文件标志会保留。

这是应用文件的写入保护，App Store 仍可能显示更新或下载更新包；管理员或主动清除文件锁的
安装程序可以解除保护。已验证文件写入和目录替换被拒绝，尚未以真实 App Store 升级验证。
机制和验证记录见 [更新保护说明](docs/update-protection.md)。

若使用 `sudo` 仍提示 `Operation not permitted`，需在「系统设置 → 隐私与安全性 → App 管理」
允许运行命令的终端修改应用，再从该终端执行命令；管理员权限本身不能替代这项 macOS 授权。

## 微信 4.1.15（270115）防撤回

适配 **App Store 版微信 4.1.15.35（构建号 270115），Apple Silicon / arm64**。
支持静默保留消息、原生撤回提示及自定义标记 `[对方已撤回]`。自己的撤回在自定义模式中
仍保留原生行为。新版运行时也包含顶部菜单注入标记及接收内容缓存。

```bash
swift build

# 预检，不修改或签名
.build/debug/wechattweak patch --app "/Applications/WeChat 2.app" --config ./config.json --custom-recall-label --dry-run

# 完全退出微信、备份应用后执行；需在 Terminal / Warp 中输入 sudo 密码
sudo .build/debug/wechattweak patch --app "/Applications/WeChat 2.app" --config ./config.json --custom-recall-label

# 可选：使用原生撤回提示
sudo .build/debug/wechattweak patch --app "/Applications/WeChat 2.app" --config ./config.json --show-recall-notice

# 可选：静默保留消息
sudo .build/debug/wechattweak patch --app "/Applications/WeChat 2.app" --config ./config.json
```

自定义模式会更新运行时库并安装两个内联钩子；切换到静态模式会恢复这两个入口，
避免旧钩子继续改写提示。更换模式后需完全重启微信。仅执行 `inject-runtime` 不会安装
防撤回所需的静态入口补丁；请使用上面的 `patch` 命令。

21 项 Swift 测试、生产钩子的 ARM64 合成调用测试，以及真实应用副本的三种模式切换、
逐字节比对和严格签名验证均通过。**使用者已实测确认防撤回及标记正常**；
三种模式、各消息类型与自己的撤回行为仍需逐项测试。
不声明 Intel、强制升级绕过或已撤回历史消息恢复支持。地址与验证记录见
[270115 适配记录](docs/wechat-270115.md)。

## 从源码使用微信 4.1.13 补丁

新增适配 **微信 4.1.13（构建号 269602），Apple Silicon / arm64** 的防撤回功能。
此构建暂不包含禁止自动更新和多开补丁；其他构建号需单独适配。默认仍为静默防撤回；使用
`--custom-recall-label` 可保留原消息，并将撤回提示行替换为自定义标记「[对方已撤回]」。

```bash
# 构建 CLI 和运行时动态库
swift build -c release

# 指定实际应用路径和本仓库配置，先预检（不修改或签名）
.build/release/wechattweak patch --app "/Applications/WeChat 2.app" --config ./config.json --custom-recall-label --runtime-dylib ./.build/release/libWeChatTweakRuntime.dylib --dry-run

# 完全退出微信，备份应用后启用自定义标记
.build/release/wechattweak patch --app "/Applications/WeChat 2.app" --config ./config.json --custom-recall-label --runtime-dylib ./.build/release/libWeChatTweakRuntime.dylib

# 可选：使用微信原生撤回提示（不是自定义标记）
.build/release/wechattweak patch --app "/Applications/WeChat 2.app" --config ./config.json --show-recall-notice
```

自定义模式会将运行时库复制到微信资源目录、注入加载命令并重新签名。CLI 和运行时库必须使用同一配置构建。

请显式传入 `--config ./config.json`，默认使用的是原项目的远程配置。
补丁修改 `Contents/Resources/wechat.dylib` 并重新签名应用；原始字节不匹配会拒绝修改。
恢复时用备份替换应用；微信更新后需重新核对构建号。

如果用本分支早期版本打补丁后无法启动，请重新执行 `swift build`，再运行上面的补丁命令。
修复后的签名流程会清除与临时签名不兼容的开发者权限，并保留微信的沙盒及相机、麦克风等权限。

开发验证使用 `swift test`。本次补丁的位置、来源和验证范围见 [适配记录](docs/wechat-269602.md)。

## 致谢

感谢原作者 **[Sunny Young（sunnyyoung）](https://github.com/sunnyyoung)** 开源
[WeChatTweak](https://github.com/sunnyyoung/WeChatTweak)，提供命令行工具、补丁框架、
历史版本适配及相关技术文章。本仓库在原项目基础上继续适配，并保留原作者署名与许可证。

感谢 **[wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall)** 的作者与贡献者
分享防撤回运行时、内联钩子和提示渲染实现。运行时中的相关代码基于该项目改编，
保留其 [MIT 许可证及 Morax 版权声明](Sources/WeChatTweakRuntime/LICENSE-MIT)。

感谢 [zengtianli/WeChatTweak](https://github.com/zengtianli/WeChatTweak) 和
[EchoXml/WeChatTweak](https://github.com/EchoXml/WeChatTweak) 提供的版本适配与签名分析参考，
以及所有贡献代码、测试和反馈的使用者。各构建的来源与验证范围见 `docs/` 中的适配记录。

## 参考

- [微信 macOS 客户端无限多开功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-wu-xian-duo-kai-gong-neng-shi-jian/)
- [微信 macOS 客户端拦截撤回功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/)
- [让微信 macOS 客户端支持 Alfred](https://blog.sunnyyoung.net/rang-wei-xin-macos-ke-hu-duan-zhi-chi-alfred/)

## 贡献者

This project exists thanks to all the people who contribute.

[![Contributors](https://contrib.rocks/image?repo=sunnyyoung/WeChatTweak)](https://github.com/sunnyyoung/WeChatTweak/graphs/contributors)

## License

项目采用 [AGPL-3.0](LICENSE)。防撤回运行时中改编自 wechat-antirecall 的代码另保留
[MIT 许可证及版权声明](Sources/WeChatTweakRuntime/LICENSE-MIT)。
