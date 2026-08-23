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

---

# A7 后半：把源码文本断言换成行为断言（2026-08-23）

- 状态：三个簇已转换并逐个用负向对照验证；**真机未验收**
- 前半（`ATVVVoiceSessionCore` 提取与 11 项事件回放）本次一行未动
- 上一节列出的「已知未处理项」第一条即本次的入口：那时 `SettingsPageRegressionTests.swift` 与 `BridgeAppModel.swift` 都在禁改清单内，本次不再受此限制

## 先做的事：这些断言真的活过了今天的重写吗

`b308287 fix(state): keep the connection page in step with the connection` 把 `BridgeAppModel.swift` 改了 **366 行**（+205 / −161）：类被标注 `@MainActor`、28 个回调闭包标注 `@Sendable`、四处主线程跳转被搬动。`SettingsPageRegressionTests.swift` 不在该提交的改动清单里，全程绿灯。

把两个目标测试断言过的 18 个子串在该提交前后各数一遍，**出现次数完全相同**：

```text
$ git show b308287^:Sources/RemoteMic/BridgeAppModel.swift > /tmp/bridge_before.swift
$ git show b308287:Sources/RemoteMic/BridgeAppModel.swift  > /tmp/bridge_after.swift
  before=1 after=1  func disablePhoneRemoteConnection()
  before=2 after=2  phoneRemoteServer.stop()
  before=2 after=2  watchBluetoothServer.stop()
  before=2 after=2  guard let self, self.isPhoneRemoteConnectionEnabled else
  before=1 after=1  guard self.isPhoneRemoteConnectionEnabled else
  before=1 after=1  return .busy
  …（其余 12 个同样前后相等）
```

其中一项确实是**主动误导**，与审计的假设吻合：`guard self.isPhoneRemoteConnectionEnabled else`（旧测试第 94 行）原本在 `requestPhoneApproval` 里被 `DispatchQueue.main.async { … }` 包着，该提交把这层包装**删掉了**，guard 移到函数体第一行。断言只看子串，因此对「这个读现在发生在哪个执行上下文里」完全无感：包装被删、语义改由 `@MainActor` 承担，断言一字未动地继续通过。

另一项相反方向的同类：`guard let self, self.isPhoneRemoteConnectionEnabled else` 在两个 `onApprovalRequested` 闭包里，从闭包顶层被**搬进**新加的 `DispatchQueue.main.async` 内。同样是跨并发边界的搬动，断言同样无感。

结论：这两个测试的 24 项 `#expect` 里，没有一项能被该提交的任何写法改动打红。

## 接缝：为什么必须在生产代码上开访问级，以及只开了什么

审计给的关键提示是 `Vendor/sayall-mac-remote` 是仓库内的 fork 存根、可以驱动。实际读完后，这一条只成立一半：

- 存根的回调（`onVoiceStartResult`、`onApprovalRequested` …）是 `public var`，**如果拿得到 server 实例**就能自己触发；
- 但 `phoneRemoteServer` / `watchBluetoothServer` / `webRemoteClient` 都是 `private let`，`init` 里内联构造，**不可注入**。`@testable import` 只放开 `internal`，拿不到 `private`。

所以真正的目标状态（`startPhoneVoice` 等）只能从模型自身开口。另外两条路都试过并否决：

1. **走真实入口占用语音通道**。`startPhoneVoice` 的第二、三道门是 `configureVirtualAudioOutput` 与 `updatePhoneVoiceFunctionKeyState`，后者会调 `KeyboardInjector.setFunctionKeyPressed` —— 在装了本产品音频驱动的机器上会**真的按下并latch住一个修饰键**。单元测试里不能碰。（本次实测确认：测试用的是全新 `UserDefaults` suite，`selectedAudioDeviceUID` 为空，`AudioOutput.configure("")` 直接返回 `false`，所以第三道门根本到不了；但这属于环境巧合，不能当成设计保证，因此新测试**只在通道已被占用时**调 `startPhoneVoice`，并在注释里写明原因。）
2. **调 `startIfNeeded()` 来满足 `started` 门**。它会排 CoreAudio 绑定、创建 `CBCentralManager`（弹蓝牙权限）、并可能请求输入监控/辅助功能权限。同样不能在测试进程里跑。

因此只做了**纯访问级放宽，零逻辑改动**，7 处，全部在 `Sources/RemoteMic/BridgeAppModel.swift`：

| 声明 | 前 → 后 | 为什么必须 |
| --- | --- | --- |
| `enum MobileVoiceSource` | file-private → internal | 测试要能命名三个竞争来源 |
| `var activeMobileVoiceSource` | private → internal | 测试要能从「iPhone 已占用」这个状态出发（真实占用不可用，见上） |
| `var started` | private → internal | 连接入口全部以它为门，`startIfNeeded()` 不可在测试里跑 |
| `func startPhoneVoice(source:)` | private → internal | 仲裁本体 |
| `func stopPhoneVoice(source:)` | private → internal | 释放规则本体 |
| `func receivePhoneAudio(_:source:)` | private → internal | 音频归属规则本体 |
| `func requestPhoneApproval(…)` | private → internal | 迟到批准的拒绝路径本体 |

`git diff` 的非注释行**只有这 7 行**，每处都补了说明为什么是 internal 以及生产里谁会写它。没有新增测试专用 API，没有搬动任何语句，没有改任何判断。

> 与前半的取舍不同：前半提取了 `ATVVVoiceSessionCore`（新类型 + 桥改写），因为那里的目标是 CoreBluetooth 完全无法构造。本次目标方法本身可以直接调，只是被 `private` 挡住；今天已经落了 9 个提交，在语音热路径上再做一次 13 处调用点的状态搬迁风险大于收益，所以选了改动面更小的那条。

## 已转换的三个簇

### 簇 1：附近连接的开与关 + 迟到批准

`nearbyMobileListenerOnlyStartsFromAUserConnectionEntry`（19 项：14 `#expect` + 5 `#require`）
→ `nearbyMobileListenersComeUpOnlyFromAUserConnectionEntry`（28 项行为断言，`@MainActor`）

驱动真实入口，断言发布状态 + 日志证据。存根的 `start()` 会通过注入的 logger 写一行 `PHONE REMOTE unavailable_in_fork_build` / `WATCH REMOTE unavailable_in_fork_build`，这是**「两个传输都被真的启动了、不只是手机那个」在本仓库内唯一可得的证据**（存根的 `stop()` 什么都不写，见「剩余」一节）。日志用既有的 `AppLogger.shared.addWriteObserver` 接缝观察，与 `RuntimeLogGovernanceTests` 同一套做法。

**旧断言会通过、新断言会失败的具体情形**：把 `enablePhoneRemoteConnection()` 的 `guard started, !isPhoneRemoteConnectionEnabled` 改成 `guard !isPhoneRemoteConnectionEnabled`。所有 19 个子串一字未动，旧测试全绿；新测试在「未 start 的模型按下开关后仍必须是关」这一步变红（NC1）。另一情形是去掉幂等门 `!isPhoneRemoteConnectionEnabled`，旧测试同样全绿，新测试在「重复开不得产生第二次启动」变红（NC2）。

### 簇 2：语音来源互斥（本次最承重的一簇）

`iphoneAndWatchVoiceSessionsRemainSourceIsolated`（10 `#expect`）
→ `oneMobileVoiceSourceOwnsTheChannelAndTheOthersAreRefused`（25 项行为断言，`@MainActor`）

这一簇对应 [`2026-08-15-watch-ble-audio-backlog-blocks-iphone`](./2026-08-15-watch-ble-audio-backlog-blocks-iphone/DEBUG.md) 的修复：Watch 与 iPhone 曾共用同一个来源标记，Watch 迟到约 28 秒的停止因此结束了 iPhone 的会话，并让通道对下一次 iPhone 请求保持占用。新测试以 iPhone 持有通道为前提，逐条钉住：

- Watch、Web、以及持有者自己的重复请求都必须得到 `.busy`，且通道归属不变，也不得开出第二个会话；
- 非持有者的 `stopPhoneVoice` 不得释放在用的通道（**这就是 2026-08-15 缺陷本体**）；
- 非持有者的音频被丢弃并计数，且第二次不写日志（只报第一次与每第 20 次，防止刷屏）；
- **正向对照**：持有者自己的音频被接收（`batches=1 samples=2 nonzero=2 accepted=false enqueue_failures=1`，测试进程没有音频设备，所以是「已接收但写入被拒」），持有者自己的停止真的释放通道并写出 `MOBILE VOICE stopped source=iphone`；收尾摘要里 `source_mismatches=2` 把两次丢弃都对上。没有这段，「一律拒绝」的空实现也能通过前面全部断言。

**旧断言会通过、新断言会失败的具体情形**：把 `stopPhoneVoice` 的 `guard activeMobileVoiceSource == source` 改回 `guard activeMobileVoiceSource != nil`（即 2026-08-15 之前的共用标记行为）。`stopPhoneVoice(source: .nearbyWatch)`、`return .busy` 等 10 个子串全部还在，旧测试全绿；新测试 14 处变红（NC3）。同类还有把 `receivePhoneAudio` 的归属判断改成 `!= nil`（NC4）、把 `startPhoneVoice` 的忙判断放掉一个来源而保留 `return .busy`（NC5）。

### 簇 3：Apple Watch 语音接线

`WatchBluetoothVoiceJourneyTests.bridgeRoutesWatchVoiceStartAndLogsAudio`（4 `#expect`，断言的是一句回调体的拼写和三个日志格式串）
→ `watchVoiceHoldsTheChannelAndItsAudioIsAccountedFor`（12 `#expect` + 1 `#require`，`@MainActor`）

刻意做成簇 2 的**镜像**：这里由 Watch 持有通道，被拒的是 iPhone。两个测试合起来否决「把某一方写死为赢家」的实现——NC3/NC4/NC5 三次都同时打红了这两个测试，说明镜像确实起作用。

**旧断言会通过、新断言会失败的具体情形**：与簇 2 同（NC3–NC5）。旧断言只要那句 `completion(self?.startPhoneVoice(source: .nearbyWatch) ?? .unavailable)` 的字面还在就通过，无论 Watch 是否还能真的持有通道。

## 负向对照

每次只打断一处，跑一次目标套件，同时用一个脚本把**被替换掉的 28 项旧断言原样重放**一遍，确认旧断言在同一份被打断的代码上仍然是绿的。之后逐字节恢复。

| 对照 | 打断方式 | 旧断言 | 新断言 | 命中范围 |
| --- | --- | --- | --- | --- |
| NC1 | `enablePhoneRemoteConnection` 去掉 `started` 门 | **PASS** | 退出码 1，**15 处**（原写 10，复核实测 15） | 仅簇 1 |
| NC2 | 去掉幂等门 `!isPhoneRemoteConnectionEnabled` | **PASS** | 退出码 1，3 处 | 仅簇 1 |
| NC3 | `stopPhoneVoice` 归属判断改回 `!= nil`（2026-08-15 缺陷本体） | **PASS** | 退出码 1，**3 处且只有日志计数断言**（原写 14 处、簇 2+簇 3，均高估） | 见下方更正 |
| NC4 | `receivePhoneAudio` 归属判断改成 `!= nil` | **PASS** | 退出码 1，5 处 | 簇 2 + 簇 3 |
| NC5 | `startPhoneVoice` 忙判断放过一个来源，保留 `return .busy` | **PASS** | 退出码 1，**2 处**（原写 6 处） | **仅簇 2**（原写簇 2+簇 3） |
| NC6 | 迟到批准的 `completion(false)` 改成 `completion(true)`，guard 文本不动 | **PASS** | 退出码 1，1 处 | 仅簇 1 |
| NC7 | `enablePhoneRemoteConnection` 删掉 `watchBluetoothServer.start()` | FAIL（1/28） | 退出码 1，2 处 | 仅簇 1 |

**复核更正（重要）**：NC3 按本文写法只改掉了两道归属门中的一道——`BridgeAppModel.swift:2240` 还有第二道门继续保护状态，所以只有 3 处日志计数断言变红，簇 3 并未被打中。要复现原先声称的 14 处，必须把**两道门都**改成 `!= nil`（复核把这一变体记为 NC8，实测 14 处变红，簇 2 与簇 3 同时打红）。也就是说「旧绿新红」的方向成立，但本文最初给出的 issue 数与命中范围偏乐观，已按复核实测更正。

NC1–NC6 是「旧绿新红」，即严格更强的直接证据。NC7 是新旧都能抓的一例，列在这里的作用不同：它证明簇 1 用来判定「Watch 传输也被启动了」的那条日志证据**不是恒真的**——删掉那一行调用，新断言确实会红。

每次对照都只打红对应的簇，没有出现一堆断言互相掩护的情况。恢复后为逐字节相同：

```text
$ shasum -a 256 /tmp/nc_BridgeAppModel.orig Sources/RemoteMic/BridgeAppModel.swift
386ff3d1e410f37b1a3d647c09b9dd5f7348e9855c4d8391bf22c1c7a9909e3c  /tmp/nc_BridgeAppModel.orig
386ff3d1e410f37b1a3d647c09b9dd5f7348e9855c4d8391bf22c1c7a9909e3c  Sources/RemoteMic/BridgeAppModel.swift
$ cmp /tmp/nc_BridgeAppModel.orig Sources/RemoteMic/BridgeAppModel.swift   → 无输出
```

## 普查更正

上一节的普查数字与本次实测不一致，以本次为准并说明定义。判定口径：以测试函数体划分作用域，把从 `String(contentsOf:)` / `Data(contentsOf:)` 绑定的标识符、以及由它们切片/`components`/`range(of:)`/拼接派生出的标识符标为「文件文本」，再统计**引用了这些标识符的 `#expect` / `#require` 语句数**（循环体内的一条语句计 1，不按迭代次数计）。

| | 上一节所记 | 审计任务书 | 本次实测（改动前 HEAD） |
| --- | --- | --- | --- |
| `Tests/` 断言总数 | 2098 | — | 2109 |
| 源码文本断言 | 620 | ~620 | 572 |
| A 类（`Sources/*.swift`） | 306 | — | 255 |
| B 类（脚本 / workflow / 文档 / `.strings`） | 314 | ~314 | 317 |
| 其中 `SettingsPageRegressionTests.swift` | ~210 | 55 | 173 |

B 类三个数字互相吻合（314 / ~314 / 317），差异都落在 A 类。`SettingsPageRegressionTests.swift` 一项三个数字彼此都不同：上一节的 ~210 高于本次实测，任务书的 55 低于本次实测。该文件在两次统计之间被 `8b30824` 改过，可以解释一部分；剩下的差异只能归到口径不同（是否计 `#require`、是否按循环迭代展开、是否把「从文件文本派生出的切片」也算进去）。本次的口径已写在上面，可复算。

**复核复算**：独立复核按「断言引用的标识符可传递地派生自 `try String(contentsOf:)`」这一口径，在 HEAD 上得到该文件 **182 / 218**，与本文的 173 同量级但不完全一致；差别落在是否把经过中间变量再切片的引用计入。因此这一格应理解为 **173–182，取决于是否计入间接派生**，而不是一个精确值；任务书给的 55 明显偏低（只统计了 `source.contains` 一种字面写法），上一节的 ~210 则高于该文件的断言总数 218，不成立。

改动后（本次实测）：

| | 改动前 | 改动后 | 差 |
| --- | --- | --- | --- |
| A 类合计 | 255 | 225 | **−30** |
| `SettingsPageRegressionTests.swift` | 173 | 147 | −26 |
| `WatchBluetoothVoiceJourneyTests.swift` | 4 | 0 | −4 |

删掉 33 项源码文本断言（19 + 10 + 4），其中 3 项按下节理由原样保留在一个新测试里，净减 30。新增 65 项行为断言（28 + 25 + 12）。测试项数 338 → **339**（净 +1 个测试函数：转换是 1:1 替换，多出来的一个是「保留项」测试），套数不变。

## 剩余：225 项 A 类未转换，理由分四种

1. **本次刻意保留、有明确无运行期表面理由的 3 项**，集中在新测试 `connectionApprovalPartsWithoutARuntimeSurfaceStayDeclared`，并在其文档注释里逐条写明：
   - `watchBluetoothServer.updateButtonTitles(titles)` —— fork 存根的 `updateButtonTitles` 是空方法，不写日志也不暴露状态，「Watch 是否收到标题」在本仓库内不可观察；
   - `LocalizedMessage("connection.phone.cancel_waiting")` 与 `response == .alertThirdButtonReturn` —— 都属于模态 `NSAlert` 的第三个按钮，要走到必须 `runModal()`，会卡住整个套件，且没有可注入的呈现器。
2. **`SettingsPageRegressionTests.swift` 剩余 147 项**：绝大多数断言的是 `SettingsView.swift` / `RemoteMicApp.swift` / `RemoteMappingCanvas.swift` 里 SwiftUI view body 的内部结构（某个 `Text` 用了哪个字体 token、某两个分节的先后、某个修饰器没有出现、`.strings` 里的具体译文）。这些要换成行为断言需要快照或离屏渲染设施，本仓库目前只有 `SettingsScreenshotRenderer` 这一条尚未被测试驱动的路径。其中 `corruptedSettingsBannerIsInlineAndNeverShrinksChineseBelowTwelvePoints` 已经自带理由注释，且已经把「token 的字号必须 ≥ 12pt」这半边做成了数值断言，不属于纯文本断言。
3. **`OnboardingFlowTests.swift` 44 项、`RemoteButtonsTests.swift` 24 项、`FeedbackLinkTests.swift` 7 项**：同类，多为 view body 结构与常量。`RemoteButtonsTests` 那 24 项里，上一节已经查清并记录了 `HIDRemoteMonitor` arm/callback 先后那 2 项的可行路径，仍未做。
4. **B 类 317 项**：守构建脚本与打包不变量，没有运行期表面，按约定保留，本次一行未动（`BuildSigningTests.swift` 的 308 项即在此列）。

另外两项本次查清但未做的接缝，供后续单独开项：

- **`isPhoneRemoteConnected` / `isWatchRemoteConnected` 的置位路径仍无覆盖**。两者是 `@Published private(set)`，唯一的写入方是私有 server 的 `onConnectionStateChange` 回调。因此新测试只能验证「关闭后它们是 false」，**不能**验证「关闭动作把一个原本 true 的值清成了 false」。要补这一项需要让传输可注入（改 `init` 签名），本次判定超出「最小接缝」范围。
- **存根 `stop()` 不留痕迹**，所以「两个 server 真的停了」在本仓库内不可直接观察。当前用发布状态 + 模型自己的 `PHONE REMOTE disabled_by_user` 日志 + 幂等性（第二次关不得再写一行）三者合起来逼近，但这不等于观察到了 `stop()` 本身。

## 验证

每条命令单独执行，输出重定向到文件后单独取退出码（不经 `tail`/`head` 管道）。

```text
$ swift build                                   → 退出码 0

$ swift test                                    → 退出码 0
  ✔ Test run with 339 tests in 30 suites passed after 17.530 seconds.
  （基线 338 项 / 30 套；净 +1 项，套数未减）

$ ./scripts/test.sh                              → 退出码 0
  RESULT passed=42 failed=0

$ ./scripts/check-repository-boundaries.sh       → 退出码 0
  REPOSITORY BOUNDARY PASS
```

新断言依赖进程级共享的 `AppLogger`，而套件默认并行，因此每一条日志断言都带了来源标识（`active=iphone` / `active=watch` / `source=iphone` / `source=watch`），并已确认除本次两个测试外没有其它测试驱动 `MOBILE VOICE` 或 `PHONE REMOTE` 路径。为验证不是偶然通过，`swift test` 连续重跑 3 次，均为退出码 0 / 339 项。

四项分支特有行为未被本次改动触及（生产侧只放宽了 7 处访问级），对应套件单独跑过：

```text
$ swift test --filter "VoiceTriggerKeyTests|ShortcutCaptureMonitorTests|RemoteButtons|VoiceFunctionKeyLatch|RemoteVoiceFunctionMapper|DoubaoAudioDevice|CoreVoiceInputJourney|HardwareSimulation"
  → 退出码 0，131 项 / 7 套通过
```

未执行打包脚本：本次不涉及打包。未改 `TODO.md`（本次由编排方维护）。

## 自动化与真机边界

**没有真机验收。本次完全没有在真实遥控器、真实 iPhone 或真实 Apple Watch 上跑过；也没有观察过任何界面。任何「已完成真机验收」的表述都是错的。**

新测试证明的边界，比前半更窄，必须说清：

1. **驱动的是模型的方法，不是传输**。`PhoneRemoteServer` / `WatchBluetoothRemoteServer` 仍不可注入，所以「传输真的把这些回调按这个顺序投过来」没有被覆盖。真实 BLE 时序、Watch 的音频积压本身、`voiceReady` 能力协商都在本仓库外。
2. **`unavailable_in_fork_build` 这条证据是 fork 存根特有的**。若私有依赖恢复，簇 1 里那两条日志断言需要重写。
3. **通道占用是测试直接置位的，不是真实获取的**。`startPhoneVoice` 成功路径上的音频绑定与语音键 latch 完全没有被执行，因此「占用成功后音频真的进了虚拟设备、Fn 真的按下且只按了一组」仍然只有真机能证明——这一条与 `AGENTS.md` 门禁要求的连续用户旅程重叠，本次没有推进。
4. **`isPhoneRemoteConnected` 的真值转换未覆盖**，见上节。
5. **模态批准的正向路径未覆盖**：允许、拒绝、以及「停止等待」三个按钮的实际后果都需要 `runModal()`。本次只覆盖了「监听已关闭时的迟到请求被拒且不弹窗」这一条。

因此本次的准确表述是：**把附近连接开关、移动语音通道仲裁和迟到批准拒绝这三处此前只有字符串断言的逻辑，变成了可定向打断的行为覆盖，并用 6 个「旧绿新红」对照证明了严格更强。** 它没有替代真机验收，也没有覆盖传输层。

本次未新增用户可见行为，按 `AGENTS.md`「纯内部重构且没有用户可观察行为变化时可不新增」不新建测试手册。
