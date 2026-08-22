# SwiftUI 观察的发布状态在主线程之外被写入

- 时间：2026-08-21
- 状态：已修复，自动化通过；真机遥控器、真实 iPhone / Apple Watch / 手机网页会话验收未完成
- 影响范围：`BridgeAppModel` 的全部 22 个 `@Published` 属性；直接受影响的是连接页显示的手机网页会话状态
- 功能点：`BridgeAppModel` 主线程隔离、手机 / Apple Watch / 网页传输回调入口、`XiaomiBluetoothBridgeDelegate` 边界
- 简单描述：`webRemoteClient.onStateChange` 把 SwiftUI 正在观察的 `webRemoteState` 直接在中继下发线程上赋值，没有任何主线程跳转；同一处传输回调里还有两次在传输线程上读取 `isPhoneRemoteConnectionEnabled`。后果是连接页可能显示错误的网页会话状态，或者在未定义行为下崩溃。

## 复现

这是审计项 A8。属于可从源码与隔离规则直接确认的线程缺陷；不需要现场条件，但**需要真实中继服务器才能观察到用户可见的错误界面**，这一部分本次没有做到（见「自动化与真机边界」）。

**可重复的确认方式（本次采用）**：`WebRemoteRelayClient.stop()` 会在调用方线程上同步触发 `onStateChange`。因此「回调是否在调用方线程上直接发布」这一点，可以用 `objectWillChange` 的到达时机来判定，不需要真实中继：

- 错误行为（修复前）：调用 `BridgeAppModel.disableWebRemoteConnection()` 期间就收到一次 `objectWillChange`，即 `webRemoteState` 是在传输回调的调用线程上被写入的。
- 正常行为边界：兄弟回调（`watchBluetoothServer.onAudio`、`onCommand`、`onButtonEvent` 等 20 处）都包着 `DispatchQueue.main.async`，本来就只在主线程发布。

第二种确认方式（针对隔离本身，与具体某个回调无关）：从 `Task.detached` 里调用一个会发布状态的模型方法，观察 `objectWillChange` 实际到达的线程。类型带主线程隔离时必然是主线程；去掉隔离后就是分离任务自己的线程。

**未能复现的部分**：真实中继服务器下发会话状态、真实 iPhone / Apple Watch 授权与语音回调、真实崩溃。本次一次都没有产生。

## 日志结论

**这条路径在日志里是看不见的。** `webRemoteState` 只驱动界面，赋值处不写日志；`disableWebRemoteConnection()` 只写

```text
WEB REMOTE disabled_by_user
```

它记录的是「用户关掉了网页连接」，与状态在哪个线程上发布无关。现场日志因此既不会显示线程错误，也不会显示界面显示的是哪一个状态——这正是仓库规则里「日志中的『收到事件』不等于用户功能已经真正可用」的一个实例：这里连「收到事件」都没有记录。

已有 Bug 记录反过来印证了传输回调不在主线程：[`2026-08-12-mac-phone-waiting-cannot-cancel.md`](./2026-08-12-mac-phone-waiting-cannot-cancel.md) 第 25 行写明「停止与下一条排队授权请求之间存在竞态，**授权回调**和**主线程弹窗创建前**都需要检查监听仍处于开启状态」——把「授权回调」与「主线程」分开表述，说明回调本身不在主线程。

## 根因

`Sources/RemoteMic/BridgeAppModel.swift` 的类声明没有 `@MainActor`，22 个 `@Published` 属性的线程正确性完全依靠在每个回调入口手写 `DispatchQueue.main` 跳转来维持——修复前共 31 处。这种纪律已经失效了两次：

1. `webRemoteClient.onStateChange` 一处跳转都没有，直接 `self?.webRemoteState = state`；
2. 手机与 Watch 的 `onApprovalRequested` 在跳转**之前**读取 `self.isPhoneRemoteConnectionEnabled`，即在传输线程上读一个 `@Published` 属性。

编译器当时不可能发现这两处，原因有两层，都需要说清楚：

- 类不带隔离时，根本没有可检查的规则；
- **即使加上 `@MainActor`，光靠它也发现不了这两处。** 供应商回调属性的类型是非 `@Sendable` 的函数类型（`((WebRemoteSessionState) -> Void)?` 等），写在 `@MainActor` 初始化器里的闭包字面量会**静默继承**主线程隔离。已用最小实验确认：这种写法在 `-strict-concurrency=complete` 下也不产生任何诊断。

因此只加 `@MainActor` 会得到一个「看起来被编译器保证了、实际最关键的边界仍然没有检查」的结果。

## 修复

四类改动，全部为最小改动。

**一、`Sources/RemoteMic/BridgeAppModel.swift` —— 类加 `@MainActor`**

22 个 `@Published` 属性的规则从人工约定变成类型系统属性。副作用是 `stop()`、`sendTestTone()`、`applyAudioSettings(reason:)` 等成为主线程隔离方法，两处既有测试相应加 `@MainActor`（未改断言）。

**二、`Sources/RemoteMic/XiaomiBluetoothBridge.swift` —— 委托协议标 `@MainActor`（选择前者，不用 `nonisolated` 方法）**

事实支持这一选择：桥自己把 `queue: .main` 交给 `CBCentralManager`（`XiaomiBluetoothBridge.swift` 的 `start()`），所有 CoreBluetooth 回调都落在主队列；桥自己的重连与超时用 `DispatchQueue.main.asyncAfter`。协议只有一个实现方（`BridgeAppModel`）。

标记协议会连带要求调用方一致，因此 `XiaomiBluetoothBridge` 与 `XiaomiPeripheralDelegateProxy` 同样标 `@MainActor`；两个 CoreBluetooth `@objc` 协议的一致性用 `@preconcurrency` 标注（`CBCentralManagerDelegate`、`CBPeripheralDelegate` 本身没有并发注解，而隔离由 `queue: .main` 在构造时保证）。这样做之后新增警告数为 0。

替代方案是把 `BridgeAppModel` 的 7 个委托方法标 `nonisolated` 再各自跳转。没有采用：这会让承载音频解码的 `bluetoothBridge(_:didDecode:)` 每批样本多一次队列往返，而且把一个本来成立的保证重新变成人工约定。

**三、传输回调闭包显式标 `@Sendable` —— 让编译器接管那 20 处跳转**

手机 / Watch / 网页共 29 处回调赋值中的 27 处，加上 `audioOutput.onConfigurationChange`，共 28 个闭包字面量前加 `@Sendable`。这一步关闭了上面说的隔离继承：闭包不再是主线程隔离的，于是**跳转成为编译器要求**。删掉任意一处跳转都是编译错误，而不是像修复前那样静默通过。

余下 2 处例外：`phoneRemoteServer.isIdentityTrusted` 与 `watchBluetoothServer.isIdentityTrusted` 必须在调用方栈帧里同步返回 `Bool`，无法跳转。它们在传输线程上读 `settings.trustedPhoneIdentityTrustDates`——一个 `@Published private(set) var [String: Date]`，而主线程会在 `requestPhoneApproval` 里通过 `trustPhoneIdentity` 写同一个字典，构成未同步的 Dictionary 读写竞态。本次刻意未改（见「附带发现」），并在代码里注明原因，避免后来者误以为漏标。

**四、`webRemoteState` 补上缺失的跳转，并把授权路径的跳转移到边界**

- `webRemoteClient.onStateChange` 加 `DispatchQueue.main.async`：这就是本次缺陷本体的修复。
- 三个 `onApprovalCancelled` 与三个 `onApprovalRequested` 在回调处跳转，`requestPhoneApproval` / `cancelPhoneApproval` / `requestWebApproval` / `cancelWebApproval` 内部原有的 4 处跳转随之删除。目的是把每个传输事件的跳转次数固定为一次，并让 `isPhoneRemoteConnectionEnabled` 的读取落在主线程。

**跳转数量的实际变化，需要如实说明**：静态跳转点从 31 处变为 34 处（删 4、增 7）。**没有出现「加了 `@MainActor` 就能删掉大批跳转」的情况**，原因是那 31 处并不是同一个不变量的重复实现。逐一分类（修复前 20 + 3 + 4 + 4 = 31，修复后 27 + 3 + 4 = 34）：

- **传输边界，修复前 20 处、修复后 27 处**：手机 / Watch / 网页各 9 处。供应商包 `Vendor/sayall-mac-remote` 在本 fork 中是桩实现（`SayAllMacRemoteCore.swift` 顶部注明），**不承诺任何线程**；真实私有包的下发线程无法从本仓库观察，而上面引用的 2026-08-12 记录表明回调不在主线程。删掉它们就是制造本次要修的同一种竞态。
- **`asyncAfter` 延时，3 处不变**：`recoverHIDAfterCompletedUpdate`（更新后恢复 HID）、`scheduleAudioRecovery` 内部的 1 秒去抖、`scheduleHIDMappingRetryIfNeeded`。作用是「等一段时间」，不是「换线程」。（长录音与手机手势的超时用的是 `DispatchSource.makeTimerSource(queue: .main)`，不在这个计数里。）
- **真实后台边界，4 处不变**：`refreshAudioDevices` 与 `startAudioSubsystem` 的 `audioPreparationQueue`（CoreAudio 设备枚举与配置刻意不在主线程做）、`sendTestTone` 里 AVAudioPlayerNode 的缓冲完成回调、`scheduleAudioRecovery` 本身（`AVAudioEngineConfigurationChange` 以 `queue: nil` 观察 + CoreAudio 属性监听块跑在 `audioHardwareListenerQueue`）。
- **审批方法内部的 4 处，已删除**：改为在回调边界跳转（见上一节）。

按「每个事件实际执行的跳转次数」看，结果是变好的：`disablePhoneRemoteConnection()`（本来就在主线程）经 `cancelPhoneApproval` 的那一次**多余**跳转被删除；传输事件仍是一次；只有原本 0 次的 `onStateChange` 变成必要的一次。

**五、`nonisolated` 标注 —— 让刻意的后台访问显式且受检**

- `audioOutput`（`nonisolated let`）：`VirtualAudioOutput` 被刻意从多个线程驱动——`configure`/`stop` 在 `audioPreparationQueue`、排空账目在 AVAudioEngine 自己的缓冲完成线程上经内部锁处理。只有**引用**是 `nonisolated`，由它派生的发布状态仍在主线程赋值。
- `scheduleAudioRecovery(reason:details:)`：两个入口都在主线程之外，方法内已有跳转；标 `nonisolated` 之后，编译器会检查跳转之外不触碰发布状态。
- `audioDevicesDiagnostic(_:)`、`audioHardwarePropertyNames(count:addresses:)`、`audioHardwarePropertyName(_:)`、`shouldRecoverHIDAfterCompletedUpdate(...)`：纯函数，与类内既有的三个 `nonisolated static func` 同一模式。

**完成回调的时序核对**（`@MainActor` 会不会让答案晚于调用方栈帧）：`onCommand`、`onButtonEvent`、`onVoiceStartResult`、`onVoiceStart`、`onApprovalRequested` 都通过 `completion` 回传结果。修复前这 5 类回调**已经**在 `DispatchQueue.main.async` 之后才调用 `completion`（`onApprovalRequested` 更是要先跑完 `alert.runModal()` 这个嵌套事件循环），所以「答案异步返回」是既有契约，本次没有改变任何一处的同步/异步性质。`isIdentityTrusted` 是唯一要求同步返回的回调，因此它没有被改成 `@Sendable`，也没有加跳转。

未改动：语音触发键判定、`VoiceTriggerKey`、`KeyboardInjector`、修饰键释放顺序、外接麦克风采集开关、HID 路径、`VirtualAudioReleaseGate` 与 `releaseVirtualAudioOutputIfUnused` 的判定、日志文本、审批弹窗文案与按钮顺序、`AppSettings`、Package 语言模式（仍为 `swiftLanguageModes: [.v5]`）。

## 验证

命令各自单独执行，退出码单独一行捕获（未经 `tail`/`head` 管道，避免读到分页器的状态）。

```text
$ swift build > /tmp/A8_swift_build.log 2>&1
EXIT_CODE=0
Build complete! (8.48s)

$ swift test > /tmp/A8_swift_test.log 2>&1
EXIT_CODE=0
✔ Test run with 338 tests in 30 suites passed after 21.238 seconds.

$ ./scripts/test.sh > /tmp/A8_scripts_test.log 2>&1
EXIT_CODE=0
RESULT passed=42 failed=0

$ ./scripts/check-repository-boundaries.sh > /tmp/A8_boundaries.log 2>&1
EXIT_CODE=0
REPOSITORY BOUNDARY PASS

$ ./scripts/build-app.sh > /tmp/A8_build_app.log 2>&1
EXIT_CODE=0
RELEASE VARIANT: apple-silicon
SIGNING IDENTITY: -
```

`scripts/build-app.sh` 做的是 release 构建加 ad-hoc 签名（`SIGNING_IDENTITY: -`），跑它的理由是「隔离改动可能在 SwiftPM 下通过而在真实 App 构建里失败」。它**不能**替代 Developer ID 签名、公证或安装包验收。

计数口径：基线 336 项 / 29 个 suite，本次新增固定 2 项 / 1 个 suite，最终 338 项 / 30 个 suite。测试数量未下降，未删改或弱化任何既有测试；`scripts/test.sh` 的 `check(...)` 数量保持 42 项（本次未触碰 `Tests/SelfTest/main.swift`，该脚本编译的源文件清单也不含 `BridgeAppModel.swift`）。

编译警告：`swift build` 全量重编后的警告与修复前逐条一致，均为既有的 6 条（`OnboardingView.swift` 3 条、`SettingsView.swift` 3 条 `onChange` 弃用与非 Sendable 函数转换）。本次新增警告 0 条。

新增测试（`Tests/RemoteMicTests/BridgeAppModelIsolationTests.swift`，“Bridge model main-actor isolation” suite；两项都是行为断言，不通过 grep 源码文本）：

1. `webSessionStateFromTheTransportIsPublishedOnALaterMainActorTurn` —— 利用 `WebRemoteRelayClient.stop()` 同步触发 `onStateChange` 这一点，断言 `disableWebRemoteConnection()` **调用期间**不得发生任何 `objectWillChange`，随后在主队列 FIFO 的下一块里必须恰好发生一次、且落在主线程、且 `webRemoteState == .disabled`。
2. `aPublishedMutationStartedOffTheMainThreadStillExecutesThere` —— 从 `Task.detached` 调用 `selectDoubaoAudioDevice()`（模型未启动时必走「找不到设备」分支，会发布 `doubaoAudioStatus`，不触碰 CoreAudio），断言 `objectWillChange` 记录到的线程是主线程。

反向验证（确认断言真的依赖本次修复，而不是恒真）：

- 把 `webRemoteClient.onStateChange` 逐字还原成修复前的 `{ [weak self] state in self?.webRemoteState = state }`（同时去掉 `@Sendable`，否则这是编译错误、测试没有机会运行）：

```text
$ swift test --filter BridgeAppModelIsolationTests > /tmp/a8_neg1b.log 2>&1
EXIT_CODE=1
✘ Test webSessionStateFromTheTransportIsPublishedOnALaterMainActorTurn() recorded an issue at
  BridgeAppModelIsolationTests.swift:83:9: Expectation failed: (recorder.mainThreadFlags → [true]).isEmpty → false
✔ Test aPublishedMutationStartedOffTheMainThreadStillExecutesThere() passed
✘ Test run with 2 tests in 1 suite failed after 0.009 seconds with 1 issue.
```

`mainThreadFlags` 在 `disableWebRemoteConnection()` 返回时就已经非空，这就是缺陷本体：发布发生在调用之内，也就是传输回调的调用线程上。此处记录到的值是 `true`，只是因为测试自己在主线程调用；真实中继下发时会是中继自己的线程。

- 去掉隔离本身。这里有一个必须记录的发现：**只删类上的 `@MainActor` 不会改变任何行为**，因为 `BridgeAppModel` 声明中就一致于 `@MainActor` 的 `XiaomiBluetoothBridgeDelegate`，隔离会被推断出来（已实测：只删类注解时两项测试仍全绿，退出码 0）。删掉协议注解则因 `XiaomiBluetoothBridge` 仍是 `@MainActor` 而变成编译错误。因此真正的反向验证是把三处注解一起去掉（等价于把 `XiaomiBluetoothBridge.swift` 还原到 HEAD 并删掉类注解）：

```text
$ swift test --filter BridgeAppModelIsolationTests > /tmp/a8_neg2d.log 2>&1
EXIT_CODE=1
✔ Test webSessionStateFromTheTransportIsPublishedOnALaterMainActorTurn() passed
✘ Test aPublishedMutationStartedOffTheMainThreadStillExecutesThere() recorded an issue at
  BridgeAppModelIsolationTests.swift:119:9: Expectation failed: (recorder.mainThreadFlags → [false]) == [true]
✘ Test run with 2 tests in 1 suite failed
```

`[false]` 就是「SwiftUI 观察的属性在分离任务的线程上被写入」。

两次反向验证后源文件均已逐字还原，还原前后完整 `git diff` 字节一致，`sha256 = d304975a7e7bac2e908decb1c1f6ba7cc011d04221c27e9654be1b0cbb5a1c5e`，并重新执行了上述全部命令。

（第一次尝试用「`@MainActor` 类隐式满足 `Sendable`」做类型级断言，实测在 Swift 5 语言模式下删掉隔离后**不产生任何诊断**，该断言恒真、无效，已替换为上面第 2 项的运行时线程观察。此处记录下来，避免以后有人再写同一种无效断言。）

fork 专有行为回归（自动化层面）：四项 fork 专有行为对应的既有测试全部通过——可配置语音触发键与外接麦克风采集（`VoiceTriggerKeyTests` 的 `setFunctionKeyPressedInjectsTheSelectedTriggerKeyCodeAndFlags`、`modifierTriggersUseHoldInjectionAndNeutralizeHardwareKey`、`fnTapInjectionAppliesOnlyToFnWhileStreamingRemoteMic`、`fnKeepsHardwareRemapUnlessTypeless`、`voiceKeyUsesRemoteMicrophoneDefaultsOnAndRoundTrips`），右侧修饰键不粘滞与自定义快捷键左右保真（`RemoteButtonsTests` 的 `sideSpecificShortcutHoldsRealModifierAndReleasesInReverse`）。同一工作区当日其他修复对应的测试也全绿：`RuntimeLogGovernanceTests`、`BluetoothLifecycleTests`、`VoiceFnTapSessionControllerTests`、`VirtualAudioConnectionLifecycleTests`、`ConfigurationImportValidationTests`、`InterfaceTypographyTests`、`XiaomiBluetoothBridgeSessionTests`。上述均为自动化断言，**不等于这四项 fork 行为已完成真机验收**。

## 严格并发检查（仅诊断，本次刻意未修）

按要求以诊断方式跑了一次严格检查，未切换 Package 语言模式（仍为 `swiftLanguageModes: [.v5]`）：

```text
$ swift build --scratch-path /tmp/a8-strict-scratch -Xswiftc -strict-concurrency=complete
EXIT_CODE=0
警告行数 746、去重后 93 条（其中 BridgeAppModel.swift 61 条）
```

同一命令在本次改动**之前**的基线是 1084 行、去重后 136 条（其中 `BridgeAppModel.swift` 104 条），其余文件逐一相同。也就是说本次改动把 `BridgeAppModel.swift` 的严格并发发现由 104 条减到 61 条，没有在任何其他文件引入新发现。复核指出本文最初写的 542 → 373 是按行计数（每条诊断占两行），已按去重条数更正。

剩余部分若要转向 Swift 6 语言模式，需要额外处理三类（本次**未**修）：

1. `reference to captured var 'self' in concurrently-executing code`（108 条）——`[weak self]` 之后在嵌套的 `DispatchQueue.main.async` 里用 `self?.`，被视为在并发代码中引用捕获的可变量；需要改成先 `guard let self` 再进入嵌套闭包。
2. `sending 'completion' risks causing data races` / `capture of 'completion' with non-Sendable type`（96 条）——供应商回调的 `completion` 参数是非 `@Sendable` 函数类型；根治需要 `Vendor/sayall-mac-remote` 把这些参数标成 `@Sendable`，属于跨仓库改动。
3. `non-Sendable type 'VirtualAudioOutput' … cannot exit nonisolated context` 与 `'nonisolated' can not be applied to variable with non-'Sendable' type`（43 条）——`VirtualAudioOutput` 需要成为 `Sendable`；它已有内部 `NSLock`，最可能的落点是 `@unchecked Sendable`，但那是一个独立判断，不应夹在本次修复里。

`AudioOutput.swift`（52 条）、`KeyboardInjector.swift`（17 条）、`AppLogger.shared` 等全局可变状态（9 条）在改动前后完全一致，与本次修复无关。

## 自动化与真机边界

**本次修复完全没有在真实硬件、真实中继服务器或真实界面上验证，不能视为已完成真机验收。代理无法接入真实小米蓝牙语音遥控器、真实 iPhone、真实 Apple Watch 或真实手机网页中继，也无法观察屏幕上的界面。**

自动化只覆盖：

- `BridgeAppModel` 的主线程隔离与 `objectWillChange` 到达线程；
- fork 内的供应商桩实现（`WebRemoteRelayClient.stop()` 同步触发 `onStateChange`）。**真实私有传输包在本 fork 中不存在，它实际的下发线程一次都没有被执行过**；本次「传输回调不在主线程」的判断依据是 2026-08-12 的既有记录与修复前 20 处已存在的跳转，属于文档与代码证据，不是实测。
- 编译期隔离检查。这里必须区分清楚：`@Sendable` 让 20 处跳转成为编译器要求，这是**编译期**保证；而「跳转之后确实落在主线程」由 `DispatchQueue.main.async` 的语义保证，本次没有在真实传输线程上实测过。

**以下均未验证**：

- 真实中继下发会话状态时连接页显示是否正确（本缺陷的用户可见后果）；
- 真实 iPhone / Apple Watch 授权弹窗：把跳转移到回调边界之后，「停止等待」与迟到授权请求的实际表现；
- 真实按键、语音开始/停止、音频批次经真实传输线程进入模型的时序，尤其是 `onAudio` 在高频下的顺序；
- `MainActor.assumeIsolated` 用在 `NSApplication.willTerminateNotification` 观察块（该块以 `queue: .main` 注册）里，真实退出流程中是否确实一次都不触发断言；本次选择 `assumeIsolated` 而不是异步跳转，正是因为异步跳转会让进程在清理完成前退出——这一点在真实退出流程上未实测；
- CoreBluetooth 委托边界改成 `@MainActor` 之后，真实遥控器连接、电量、按键与 `STREAM_START → AUDIO → STREAM_STOP` 的完整语音链路；
- 四项 fork 专有行为（可配置语音触发键、外接麦克风采集、右侧修饰键不粘滞、自定义快捷键左右保真）在真机上的表现。

上述项目必须在真实遥控器、真实手机与真实中继上完成一次完整流程，并收集 `~/Library/Logs/RemoteMic/runtime.log` 后才能确认。当前只能确认自动化边界通过。

## 附带发现（本次未修复）

1. **`isIdentityTrusted` 在传输线程上与主线程竞争同一个 `@Published` 字典。** `phoneRemoteServer.isIdentityTrusted` 与 `watchBluetoothServer.isIdentityTrusted` 必须在调用方栈帧里同步返回 `Bool`，因此无法用跳转修复；把它改对需要让 `AppSettings` 的信任查询本身可跨线程安全读取，或者让供应商协议改成异步回答。属于独立改动，本次刻意保持原样并在代码注释里标明。
2. **`endSessionAfterDraining` 的完成回调线程未受隔离约束。** `stopPhoneVoice` 与 `releaseVirtualAudioOutputIfUnused` 的排空回调在正常路径上都由主线程调用（`AudioOutput.swift` 的 `DispatchQueue.main.async` / `asyncAfter` / 同步返回），但打断路径上 `audioOutput.stop()` 可能跑在 `audioPreparationQueue`，此时回调也在那条队列上执行并写 `isAudioOutputReady` / `testToneStatus` / `activeMobileVoiceSource`。由于 `audioOutput` 标了 `nonisolated`，编译器不检查这一段。修复前后行为一致，且在此加跳转会改变排空时序（与 2026-08-21 排空卡死修复相邻），因此按最小修复范围**刻意未改动**，作为独立项记录。
