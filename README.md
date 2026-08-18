# 无线麦（Remote Mic）· NotWizard 分支

[![License](https://img.shields.io/badge/license-GPL--3.0--only-blue.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#使用要求)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](Package.swift)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue.svg)](Sources/RemoteMic)
[![Fork](https://img.shields.io/badge/fork%20of-HD838A%2Fremote--mic--app-informational.svg)](https://github.com/HD838A/remote-mic-app)
[![Upstream Sync](https://img.shields.io/badge/upstream%20sync-v1.8.25-success.svg)](#与上游的关系)
[![Last Commit](https://img.shields.io/github/last-commit/NotWizard/remote-mic-app.svg)](https://github.com/NotWizard/remote-mic-app/commits/main)
[![Stars](https://img.shields.io/github/stars/NotWizard/remote-mic-app.svg?style=flat)](https://github.com/NotWizard/remote-mic-app/stargazers)

[English](README.en.md)

> 本仓库是 [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app) 的分支，在同步上游 v1.8.25 的基础上，增加了**可配置语音触发键**与**外接麦克风收音模式**，并修复了两个修饰键注入缺陷。详见[本分支的改动](#本分支的改动)。

![无线麦——为 Vibe Coding 而生的语音遥控器](Screenshots/Remote-Mic-Introduce-1.png)

无线麦是一款 macOS 应用，可以把小米蓝牙遥控器 2 Pro 变成 Mac 的无线语音遥控器。它同时提供常规 Dock 入口和常驻菜单栏入口。

按住遥控器的语音键即可说话；遥控器上的方向、确定、返回、主页、菜单、TV 和音量键也可以用来控制 Mac，或设置为打开常用应用。

无线麦使用 SwiftUI 原生开发，常驻运行时 CPU 占用率低于 0.5%，内存占用约 50 MB，比一个 Chrome 标签页还要轻量。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/connection-and-voice-dark-zh.png">
  <img alt="连接与语音设置页" src="Screenshots/connection-and-voice-zh.png">
</picture>

## 与上游的关系

代码血缘：[nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge) → [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app) → 本仓库。

上游负责产品主线、签名公证发布和官方分发渠道。本分支只在上游之上叠加下面这几项改动，其余功能、协议和默认行为与上游 v1.8.25 保持一致。上游的新版本会定期合并进来。

## 本分支的改动

### 语音触发键可配置

上游把语音键固定映射为 Fn。本分支允许在“按键映射”页的语音键卡片下方改选触发键：

| 触发键 | 适用场景 |
| --- | --- |
| **Fn**（默认） | 豆包输入法、macOS 系统听写，与上游行为逐字节一致 |
| 右 Command | 以右侧修饰键作为“按住说话”启动键的第三方语音软件 |
| 右 Option | 同上 |
| 右 Shift | 同上 |

只改变对外发出的“触发键”，不改按住说话语义、音频串流和 hold/tap 状态机。设置会持久化并纳入配置导入导出；旧配置缺少该字段时回退为 Fn。

选择右侧修饰键需要“辅助功能”权限；未授权时语音键不会产生副作用，并会提示授权。

### 外接麦克风收音模式

新增“用遥控器自带麦克风收音”开关，**默认开启**（等同上游行为：触发键 + 遥控器麦克风进虚拟麦）。

关闭后语音键变成纯触发器——按住只发送触发键，不再采集或路由遥控器的 ATVV 音频。这样就能用外接麦克风作为语音输入源，实现“遥控器触发 + 外接麦收音”，适合嘈杂环境或已有专业麦克风的场景。

关闭时“语音键模拟 Fn 点按”（Typeless 兼容）会自动禁用，因为它的注入时机依赖遥控器音频排空。

### 修复：右侧修饰键卡住

语音触发键设为右 Command / Option / Shift 时，修饰键可能“卡住”——表现为无法停止、误触发旁白 VoiceOver 或系统卡顿。现在修饰键随语音开始/结束注入按下与松开，并在断连、退出应用或切换触发键时确保松开。

### 修复：自定义快捷键丢失修饰键左右侧

录入“右 Command + 逗号”这类组合时，上游只保存为通用 Command，导致区分左右侧的第三方软件不响应。

本分支保留左/右侧信息，发送时按下对应侧别的真实修饰键（右 ⌘=54、右 ⌥=61、右 ⇧=60、右 ⌃=62；左侧 55/58/56/59）并逆序释放，界面中标出“左/右”。旧配置（无侧别）继续走原来的 flags-only 路径。

同时修正了修饰键的注入方式：之前以普通按键发送修饰键，不会真正改变系统修饰键状态，导致快捷键在触发目标软件的同时还会“漏”给前台应用（例如误弹钉钉设置页）。现在按真实硬件的方式发送修饰键状态变化（`flagsChanged`），行为与手动按键一致。

### 验证状态

自动化：`swift test` 244 项单元测试与 `scripts/test.sh` 42 项项目自检全部通过；触发键常量、mapper 重映射、默认 Fn 回归、注入键码与修饰、配置导入导出往返均有单元测试覆盖。

尚未完成：以上四项改动都**未经真实 RC003 遥控器 + 第三方语音软件的端到端验收**。测试手册见 [`Testing/VoiceTriggerKey.md`](Testing/VoiceTriggerKey.md) 与 [`Testing/CustomShortcutModifierSide.md`](Testing/CustomShortcutModifierSide.md)。

> **构建须知**：上游 v1.8.25 把私有组件 `GetSayAll/sayall-mac-remote` 声明为无条件依赖，没有访问权限时 SwiftPM 在解析阶段就会失败。本分支改为指向 [`Vendor/sayall-mac-remote`](Vendor/sayall-mac-remote) 下的本地 stub，`swift build`、`swift test` 和 Release 构建均可正常执行。代价是 **iPhone App 连接、Apple Watch 连接和网页版语音连接在本分支构建中不可用**——这三条路径的对话方（iOS App、Watch App、中继服务器）都在私有仓库里，无法自行实现。RC003 实体遥控器的全部功能不受影响。

## 使用要求

- Apple Silicon Mac（macOS 14 或更高版本），或 Intel Mac（macOS 13 或更高版本）；
- 小米蓝牙遥控器 2 Pro；
- 使用语音输入时，需要安装兼容麦克风，或在 Mac 上已有 BlackHole 2ch 等回环音频设备。

## 安装

本分支在 [Releases](https://github.com/NotWizard/remote-mic-app/releases) 提供 Apple Silicon 的 `Remote-Mic-<版本>.dmg`（ad-hoc 签名，未公证）。

打开 DMG 后双击唯一的 `Install Remote Mic.pkg`。安装器会安装 Remote Mic，并检查现有 `MiRemoteV 2ch`：健康且兼容时原样保留，缺失或不可用时才安装或更新。

**首次打开必须右键点击 App 图标并选择“打开”**，或先执行 `xattr -dr com.apple.quarantine "/Applications/Remote Mic.app"`。本分支没有 Apple Developer ID 证书，只能 ad-hoc 签名，Gatekeeper 会拦截直接双击。

需要经过 Apple 签名和公证的安装包时，请使用[上游官方 Releases](https://github.com/HD838A/remote-mic-app/releases)，但其中不含本分支的改动。

### 自动更新已关闭

本分支构建把 Sparkle 更新源指向本仓库，并关闭了自动检查。原因是构建产物仍沿用上游的 Bundle ID `com.hd838a.RemoteMic`：若继续指向上游 appcast，Sparkle 会把上游的签名版本当作新版本，**静默覆盖本分支构建**，4 项改动随之全部丢失。

代价是升级需要手动下载新的 DMG。本分支不发布 appcast 资产，因此手动“检查更新…”也不会找到版本。

### 从源码构建

```zsh
swift test               # 244 项单元测试
./scripts/test.sh        # 42 项项目自检
./scripts/build-app.sh   # 产出 dist/Remote Mic.app
./scripts/build-dmg.sh   # 产出 dist/Remote-Mic-<版本>.dmg 与 .sha256
```

## 首次使用

1. 在“系统设置 → 蓝牙”中打开蓝牙。
2. 长按遥控器 TV 键约 2 秒，直到底部白灯闪烁。
3. 同时长按“主页”和“菜单”键，使遥控器进入配对状态。
4. 在 Mac 上连接名称为 `MI RC`、`Xiaomi Bluetooth Remote 2`、`Xiaomi Bluetooth Remote 2 Pro` 或“小米蓝牙语音遥控器”的设备。
5. 启动 Remote Mic，按提示允许蓝牙权限。
6. 如果需要自定义普通按键，再允许“输入监控”和“辅助功能”。授权后请完全退出并重新打开应用。

应用启动后会显示 Dock 图标并常驻菜单栏：

- 单击 Dock 图标或左键单击菜单栏图标：打开设置面板；
- 右键单击菜单栏图标：显示连接状态、重新连接、日志、关于、版本号、检查更新、GitHub 和退出菜单。

设置面板左侧栏底部的“关于”页面提供版本、检查更新、版本历史、术语表、GitHub、语言、Dock 显示和启动行为选项。关闭“启动时自动打开主面板”后，普通启动仅保留菜单栏入口；更新完成并重启时仍会无条件显示主面板。

“应用语言”提供“跟随系统”“简体中文”和“English”三个选项。系统权限提示和第三方界面仍会按 macOS 自身的语言显示。

## 使用语音输入

1. 打开“连接与语音”页面。
2. 点击“刷新音频设备”。
3. 选择 `MiRemoteV 2ch`，或选择你已经安装的其他回环音频设备。
4. 在需要听写或语音输入的应用中选择同一个设备作为麦克风。
5. 单击目标输入框，按住遥控器语音键说话，松开后结束。

如果想先确认音频链路是否正常，可以点击“发送 1 秒测试音”，或在 QuickTime Player 的“新建音频录制”中观察输入电平。

想改用外接麦克风收音时，关闭“用遥控器自带麦克风收音”，跳过第 2–4 步，直接在目标应用里选择你的外接麦克风。

### 配合第三方语音软件

第三方语音软件以右侧修饰键作为“按住说话”启动键时，在“按键映射”页把语音触发键改为对应的右 Command / Option / Shift 即可。这是本分支新增的能力，详见[语音触发键可配置](#语音触发键可配置)。

### Typeless 兼容

Typeless 等点按 Fn 开始、再次点按结束的语音工具，与 RC003 默认的 Fn 长按行为不兼容。在“连接与语音”中开启“语音键模拟 Fn 点按”后，无线麦会在语音流开始和排空结束时各发送一次 Fn 点按。Typeless 和无线麦仍需选择同一个回环设备，并需授予“辅助功能”权限。

该模式仍然要求**按住 RC003 语音键说话、松开结束**；RC003 固件在松开语音键后不会继续发送麦克风音频，因此这不是持续录音或免按键模式。开关默认关闭；豆包输入法等使用 Fn 长按的工具应保持关闭。

豆包输入法找不到普通虚拟麦克风时，请先安装 `MiRemoteV 2ch`，然后在 Remote Mic 中选择它。详细步骤见[豆包输入法兼容说明](Resources/豆包输入法兼容说明.md)。

![豆包输入法 Mac 版选择 MiRemoteV 2ch 麦克风](Screenshots/doubao-input-method-macos.png)

## 自定义遥控器按键

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/key-mapping-dark-zh.png">
  <img alt="按键映射设置页" src="Screenshots/key-mapping-zh.png">
</picture>

打开“按键映射”页面并启用自定义映射后，可以修改方向、确定、返回、主页、菜单、TV、电源和音量键的功能。

每个普通按键都可以设置单击动作，并可额外设置双击和长按动作。动作支持键盘操作、系统音量、播放控制、打开当前 Mac 已安装的常用应用，以及录入任意自定义键盘快捷键。

录入自定义快捷键时，本分支会保留修饰键的左右侧信息，并在显示中标出“左/右”。从上游升级过来后，请重新录入一次相关快捷键——旧记录不包含左右侧信息。

“打开自定义 APP”可以从本机选择任意 `.app`，并选择只打开应用、激活后发送该应用的聚焦快捷键，或记录一次目标输入框后自动聚焦。目标应用升级后如果输入框结构变化，请重新记录；无线麦不会使用固定屏幕坐标，也不会记录输入框中的文字。

- 没有设置双击或长按时，单击保持原有的即时响应和按住重复；
- 设置双击后，应用会等待约 0.3 秒区分单击和双击；
- 设置长按后，按住约 0.55 秒执行长按动作，并抑制单击；
- 设置了双击或长按的实体键不会再按住重复，避免多个动作同时触发。

语音键不参与普通按键映射；它的触发键在同一页面单独配置。

## 使用统计

“统计”页面可以按日、周或全部范围查看遥控器按键次数、语音时长，以及最长单次语音排行。所有统计数据仅保存在本机，不会上传。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/statistics-dark-zh.png">
  <img alt="无线麦使用统计页" src="Screenshots/statistics-zh.png">
</picture>

## 权限与隐私

- 蓝牙：连接遥控器并接收语音；
- 输入监控：识别遥控器普通按键；
- 辅助功能：把按键动作发送给当前应用；语音触发键使用右侧修饰键时也需要该权限。

无线麦不会上传或保存语音，不会自动修改系统默认输入、输出设备，也不会在日志中记录语音内容、蓝牙地址或外设标识。

## 卸载

1. 退出无线麦。
2. 运行 `Uninstall Remote Mic.pkg`，移除 `MiRemoteV 2ch` 兼容麦克风。
3. 删除“应用程序”中的 Remote Mic.app。

卸载兼容麦克风不会修改或删除已有的 BlackHole。

## 遇到问题

请先查看[排障指南](TROUBLESHOOTING.md)。首次安装的完整步骤见[首次安装说明](Resources/首次安装说明.md)。

开发、构建、协议、测试和发布信息见[技术文档](TECHNICAL.md)。

后续开发计划见 [TODO](TODO.md)。

本分支自身改动的问题请在[本仓库 Issues](https://github.com/NotWizard/remote-mic-app/issues) 反馈；上游主线功能的问题请到[上游仓库](https://github.com/HD838A/remote-mic-app/issues)反馈。

## 许可与来源

本仓库中的 macOS App、驱动及相关软件代码采用 `GPL-3.0-only` 许可。macOS App 的 Logo 和 App Icon 是需要单独授权的专有品牌资产，本分支不获得也不转授这些品牌权利，详情见 [LOGO-LICENSE.md](LOGO-LICENSE.md)。完整版权和第三方信息见 [COPYRIGHT.md](COPYRIGHT.md) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目最初 fork 自 [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge)，随后由 [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app) 独立维护，本仓库再从其分支而来。

`MiRemoteV 2ch` 的设备命名及让豆包枚举设备的 USB transport 兼容方案参考自 [VincentKingHsu/MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) `v1.0.0-beta.1`（MIT）；该项目的兼容驱动同样基于 BlackHole。本项目不复用 MiRemoteVoice 的二进制替换脚本，而是从 [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) `v0.7.1`（固定提交 `e2b22aaaba4e507a097131704bf96dabc004d9cf`）源码独立派生构建 `MiRemoteV2ch.driver`，适用 `GPL-3.0`。它使用独立标识，可与已安装的 BlackHole 并存，不覆盖或删除其文件。
