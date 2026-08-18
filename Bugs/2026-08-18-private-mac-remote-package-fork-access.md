# 本 fork 无法解析私有 Mac 远控组件导致构建失败

- 时间：2026-08-18
- 状态：已修复，构建与测试通过
- 影响范围：`NotWizard/remote-mic-app` 分支的全部 `swift build`、`swift test`、Release 构建和 App 打包
- 功能点：`GetSayAll/sayall-mac-remote` 私有 Swift Package 依赖解析
- 简单描述：合并上游 v1.8.25 后，SwiftPM 在依赖解析阶段即退出，本分支无法构建或运行任何测试。
- 相关上游记录：[`2026-08-13-private-mac-remote-package-ci-access.md`](2026-08-13-private-mac-remote-package-ci-access.md)（上游为自身 CI 配置部署密钥解决同一依赖的认证问题）。

## 复现

在没有 `GetSayAll/sayall-mac-remote` 访问权限的环境执行：

```zsh
swift build
```

失败于依赖解析，尚未进入编译：

```text
error: 'sayall-mac-remote': Failed to clone repository https://github.com/GetSayAll/sayall-mac-remote.git:
    remote: Repository not found.
    fatal: repository 'https://github.com/GetSayAll/sayall-mac-remote.git/' not found
```

`gh repo view GetSayAll/sayall-mac-remote` 返回 `Could not resolve to a Repository`，确认当前账号 `NotWizard`（本仓库所有者，token 具备 `repo` scope）对该仓库无可见性。

正常边界：`swift build`、`swift test`、`scripts/test.sh` 和 Release 构建都应在无该私有仓库访问权限时完成，且 RC003 实体遥控器的按键、语音触发键、音频路径行为不得改变。

## 日志结论

失败发生在 SwiftPM 解析阶段，公开依赖 Sparkle 可正常获取，只有 `sayall-mac-remote` 返回仓库不存在。没有任何 Swift 文件进入编译，因此不能把失败归因于合并结果或产品代码。

`scripts/test.sh` 使用 `xcrun swiftc` 直接编译源码子集，不经过 SwiftPM，因此在此故障下仍能通过 42 项自检——这说明自检通过不足以证明整个包可构建。

## 根因

`Package.swift` 把该私有组件写在 `packageDependencies` 数组字面量中并固定 revision `04a1bf2b713ee98c4d2c07cd690bb4b26288a82d`，其产物 `SayAllMacRemoteCore`、`SayAllMacRemoteUI` 是 `RemoteMic` 可执行目标的必需依赖，`SayAllMacRemoteCore` 还是测试目标的必需依赖。

同一文件中另外三个私有依赖（`SAYALL_AI_PACKAGE_PATH`、`SAYALL_MACRO_PLATFORM_PATH`、`REMOTE_MIC_HARDWARE_SIMULATION_PATH`）都由环境变量控制且配合 `#if canImport(...)` 优雅降级，缺失时只是功能不可用。`sayall-mac-remote` 没有这两层保护，`SettingsView.swift` 与 `BridgeAppModel.swift` 的 `import` 也没有 `#if` 包裹，因此缺失即硬失败。

该组件不是自包含算法，无法自行实现：它提供的 `PhoneRemoteServer`、`WatchBluetoothRemoteServer`、`WebRemoteRelayClient` 都是协议客户端，对话方分别是私有 iOS 仓库中的 App、Watch App 和私有中继服务器，协议与生产域名均未公开。

## 修复

- 新增本地 stub 包 `Vendor/sayall-mac-remote`，包标识保持为 `sayall-mac-remote`，因此根 `Package.swift` 中的产物引用行与上游逐字节一致。
- 根 `Package.swift` 只改动一处：把该远端依赖换成 `.package(path: "Vendor/sayall-mac-remote")`，并保留原 revision 于注释中，便于日后取得权限后还原。
- stub 提供实测所需的全部符号：`PhoneRemoteServer`、`WatchBluetoothRemoteServer`、`WebRemoteRelayClient`、`WebRemoteSessionState`、`WebRemoteConfiguration`、`RemoteVoiceStartResult`、`WatchBluetoothAudioSignalMetrics`，以及 UI 侧的 `WebRemoteSessionModel`、`WebRemoteSessionLocalization`、`WebRemoteSessionView`。
- 三个传输类实现为空操作，回调只存不调；`WebRemoteConfiguration.relayURL()` 返回 `nil`，使网页会话如实报告为不可用。`WatchBluetoothAudioSignalMetrics` 按真实语义实现样本计数、非零计数、峰值与 RMS，避免日志出现假数据。
- `BridgeAppModel.swift`、`SettingsView.swift` 未做任何改动，与上游保持一致，后续合并上游不会因本修复产生冲突。
- `Tests/RemoteMicTests/WatchBluetoothVoiceJourneyTests.swift` 原先通过 `_testConfigureSession`、`_testHandleMessage` 等内部钩子驱动私有组件真实状态机。stub 无法提供这些行为，且补造钩子会让测试对着假实现通过，因此删除该部分，只保留原有 4 条针对 `BridgeAppModel.swift` 源码的接线断言。
- `Tests/RemoteMicTests/LocalizationTests.swift` 两处断言要求 README 保留上游 CDN 下载入口与 TestFlight 链接。本分支已按要求移除推广内容，故调整为匹配 fork 的安装小节，并保留"下载链接必须与版本无关"及全仓库 TestFlight 链接唯一性这两项真实意图。

## 验证

原始失败用例已从失败变为通过：

- `swift build`：通过；
- `swift test`：244 项测试、21 个 suite 全部通过；
- `./scripts/test.sh`：42 项项目自检通过；
- `swift build -c release`：通过；
- `./scripts/build-app.sh`：产出 `dist/Remote Mic.app`，版本 `1.8.25 (120)`、`arm64`、ad-hoc 签名；
- `./scripts/verify-release-dependency-pins.sh`：通过（注意该脚本读取 `.github/workflows/*.yml` 中的 pin，不读 `Package.swift`，因此它通过不代表本地依赖已就绪）。

本次修复只涉及依赖解析和构建输入，不证明任何真机行为已验收。RC003 实体遥控器按键、语音触发键、外接麦克风模式和自定义快捷键修饰键侧别仍未完成真机验证。iPhone、Apple Watch 和网页版连接在本分支构建中确定不可用，不属于回归。

## 遗留问题

- `.github/workflows/` 仍会 checkout 三个私有仓库，本仓库 CI 必然失败，尚未处理。
- 构建产物仍使用上游 Bundle ID `com.hd838a.RemoteMic`，`SUFeedURL` 指向上游 appcast 且自动检查开启。安装本分支构建后，Sparkle 会用上游签名版静默覆盖它。发布可安装的分支版本前必须先解决。
