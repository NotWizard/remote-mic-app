# 语音键触发旁白、修饰键卡住、系统整体卡顿（1.8.25-fork.6 回归）

- 时间：2026-08-28
- 状态：已修复，自动化通过；真机验收未完成
- 影响范围：使用修饰键作为语音触发键（如右 Command）的用户，在 `1.8.25-fork.6` 上遥控器重连后可进入该状态
- 功能点：`RemoteVoiceFunctionMapper` 的语音键映射与 `retryPowerKeyMappingWrite` 的重试
- 简单描述：启动录音时莫名开启 macOS 旁白；关掉旁白后系统很卡，鼠标点击无法切换窗口。**这是我在 `1.8.25-fork.6` 引入的回归。**

## 复现

用户现场（`1.8.25-fork.6 (125)`，`voiceTriggerKey = rightCommand`，`voiceKeyUsesRemoteMicrophone = 0`）：

1. 遥控器重连（此时 HID 服务尚未注册，映射写入 `matched=0`）。
2. 按遥控器语音键启动录音。

错误行为：旁白被开启；此后系统卡顿，在终端等 App 里鼠标点击无法切换窗口。
正常行为边界：`1.8.25-fork.5` 及之前无此现象。

## 日志结论

日志：`~/Library/Logs/RemoteMic/runtime.log`。

正常的一次（08-28 05:58:54，末态正确）：

```text
VOICE FN MAPPING applied=true neutralized=false power_suppressed=true ... matched=1
VOICE FN MAPPING applied=true neutralized=true  power_suppressed=true ... matched=1
```

出问题的一次（08-28 09:19:12，末态错误）：

```text
VOICE FN MAPPING applied=false neutralized=false power_suppressed=false matched=0   ← ×3
VOICE FN MAPPING applied=true  neutralized=false power_suppressed=true  matched=1   ← 最终
```

决定性差异是末态的 `neutralized`：正常那次是 `true`，出问题那次是 **`false`**。

随后的语音注入全程成对，没有 App 侧记账丢失：

```text
09:19:37 VOICE TRIGGER INJECT DOWN key=rightCommand
09:19:37 VOICE TRIGGER INJECT UP   key=rightCommand
```

## 根因

遥控器的语音键在硬件上是键盘 **F5**（`RemoteVoiceFunctionMappingPolicy.remoteVoiceKey`，usage 0x3E）。修饰键注入模式下的正确做法是把它映射成 **usage 0（彻底丢弃）**，代码注释写明了原因：

> `// Injection modes neutralize the hardware F5 so it never emits on its own;`
> `// ... This avoids a stuck hardware-remapped modifier.`

`neutralized=false` 意味着走的是降级映射 `voiceMapping(for: trigger)`：F5 被改写成**触发键本身**。于是右 Command 有了两个来源（硬件按键 + App 注入）和两条释放路径，任一不同步就有一侧悬空——这正是注释要避免的"卡住的硬件改写修饰键"。一个卡住的 Command 会把所有鼠标点击变成 Command+点击，与用户描述的"点击切换不了窗口"一致；Cmd 与 F5 同时到达系统即触发旁白开关。

**为什么末态会停在降级映射**：`applyHIDSettings` 在"丢弃 F5"失败后会退一步尝试"改写 F5"（原 `BridgeAppModel.swift:1099-1105`）。而它的失败判据是 `!isVoiceKeyNeutralized`，这个条件在**两种完全不同的情况**下都为真：

1. 设备在，但硬件拒绝接受中性映射——此时降级是合理结论；
2. 设备不在（`matched=0`）——此时什么都没写、什么都没学到，降级是**猜测**。

情况 2 被当成了情况 1。这是既有缺陷。而我在 fork.6 加的 `retryPowerKeyMappingWrite` 把它变成了永久状态：重试用 `lastNeutralizeVoiceKey` 重放"上一次尝试的值"，而失败的 `applyHIDSettings` 恰好以降级尝试收尾，于是该值停在 `false`。第一次真正写成功的重试，落地的就是降级映射。

## 修复

1. `RemoteVoiceFunctionMapper` 新增 `didReachDevice`，区分"没找到任何服务"与"找到了但没写成"。它**刻意在 rollback 中存活**——拒绝中性映射会回滚，而回滚恰恰证明设备答复过。只有 `matched=0` 那条路径才清零。
2. 抽出 `writeVoiceFunctionMapping()` 作为写入决策的唯一定义，`applyHIDSettings` 与重试共用，两者不可能再分叉；删除 `lastNeutralizeVoiceKey`。
3. 降级只在 `didReachDevice` 为真时进行。设备没碰到就保持原样，交由重试继续以"丢弃 F5"为目标——重试次数无上限，因此不会永久停在半途。

未放宽任何权限门禁，未改动注入时序，未改变设备在场时的降级行为。

## 验证

反向验证：仅去掉 `didReachDevice` 那道守卫（恢复无条件降级），新增回归测试立即变红，失败信息为 `isVoiceKeyNeutralized → false` 且实际写入 `neutralAttempts → [false]`——与现场日志的 `neutralized=false` 同形。随后按 `shasum -a 256` 确认源文件逐字节还原（`32230cc5…`）。

修复后：

- `swift test`：412 项、37 个 suite，连续 3 次全部通过（新增 3 项；基线 409）；
- `./scripts/test.sh` 42 项、`./scripts/check-repository-boundaries.sh`、`swift build -c release`：通过。

新增测试：

- **回归本体**：前 3 次写入设备缺席、第 4 次设备出现，最终必须落在中性映射上，且期间不得出现任何降级写入；
- **正向对照**：设备在场但拒绝中性映射时，降级仍必须发生——否则本修复等价于"永不降级"；
- **顺序不变量**：映射写入必须先于任何监听器启动，改为观测日志实际写入顺序。

一并把 `powerSuppressionIsArmedBeforeButtonCallbacksAndMonitoring` 中"切片 `applyHIDSettings` 源码文本比较片段位置"的那一半删掉了。决策抽成函数后该文本必然对不上，而它原本也只能发现"字面量搬家"，发现不了真实重排；同一不变量已改为行为断言。

## 自动化与真机边界

**未验证**：

- 真实遥控器上旁白不再被触发、右 Command 不再卡住——本修复的核心目的，只能真机确认；
- 真实硬件确实拒绝中性映射时（正向对照测试模拟的情况）降级是否如期发生；
- 修复后长时间使用中是否还有其他路径能进入 `neutralized=false`。

真机验收按 [`Testing/HIDTakeoverRecoveryAfterIdle.md`](../Testing/HIDTakeoverRecoveryAfterIdle.md) 新增的 TR-07 执行。
