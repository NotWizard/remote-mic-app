# 排空尾音期间音频重配置导致语音会话永久卡死

- 时间：2026-08-21
- 状态：已修复，自动化通过；真机与真实音频设备切换验收未完成
- 影响范围：所有使用 Fn 轻触（Typeless）语音路径的用户；手机语音停止与虚拟音频释放两条路径同类风险
- 功能点：`VirtualAudioOutput` 的尾音排空回调、`VoiceFnTapSessionController` 的 `.draining` 阶段
- 简单描述：语音键松开后约 0.75 秒的排空窗口内如果发生音频重配置（设备变化、引擎重启、输出释放），排空完成回调会被静默丢弃，会话永久停在 `.draining`，之后每一次按语音键都被拒绝，只能退出并重启 App 才能恢复。

## 复现

这是审计项 A5。属于可从源码与控制流直接确认的时序缺陷，用最小实验即可复现，不需要现场条件。

**可重复的确认方式（本次采用）**：在 `VirtualAudioOutput` 上挂起一个待播缓冲，调用 `endSessionAfterDraining`，再触发打断路径（`endSession()` → `flushPlayer()`，或 `stop()`），断言完成回调被调用的次数。

- 错误行为（修复前）：回调次数为 `0`，且此后再也不会变成 `1`。既没有走排空回调，也没有走 `endSessionAfterDraining` 自己的兜底定时器。
- 正常行为边界：排空在窗口内自然完成时（`scheduledVoiceBufferDidFinish` 计数归零）回调正常触发一次；不发生音频重配置时整条链路一直正常。

**触发条件（真实场景）**：`STREAM_STOP` 之后、尾音尚未播完的约 0.75 秒内发生以下任一情况：

1. 系统音频设备变化或 `AVAudioEngine` 配置变化，`BridgeAppModel` 走 `scheduleAudioRecovery` → `configure(deviceUID:)` → `stop()`；
2. `flushPlayer()` 重启播放节点失败，自身调用 `stop()` 并触发 `onConfigurationChange?()`（`AudioOutput.swift` 中 `player_restart_exception` 分支）；
3. 另一路蓝牙会话结束走 `endVoiceSessionIfNeeded(flushAudio: true)` → `endSession()`；
4. 虚拟音频释放与手机语音停止两条排空请求重叠，后者覆盖前者的回调槽位。

**未能复现的部分**：真实设备热插拔、真实系统默认输入切换、真实 CoreAudio 引擎配置变化通知，本次一次都没有实际产生（见「自动化与真机边界」）。

## 日志结论

关键点是：**这条路径的日志看起来是被处理过的，实际没有**。`flushPlayer()` 与 `stop()` 都会写

```text
AUDIO PLAYBACK interrupted trace=<id> model=<model>
```

该行只来自 `pendingDrainLogContexts`（由 `logWhenPendingVoiceAudioDrains` 登记），与排空完成回调是两套独立状态。因此现场日志会显示「打断已记录」，而等待方从未收到通知——正是仓库规则里「日志中的『收到事件』『解码成功』『入队成功』不等于用户功能已经真正可用」这一条的具体实例。

对应地，卡死后的会话不会再出现 `AUDIO PLAYBACK drained …`，也不会出现下一次会话的 Fn 配对，日志表现为「语音键按下之后什么都没发生」。

## 根因

`Sources/RemoteMic/AudioOutput.swift` 中，排空完成回调只有一个槽位 `drainCompletion`，配合 `drainGeneration` 做时序校验。

- `endSessionAfterDraining(maximumDelay:completion:)`：`drainGeneration &+= 1`，把回调存入 `drainCompletion`，并用 `DispatchQueue.main.asyncAfter` 按该 generation 挂一个兜底。
- `finishDrainIfNeeded(generation:completion:)`：仅当 `generation == drainGeneration && drainCompletion != nil` 才继续。
- 修复前的 `flushPlayer()` 与 `stop()`：同时执行 `drainCompletion = nil` **和** `drainGeneration &+= 1`，但从不调用该回调。

两个动作叠加造成双重丢失：回调引用被丢弃，同一时刻 generation 递增又让兜底闭包的判定失效。于是**没有任何路径**会再调用它。

等待方是 `Sources/RemoteMic/VoiceFnTapSessionController.swift`：

- `beginDrain` 把 `phase` 置为 `.draining(sessionGeneration)`；
- 只有排空回调经 `beginStopTap` 才能离开 `.draining`（`guard phase == .draining(sessionGeneration), generation == sessionGeneration`）；
- `startVoice` / `receive` / `stopVoice` 在 `.draining` 下都不开新会话。

因此会话永久停在 `.draining`，收尾 Fn 轻触也不会发出，目标 App（Typeless / 豆包输入法）那一侧的听写还处于打开状态，用户只能退出重启 App。

附带的同类丢失：`endSessionAfterDraining` 在槽位已被占用时直接覆盖，先到的等待方（手机语音停止或虚拟音频释放）同样永久失联。

## 修复

两处最小改动，加一处测试脚手架的假调度器适配。

**`Sources/RemoteMic/AudioOutput.swift`——把排空回调改成「一次且必达」**

- 新增私有 `takeInterruptedDrainCompletion()`，把 `flushPlayer()` 与 `stop()` 原本逐字重复的那段清理合并为一处：在 `playbackLock` 内清零计数、清空日志上下文、**取出**回调并置 `nil`、递增 generation；解锁后照原样写 `AUDIO PLAYBACK interrupted`，最后把回调返回给调用方。
- `flushPlayer()` 与 `stop()` 各自在**函数开头**取出回调，用 `defer` 在**函数结尾**调用。打断也是一种结果，等待方需要被告知排空已结束，而不是继续等待。
- `endSessionAfterDraining` 在写入新回调前把槽位原有占用者取出，并在新排空完成布置后用 `defer` 调用一次。

**保持一个槽位，不改成等待队列**：`drainGeneration` 保证同一时刻只有最新一次排空有意义，而现在每条清空槽位的路径都必须先把占用者取走并调用，槽位不可能被静默覆盖。队列只有在需要同时**追踪**两次排空时才有价值，这里不需要。

**锁纪律与重入**（本次改动的主要风险，逐条排除）：

- 回调一律在 `playbackLock` 解锁之后调用，与既有 `scheduledVoiceBufferDidFinish` 一致；`playbackLock` 是 `NSLock`（不可重入），若在持锁期间调用回调而回调回头调用 `stop()` 就会死锁——`defer` 的位置排除了这一点。
- 不会重复调用：回调引用只存在于 `drainCompletion` 一个槽位，所有读取它的位置都在**同一次持锁**内把它置 `nil`，因此最多只有一个调用方能拿到。`finishDrainIfNeeded` 用的是闭包捕获的副本，但其前置条件包含 `drainCompletion != nil` 且 generation 相符，取到后同样置 `nil` 并递增 generation。
- `flushPlayer` → 重启失败 → `stop()` 的嵌套路径不会重复调用：`flushPlayer` 在**最开头**就取走了回调，嵌套的 `stop()` 只会取到 `nil`。
- 回调回头调用 `stop()`（虚拟音频释放路径的既有写法就是这样）不会递归：此时槽位已是 `nil`，第二层 `stop()` 的 `defer` 拿到 `nil`，递归深度上限为 2。
- `defer` 而非「先调用回调再操作播放节点」是刻意选择：若先调用回调，回调里的 `stop()` 会把 `self.player` 置 `nil`，而 `flushPlayer` 局部已经强引用了旧节点，随后对已摘下的节点 `play()` 必然失败，凭空触发一次 `player_restart_exception` 与音频恢复。
- 正常路径不会多写日志：`scheduledVoiceBufferDidFinish` 归零后再走 `flushPlayer()`，此时 `pendingVoiceBufferCount == 0`，`interruptedContexts` 为空，不会把「已排空」误报成「被打断」。

**`Sources/RemoteMic/VoiceFnTapSessionController.swift`——保留控制器侧超时兜底**

新增 `drainTimeout = 2` 秒。`beginDrain` 在 `drainAudio` **之前**挂一个 `schedule(drainTimeout)` 任务，指向已有的 `beginStopTap(generation:)`。

即使回调已保证必达，这一层仍然必要：`endSessionAfterDraining` 的兜底闭包以 `[weak self]` 捕获 `VirtualAudioOutput`，输出对象被释放后该闭包静默失效，任何回调都不会到达。控制器侧的截止时间是针对这种情况的兜底。

- generation 受保：复用 `beginStopTap` 已有的 `guard phase == .draining(sessionGeneration), generation == sessionGeneration`，迟到触发无法影响后续健康会话。
- 正常路径会取消：任务进入 `scheduledTasks`，`resetSessionState()` 的 `cancelScheduledTasks()` 在每条正常退出路径上都会取消它；挂载点在 `drainAudio` 之前，因此同步返回的排空也能被正常取消。
- 到期后的状态可接受下一次按键：走 `beginStopTap` → `.stopping` → 完成收尾 Fn 轻触 → `finishSession()` → `.idle`，与正常收尾完全同路，且仍会重放 `pendingVoice`。
- 2 秒明显高于音频侧 0.75 秒的兜底，健康会话永远由 `drainAudio` 先离开 `.draining`。

**`Tests/SelfTest/main.swift`——假调度器适配（不改断言）**

该自测的假调度器把操作按下标压入数组，取消动作是空实现，因此被取消的任务仍留在队列里。`.draining` 多挂一个截止任务后，原本「取一个操作」不足以取到收尾按键释放。改为把队列里排队的操作全部执行（截止任务因阶段守卫为空操作）。`check(...)` 的条件与数量一字未改，仍为 42 项。

未改动：`playbackLock` 的加解锁位置与范围、`AUDIO PLAYBACK interrupted` / `drained` 的文字与条件、`drainGeneration` 递增时机、`finishDrainIfNeeded`、`scheduledVoiceBufferDidFinish`、`.draining` 拒绝新语音的既有语义、语音触发键判定、按键注入、外接麦克风采集。

`enqueue(samples:)` 里的三行计数自增抽成具名方法 `registerPendingVoiceBuffer()`（生产路径调用点不变），使排空账目可以在没有真实输出设备的情况下被驱动。

## 验证

三条命令各自单独执行，退出码单独一行捕获（未经 `tail`/`head` 管道，避免读到分页器的状态）。

```text
$ swift test > /tmp/a5-final-swift-test.log 2>&1
EXIT_CODE=0
✔ Test run with 312 tests in 26 suites passed after 17.606 seconds.

$ ./scripts/test.sh > /tmp/a5-final-selftest.log 2>&1
EXIT_CODE=0
RESULT passed=42 failed=0

$ ./scripts/check-repository-boundaries.sh > /tmp/a5-final-boundaries.log 2>&1
EXIT_CODE=0
REPOSITORY BOUNDARY PASS
```

需要说明计数口径。基线为 283 项测试 / 24 个 suite，本次修复贡献固定为 6 项、不新增 suite。

- 本次改动完成后、其他并行改动进入工作区之前的隔离测量为 **289 项 / 24 个 suite，退出码 0**（283 + 6）。
- 最终一次运行显示 312 项 / 26 个 suite，多出的 23 项与 2 个 suite 来自同一工作区中另一位代理并行进行、与本次修复无关的配置导入改动（`Sources/RemoteMic/AppSettings.swift`、`Sources/RemoteMic/SettingsView.swift`、`Resources/*.lproj/Localizable.strings`、`Tests/RemoteMicTests/ConfigurationImportValidationTests.swift`）。这些文件不属于本次修复，未被本次改动触碰。
- 本次新增的 6 项在最终运行中全部确认通过（`reconfiguringTheOutputMidDrainStillReportsTheDrainExactlyOnce`、`tearingTheEngineDownMidDrainStillReportsTheDrainExactlyOnce`、`aDrainCompletionThatTearsTheOutputDownAgainReportsOnlyOnce`、`aSecondDrainRequestDoesNotStrandTheFirstWaiter`、`aDrainAnswerThatNeverArrivesStillClosesTheSessionAndAcceptsTheNextPress`、`aTimelyDrainCancelsTheDeadlineBeforeItCanCutTheNextSession`）。

测试数量未下降，未删改或弱化任何既有测试。`./scripts/test.sh` 的 `check(...)` 数量保持 42 项。

新增测试（均为行为断言，不通过 grep 源码文本）：

`Tests/RemoteMicTests/VirtualAudioConnectionLifecycleTests.swift`（“Virtual audio connection lifecycle” suite），全部用 `maximumDelay: 60` 把音频侧自己的兜底定时器排除在测试之外，因此完成回调只可能来自被测的打断路径：

1. `reconfiguringTheOutputMidDrainStillReportsTheDrainExactlyOnce` —— 排空期间 `endSession()`（即 `flushPlayer()`）打断，回调必须恰好一次；随后 `stop()` 不得再触发第二次。
2. `tearingTheEngineDownMidDrainStillReportsTheDrainExactlyOnce` —— 排空期间 `stop()` 打断，回调必须恰好一次；随后 `endSession()` 不得再触发第二次。
3. `aDrainCompletionThatTearsTheOutputDownAgainReportsOnlyOnce` —— 回调内部再次调用 `stop()`（对应虚拟音频释放路径的既有写法），必须不递归、不重复调用。
4. `aSecondDrainRequestDoesNotStrandTheFirstWaiter` —— 第二次排空请求必须把第一个等待方交还并调用，而不是覆盖丢弃。

`Tests/RemoteMicTests/VoiceFnTapSessionControllerTests.swift`（“Typeless Fn tap session lifecycle” suite）：

5. `aDrainAnswerThatNeverArrivesStillClosesTheSessionAndAcceptsTheNextPress` —— 排空回答一次都不到达（模拟输出对象被释放）时，截止时间必须让会话完成收尾 Fn 配对回到 `.idle`，并且**下一次语音键按下被接受**且能进入 `.active(2)`。
6. `aTimelyDrainCancelsTheDeadlineBeforeItCanCutTheNextSession` —— 正常排空后推进 5 秒虚拟时间，后续健康会话必须不受影响，Fn 事件序列不得多出任何一次。

反向验证（确认断言真的依赖本次修复，而不是恒真）：

- 把 `takeInterruptedDrainCompletion()` 的 `let completion = drainCompletion` 改回 `let completion: (() -> Void)? = nil`（等价于修复前「清空但不调用」）：

```text
$ swift test --filter "MidDrain|StrandTheFirstWaiter|TearsTheOutputDownAgain" > /tmp/a5-negative-control.log 2>&1
EXIT_CODE=1
✘ Test reconfiguringTheOutputMidDrainStillReportsTheDrainExactlyOnce() … (completionCount → 0) == 1
✘ Test tearingTheEngineDownMidDrainStillReportsTheDrainExactlyOnce() … (completionCount → 0) == 1
✘ Test aDrainCompletionThatTearsTheOutputDownAgainReportsOnlyOnce() … (completionCount → 0) == 1
✘ Test aSecondDrainRequestDoesNotStrandTheFirstWaiter() … (secondCount → 0) == 1
✘ Test run with 4 tests in 1 suite failed after 0.001 seconds with 6 issues.
```

`completionCount → 0` 就是用户遇到的现象：回调永远不会到达。

- 把 `beginDrain` 中截止任务的 `self?.beginStopTap(generation: sessionGeneration)` 换成空操作：

```text
$ swift test --filter "NeverArrives|CancelsTheDeadline" > /tmp/a5-negative-control-controller.log 2>&1
EXIT_CODE=1
✘ Test aDrainAnswerThatNeverArrivesStillClosesTheSessionAndAcceptsTheNextPress() recorded an issue at VoiceFnTapSessionControllerTests.swift:172:9: Expectation failed: (harness.controller.phase → .draining(1)) == .stopping(1)
✘ Test aDrainAnswerThatNeverArrivesStillClosesTheSessionAndAcceptsTheNextPress() recorded an issue at VoiceFnTapSessionControllerTests.swift:175:9: Expectation failed: (harness.controller.phase → .draining(1)) == .idle
✘ Test aDrainAnswerThatNeverArrivesStillClosesTheSessionAndAcceptsTheNextPress() recorded an issue at VoiceFnTapSessionControllerTests.swift:176:9: Expectation failed: (harness.functionKeyEvents → [true, false]) == [true, false, true, false]
✘ Test aDrainAnswerThatNeverArrivesStillClosesTheSessionAndAcceptsTheNextPress() recorded an issue at VoiceFnTapSessionControllerTests.swift:179:9: Expectation failed: (harness.controller.phase → .draining(1)) == .active(2)
✘ Test run with 2 tests in 1 suite failed after 0.001 seconds with 4 issues.
```

`phase → .draining(1)` 就是卡死状态本身：收尾 Fn 从未发出（`[true, false]` 而不是 `[true, false, true, false]`），下一次语音键也无法真正开启会话。需要注意 `startVoice()` 本身仍返回 `true`（`.draining` 下它只会把语音暂存进 `pendingVoice`），因此「下一次按键被接受」必须用阶段是否真的推进到 `.active(2)` 来判定，这也是该测试断言阶段而不是只断言返回值的原因。

两次反向验证后源文件均已逐字还原，还原前后 `git diff`（限定本次改动的 5 个文件）字节一致，`sha256 = e719c790c7f0fd638ce1c772b1b983382a39d85067a929ddaa713651f525212f`，并重新执行了上述三条命令。

fork 专有行为回归（自动化层面）：`swift test` 全绿的 289 项中，四项 fork 专有行为对应的测试均通过——可配置语音触发键与外接麦克风采集开关（`VoiceTriggerKeyTests` 的 `setFunctionKeyPressedInjectsTheSelectedTriggerKeyCodeAndFlags`、`modifierTriggersUseHoldInjectionAndNeutralizeHardwareKey`、`fnTapInjectionAppliesOnlyToFnWhileStreamingRemoteMic`、`fnKeepsHardwareRemapUnlessTypeless`、`voiceKeyUsesRemoteMicrophoneDefaultsOnAndRoundTrips`），右侧修饰键不粘滞与自定义快捷键左右保真（`RemoteButtonsTests` 的 `sideSpecificShortcutHoldsRealModifierAndReleasesInReverse`）。

本次未改动语音触发键判定、`VoiceTriggerKey`、`KeyboardInjector`、修饰键释放顺序、外接麦克风采集开关或 HID 路径。`VoiceFnTapSessionController` 的改动只新增一个受 generation 保护的截止任务，未改变任何既有阶段迁移或按键事件顺序：既有测试中的 Fn 事件序列断言逐字未变且全部通过。上述均为自动化断言，**不等于这四项 fork 行为已完成真机验收**。

## 自动化与真机边界

**本次修复完全没有在真实硬件或真实音频设备变化上验证，不能视为已完成真机验收。** 代理无法接入真实小米蓝牙语音遥控器，无法触发真实 CoreAudio 设备热插拔、真实系统默认输入切换或真实 `AVAudioEngineConfigurationChange` 通知，也无法在真实 Typeless / 豆包输入法中观察听写结果。

自动化只覆盖：

- `VirtualAudioOutput` 的排空账目状态机。测试进程没有可用的虚拟输出设备，因此 `engine` 与 `player` 始终为 `nil`，`flushPlayer()` 与 `stop()` 只执行到锁内的状态清理与回调交还，**真实的 `player.stop()` / `player.reset()` / 重启节点分支一次都没有执行**。待播缓冲通过 `registerPendingVoiceBuffer()` 登记，而非真实 `scheduleBuffer`。
- `VoiceFnTapSessionController` 的阶段迁移与截止时间，使用虚拟时间的手写调度器驱动，未经过真实主队列时序。

**以下均未验证**：

- 真实设备切换、睡眠唤醒或引擎配置变化落在 0.75 秒排空窗口内的实际时序，以及此时尾音的实际听感是否有截断；
- `player_restart_exception` 分支在真实节点上的行为，以及该分支下 `onConfigurationChange` 与回调的实际先后对音频恢复的影响；
- 2 秒截止时间在真机上是否足够宽裕（真实主队列在音频恢复期间可能被阻塞），以及真机上是否会出现「音频侧回调与控制器截止时间同时到期」的竞争；
- 手机语音停止与虚拟音频释放两条排空请求真实重叠时的行为；
- 卡死修复后，真实 Typeless / 豆包输入法是否确实收到成对的 Fn，且第一次按键即成功（不接受第二、三次才成功）。

上述项目必须按 [`Testing/VoiceDrainInterruptionRecovery.md`](../Testing/VoiceDrainInterruptionRecovery.md) 在真实遥控器与真实音频设备上完成一次完整流程，并收集 `~/Library/Logs/RemoteMic/runtime.log` 后才能确认。当前只能确认自动化边界通过。

## 附带发现（本次未修复）

`finishDrainIfNeeded` 把 `pendingVoiceBufferCount` 置零但不清空也不打印 `pendingDrainLogContexts`；随后的 `flushPlayer()` 因为计数已经为 0，会把这些上下文直接丢弃，既不写 `drained` 也不写 `interrupted`。即兜底超时路径的 trace 在日志中无声消失。这是修复前后一致的既有行为，属于诊断缺陷而非本次根因，按最小修复范围**刻意未改动**。
