# 承重最重的蓝牙桥没有任何行为测试覆盖

- 编号：A7
- 时间：2026-08-21
- 状态：已补测试并完成最小接缝提取，自动化通过；**真机未验收**
- 影响范围：所有安装的全部语音会话
- 功能点：`XiaomiBluetoothBridge` ATVV 事件处理、语音会话状态机、帧重组与解码

## 这不是一个功能缺陷，而是一个测试缺口

`Sources/RemoteMic/XiaomiBluetoothBridge.swift` 约 1050 行，是本产品最承重的单个文件：每一次语音会话都从它流过。本项开始时，`Tests/` 全树对 `XiaomiBluetoothBridge` 的引用数为 **0**。

```text
$ grep -rn "XiaomiBluetoothBridge" Tests/
（无匹配）
```

也就是说：`STREAM_START → AUDIO → STREAM_STOP` 这条 RC003 基线路径、流中断连、重连后迟到回调，全部只由人工真机点测和线上日志兜底。`AGENTS.md` 的「macOS Feature Flag 与预览版回归门禁」把 RC003 基线明确列为发布门禁，并要求「如果单元测试无法真实驱动 CoreBluetooth 回调，必须使用可注入事件回放」——本仓库此前既没有回放设施，也没有该门禁对应的自动化。

阻塞原因是真实的：`CBCentralManager` 与 `CBPeripheral` 都无法在单元测试中构造或驱动。

## 为什么选择提取事件核心，而不是给 CoreBluetooth 套协议

先确认了一件事：**桥本身其实可以构造**——`init` 只保存 `settings`、`delegate`、`targetIdentifier`、`excludedIdentifiers`，不触碰任何 CoreBluetooth 对象；`CBCentralManager` 只在 `start()` → `beginConnectionCycle()` 里才创建。真正测不了的不是构造，而是三件事：`lifecycle` 是私有的、`handleControl`/`handleAudio` 是私有的、`write()` 需要真实的 `CBPeripheral` 与 `CBCharacteristic`。

考虑过给 CoreBluetooth 套一层协议，否决了：那需要一个真实实现加一个假实现，机器量远大于收益，且与本仓库既有形态不一致。`RemoteButtons.swift` 的 `HIDMappingRetryPolicy`、`BluetoothLifecycle.swift` 的 `BluetoothReconnectPolicy` 都是同一种做法：**纯类型、零依赖、单元测试直接驱动**。

因此把 ATVV 语音会话的全部决策提取成 `ATVVVoiceSessionCore`，放在 `Sources/RemoteMic/BluetoothLifecycle.swift`，紧邻 `BluetoothLifecyclePhase`、`ATVVSessionGate`、`BluetoothReconnectPolicy`。该文件同时被 `swift test` 与 `scripts/test.sh` 编译，无需改动构建脚本。

边界划分是干净的：**连接周期归桥，语音会话归核心。**

| 归属 | 内容 |
| --- | --- |
| 桥（保留，未改） | `CBCentralManager` 生命周期、扫描、连接、待连截止时间、重连调度、初始化超时、电量/型号读取、`peripheral` 身份校验 |
| 核心（提取） | 能力协商、会话状态机、帧重组、IMA-ADPCM 解码、增益后处理、相位与代号门控 |

核心把结果作为**有序 `Effect` 列表**返回，桥按序施加到 delegate 上，测试因此能看到与 delegate 完全相同的顺序。

### 唯一注入的依赖，以及为什么它必须是闭包

`write` 是唯一注入项，理由是它的**返回值会回流进会话状态**：`MIC_OPEN` 只有在写入真的发出去之后才算「已打开」，`MIC_CLOSE` 还要把 `written=` 写进日志。这两点让它无法表达成返回值型 effect。其余全部是返回值，没有第二个闭包，也没有协议。

### 为保持行为不变而做的三处刻意设计

1. **日志与 delegate 的相对顺序**。`BridgeAppModel.bluetoothBridgeDidStartVoice` 自己也写日志（`ATVV STREAM accepted trace=…`），所以现网日志顺序是「delegate 先、`ATVV STREAM START` 后」。把日志放进核心会颠倒这个顺序，于是 `ATVV STREAM START` / `ATVV STREAM STOP` 两行留在桥里，在 delegate 调用之后写。
2. **`voiceDidAbort` 与 `voiceDidStop` 分开**。`resetSession()` 路径从来不写 stream 日志，`stopStreaming()` 路径要写。合成一个 case 会凭空多出或少掉日志行。
3. **`implicitFromAudio` 标记**。原代码在 `startStreaming()` 之后才写 `ATVV STREAM implicit_audio_race`，顺序是「delegate → `STREAM START` → `implicit_audio_race`」。标记让桥能复原这个顺序。

`failInitialization` 只重置编解码状态、不结束会话，所以核心额外暴露了窄口的 `resetDecodeState()`，而不是复用 `reset()`。

### 与 A4 重连风暴修复的关系

先读了 [`2026-08-21-bluetooth-reconnect-storm-when-remote-absent.md`](./2026-08-21-bluetooth-reconnect-storm-when-remote-absent.md)。A4 的修复全部落在连接周期函数上：`beginConnectionCycle`、`hasConnectionCycleInFlight`、`releaseCentral`、`finishAttempt`、`startPendingConnectDeadline`、`stop`、`reconnectNow`。**本项一行都没有碰这些函数**，长寿命 central 与永久待连请求原样保留。

## 新增测试

`Tests/RemoteMicTests/XiaomiBluetoothBridgeSessionTests.swift`，11 项。回放字节序列与既有 `ATVVProtocolTests` 的能力应答夹具一致（`0B 01 00 02 03 00 78`）。

三项优先用例：

1. `remoteInitiatedStreamProducesOneSessionAndCompleteAudioWithoutMicOpen` —— RC003 基线。`STREAM_START → AUDIO → STREAM_STOP`，**没有任何前置主动 `MIC_OPEN`**，必须恰好产生一个会话和完整音频。音频按 100/100/100/60 字节投递、帧长 120，没有一次投递落在帧边界上，因此真正验证了跨通知的帧重组。参考样本由**同一个生产解码器**按对齐输入算出，不是独立实现——所以这条测试证明的是帧重组与解码器跨帧状态连续性，**不是**解码本身正确；解码正确性由 `ATVVProtocolTests` 的固定期望值单独钉住。
2. `disconnectMidStreamEndsTheSessionAndStopsAcceptingAudio` —— 流中断连必须干净结束会话：恰好一个 `voiceDidAbort`、不再流式、`sessionID` 归零、协商结果清空；断连后仍在途的帧不得解码也不得重开会话；再断一次不得伪造第二个停止。
3. `staleGenerationCallbacksAreRejectedWhileTheCurrentOneStillWorks` —— 上一代连接的迟到回调不得被当前代接受。**该用例后半段是正向对照**：紧接着用当前代的同一批事件确认会话照常开启并解码，否决「全部拒绝也能通过」的空洞实现。

另外 8 项覆盖：仅音频的隐式开流、`STREAM_STOP` 后 0.3 秒内的尾音不得重开会话（超窗后应重开）、无会话时断连不得伪造停止、错误相位的能力应答被忽略、仅 8 kHz remote 被拒并重试、协商 16 kHz 后改推 8 kHz 被拒、`MIC_OPEN` 写入失败不得置位「已打开」、主动 `MIC_OPEN` 被取消后抑制随后的流并回写 `MIC_CLOSE`。

## 负向对照

每个优先用例都手工打断对应行为，确认变红，再逐字节恢复。

| 对照 | 打断方式 | 结果 |
| --- | --- | --- |
| NC1 | `handleStreamStart` 与 `handleAudioValue` 都要求先有 `isMicrophoneOpen`（即重新引入 RC003 回归） | 退出码 1，**30 个 issue / 6 项失败**，含基线用例本身 9 个 |
| NC2 | `reset()` 丢掉 `isStreaming` 分支，不再发 `voiceDidAbort` | 退出码 1，**仅断连用例失败，3 个 issue** |
| NC3 | `handleControlValue`/`handleAudioValue` 去掉 `generation == callbackGeneration` | 退出码 1，**仅迟到回调用例失败，7 个 issue** |
| NC4 | `HIDRemoteMonitor.process(usages:)` 整体 `DispatchQueue.main.async` 延后 | 退出码 1，`performedActions → 0`（期望 1） |

NC2 与 NC3 只打中各自的用例，说明断言是定向的，不是一堆恒真断言互相掩护。

恢复后校验为**逐字节相同**，不只是「看起来一样」：

```text
$ cmp Sources/RemoteMic/BluetoothLifecycle.swift    /tmp/nc_BluetoothLifecycle.swift.orig    → 无输出
$ cmp Sources/RemoteMic/XiaomiBluetoothBridge.swift /tmp/nc_XiaomiBluetoothBridge.swift.orig → 无输出
$ cmp Sources/RemoteMic/HIDRemoteMonitor.swift      /tmp/a7_HIDRemoteMonitor.orig            → 无输出
$ git diff -- Sources/RemoteMic/HIDRemoteMonitor.swift → 空（该文件最终没有任何生产改动）
```

## 源码文本断言普查

用括号配对与函数体大括号配对做了一次统计，把「断言主体是从磁盘读入的文件文本」的断言全部找出来（先按变量名简单匹配会误报：同一文件里 `monitor`、`model`、`source` 在不同测试函数里既是实例也是文件文本，因此改成按函数体划分作用域）。

```text
Tests/ 全部断言：2098
其中源码文本断言：620  → 29.6%
```

与审计给出的 28% 吻合（取样提交不同，且本会话有另一个代理在并行新增测试）。

分两类：

| 类别 | 数量 | 说明 |
| --- | --- | --- |
| A：断言对象是 `Sources/` 下的 `.swift` | **306** | 原则上应该换成行为断言 |
| B：断言对象是 shell 脚本、GitHub workflow、installer `preinstall`/`postinstall`、文档、`.strings` | **314** | 打包与构建不变量，**没有运行期表面**，按任务约定保留 |

A 类 306 项的落点：

| 被断言的源文件 | 数量 | 本次能否转换 |
| --- | --- | --- |
| `BridgeAppModel.swift` | 134 | 否——本会话禁止编辑，且 `startPhoneVoice` 等目标方法是 `private` |
| `SettingsView.swift` | 98 | 否——本会话禁止编辑 |
| `RemoteMicApp.swift` | 23 | 否——本会话禁止编辑 |
| `OnboardingView.swift` | 22 | 否——SwiftUI view body，无快照设施 |
| `MacroFeatureIntegration.swift` | 10 | 否——依赖私有包 |
| `RemoteMappingCanvas.swift` | 10 | 否——本会话禁止编辑 |
| 两个 ScreenshotRenderer | 6 | 否——需要真实渲染 |
| `HIDRemoteMonitor.swift` | 3 | **部分是**——见下 |

另外 306 项里有 **约 210 项集中在 `SettingsPageRegressionTests.swift`**（复核实测该文件断言总数约 218，最初写的 249 高于文件本身的断言数，已更正），该文件本会话正被另一个代理修改，改它会直接冲掉对方在途工作。

### 已转换：1 项

`RemoteButtonsTests.HIDCallbacksDoNotDeferReportHandling` → `HIDReportsAreTurnedIntoActionsSynchronously`。

原断言是 `#expect(!source.contains("DispatchQueue.main.async"))`，即「`HIDRemoteMonitor.swift` 全文不得出现这个字符串」。它有两个方向都不准：

- **假失败**：监视器里任何一处合理的主线程跳转都会让它变红，与报告路径是否被延后无关。
- **假通过**：改用 `perform(_:with:afterDelay:)`、`DispatchWorkItem`、actor hop 等任何别的方式延后报告，它照样是绿的。

替换后用既有的 `connectSimulatedDevice` / `handleSimulatedReport` 接缝（本仓库已在用，`runtimePermissions` 与 `actionPerformer` 都可注入）投递一次真实报告，要求动作在 `handleSimulatedReport` 返回之前就已发生——中间没有任何 runloop 转动，被延后的实现必然停在 0。这是在测那条性质本身，严格强于原断言：NC4 证明它能抓到延后，而它不再依赖任何字符串拼写。

**没有为此改动任何生产代码**：`HIDRemoteMonitor.swift` 相对 HEAD 无差异。

### 保留：619 项，理由分三种

1. **314 项（B 类）**：守的是构建脚本与打包不变量，没有运行期表面，属于任务明确允许保留的情形。
2. **265 项**：断言对象是本会话被明令禁止编辑的五个文件（`SettingsView.swift`、`BridgeAppModel.swift`、`RemoteMappingCanvas.swift`、`RemoteMicApp.swift`、`Localizable.strings`）。这些断言基本都在给 `private` 方法或 SwiftUI view body 的内部结构做代理，换成行为断言需要在那些文件里开接缝。
3. **40 项**：技术上可转换但本次未做——`OnboardingView`/renderer 需要快照设施，`HIDRemoteMonitor` 剩下的 2 项（`eventSuppressor.arm` 与 `onButtonPressed` 的先后）需要在回调执行期间观察抑制器状态。

`HIDRemoteMonitor` 剩下 2 项的可行路径已经查清并记录，供后续单独开项：`KeyboardEventSuppressor` 可以从 `HIDRemoteMonitor(settings:eventSuppressor:)` 注入，它是 `final` 不能被继承，但 `arm(button:edge:.down)` 会让 `heldEventCounts` 自增，而 `handle(type:event:)` 对已 arm 的 `.down` 返回 `true`。因此在 `onButtonPressed` 回调内部构造对应 `CGEvent` 并调用 `handle`，返回值即可判定「arm 是否已经先于回调发生」。本次没做，是因为它需要处理 `descriptor()` 的 keyboard 与 systemDefined 两条分支，且 HID 属于四项分支特有行为之一，不适合在会话末尾赶工。

## 验证

每条命令单独执行，输出重定向到文件后单独取退出码（不经 `tail`/`head` 管道，避免读到分页器状态）。

```text
$ swift build                                   → 退出码 0

$ swift test                                    → 退出码 0
  ✔ Test run with 336 tests in 29 suites passed after 15.430 seconds.

$ ./scripts/test.sh                              → 退出码 0
  RESULT passed=42 failed=0

$ ./scripts/check-repository-boundaries.sh       → 退出码 0
  REPOSITORY BOUNDARY PASS
```

### 过程中一次不属于本项的红灯

本项验证中途 `swift test` 曾经退出码 1、报 360 个 issue。**全部 360 个 issue 都在 `Tests/RemoteMicTests/InterfaceTypographyTests.swift`**，这是本会话另一个代理新建的未跟踪文件，配套它对 `RemoteMappingCanvas.swift` 的 `RemoteMappingLayout` 改动。

```text
$ grep -oE '[A-Za-z]+Tests\.swift' <当时的日志> | sort | uniq -c
 360 InterfaceTypographyTests.swift
```

本项涉及的两个源文件在负向对照前后逐字节相同，本项新增套件 11 项当时也全绿，因此该失败不属于本项；本项也无权修复它（`RemoteMappingCanvas.swift` 在本会话禁止编辑清单内）。该代理随后完成了自己那一项，最终 `swift test` 已如上表所示退出码 0。此处保留记录，是为了说明中途日志里那次红灯的归属。

### 本项测试项数归属

工作区有另一个代理并行新增测试，所以总数在本项进行中发生了变化。用 `--skip` 单独隔离本项贡献：

| | 项数 | 套数 |
| --- | --- | --- |
| 完整运行 | 336 | 29 |
| 仅跳过本项新增套件（`--skip XiaomiBluetoothBridgeSession`） | 325 | 28 |

差值 **+11 项 / +1 套**，与本项新增一致。会话开始时的基线是 **313 项 / 26 套**（本次实测确认），其余 **+12 项 / +2 套** 属于并行代理。没有删除或弱化任何既有测试；A 类里唯一被改写的 1 项换成了严格更强的行为断言，套数不减。

四项分支特有行为未被本次改动触及，对应测试套在上述范围内全绿：语音键触发键可配置、外接麦克风采集、右侧修饰键不粘滞、自定义快捷键左右保真。其中 HID 相关改动只发生在测试侧，`HIDRemoteMonitor.swift` 无生产差异。

未执行打包脚本：本次不涉及打包。

## 自动化与真机边界

**没有真机验收。本项完全没有在真实遥控器上跑过——本会话没有硬件访问权限。任何「已完成真机验收」的表述都是错的。**

**回放的事件不等于真实的 CoreBluetooth 回调。** 新增测试把字节序列直接喂给提取出来的处理核心，因此以下各项**均未被这些测试覆盖**：

1. 真实 RC003 固件是否真的发出这里回放的字节序列与这个顺序。测试夹具的依据是既有 `ATVVProtocolTests` 的能力应答和本仓库既有协议实现，不是新的真机抓包。
2. CoreBluetooth 是否按这个顺序、这个分片投递通知。真实分片边界由 ATT MTU 决定，测试里的 100/100/100/60 是人为选的、刻意不对齐帧边界的值。
3. `CBPeripheral` 身份校验（`isCurrent(_:)`）与 `centralGeneration` 一致性检查仍然完全没有覆盖：`CBPeripheral` 无法构造。桥在 `handleCharacteristicValue` 顶部仍保留自己的 `currentGeneration() == generation` 判断（电量与型号读取需要它），所以 ATVV 路径上的代号校验在生产里被检查两次，两次是同一个表达式；核心里那一次是可测的那一次，**测试证明的是这个判断的行为，而不是「桥一定先于核心拒绝」**。
4. 迟到回调在真机上究竟以什么时序到达，以及 A4 已接受的那项代价（复用同一 central 后，上一代迟到的 `didDisconnectPeripheral` 可能被新一代接受）在真机上的实际表现。
5. 音频是否真的进入虚拟设备并被第三方语音工具听见。核心只到 `.decoded(samples)`，`AudioOutput` 与设备绑定不在本项范围。
6. `MIC_EXTEND` 能否突破 RC003 约 60 秒限制。按 `AGENTS.md`，真机长录音通过前这只能称为 ATVV 租期假设；本项没有改变这一点。

因此本项的准确表述是：**把此前零覆盖的 ATVV 会话决策变成了可回放、可定向打断的自动化覆盖，并没有替代 RC003 真机基线验收。** `AGENTS.md` 门禁要求的「可注入事件回放」这一条现在有了；「真机基线」那一条仍然待办。

真机测试手册仍沿用 [`Testing/BluetoothAbsentRemoteReconnect.md`](../Testing/BluetoothAbsentRemoteReconnect.md) 与既有 RC003 相关手册；本项未新增用户可见行为，按 `AGENTS.md`「纯内部重构且没有用户可观察行为变化时可不新增」不新建手册。

## 已知未处理项

- **A 类源码文本断言仍有 305 项未转换**，其中 265 项指向本会话禁止编辑的文件，约 210 项集中在另一个代理正在改的 `SettingsPageRegressionTests.swift`。建议在那两个代理收工后单独开项，按上表逐文件推进。
- **`HIDRemoteMonitor` 的 arm/callback 先后仍是源码文本断言**，可行路径已在上文写清。
- **桥的 CoreBluetooth 适配层仍无覆盖**：扫描、候选筛选、连接、服务与特征发现、订阅状态、电量与型号解析。这些需要真机或一个 CoreBluetooth 伪实现，后者的机器量在本项被判定为不划算。
- 本项没有给 `Tests/SelfTest/main.swift`（`scripts/test.sh` 的 42 项）新增用例；核心已被该脚本编译，但尚未在那里被驱动。
