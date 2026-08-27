# 空闲时音频引擎每秒重绑一次，自我维持的循环

- 时间：2026-08-27
- 状态：已修复，**已在真机观测到循环消失**；仍有未覆盖项，见文末
- 影响范围：所有选择了虚拟音频设备的用户；`1.8.25-fork.5` 现场持续复现
- 功能点：`AVAudioEngineConfigurationChange` 通知的处理与音频恢复
- 简单描述：App 空闲时陷入「重绑 → 引擎配置变化 → 判定需要恢复 → 重绑」的闭环，约每 1.2 秒一圈，永不停止。不影响听到的声音，但持续耗 CPU，并让日志每 20 分钟写满 4MB 轮转一次，把真正有用的历史冲掉。

## 复现

无需操作，App 空闲即可。现场（`1.8.25-fork.5 (124)`，选中输出为 `MiRemoteV 2ch`）：

```
grep "AUDIO RECOVERY begin" ~/Library/Logs/RemoteMic/runtime.log | cut -c1-16 | uniq -c
```

实测每分钟 48 次（约 1.2 秒一圈），成串爆发、间歇停歇。日志文件 20 分钟轮转一份 4MB。

错误行为：空闲时持续重绑，无任何用户操作触发。
正常行为边界：声音不受影响——全程 `engine_running=false`（没有播放），且 `bound_to_selected=true`（设备一直正确绑定）。语音、按键功能均正常。

## 日志结论

一个完整周期，逐行摘录（2026-08-27T07:40:00Z）：

```text
AUDIO RECOVERY begin id=2028 reason=engine_configuration_change ... bound_to_selected=true
AUDIO DEVICES refresh_requested id=2098
AUDIO REBIND begin reason=recovery_engine_configuration_change
AUDIO CONFIGURE begin target={name=MiRemoteV 2ch id=88}
AUDIO READY target={name=MiRemoteV 2ch id=88}
AUDIO REBIND finished reason=recovery_engine_configuration_change success=true
AUDIO RECOVERY completed id=2028
AUDIO ENGINE configuration_changed generation=4013     ← 重绑自己造成的
AUDIO RECOVERY scheduled id=2029 reason=engine_configuration_change   ← 于是再排一次
```

闭环成立的两点证据：

1. `AUDIO READY` 之后**紧跟** `configuration_changed`，每个周期都如此；
2. `generation` 每圈 +2，正好等于 `removeEngineConfigurationObserver`（+1）与 `observeConfigurationChanges`（+1）各一次，说明重绑确实重建了观察者并收到了针对新配置的通知。

另有 `reason=hardware_change` 25 次，与本循环无关（真实设备变化）；`engine_configuration_change` 1068 次即循环本体。

现有的 `replaced_pending` 合并机制帮不上：每圈都在下一次排程之前就已完成，没有可合并的对象。

## 根因

抑制这个循环的门禁原本是（`AudioOutput.swift`）：

```swift
if self.isReadyForTestTone,
   let selectedDevice = self.selectedDevice,
   self.currentOutputDevice()?.id == selectedDevice.id {
    // configuration_ignored reason=still_bound
    return
}
```

后两个条件日志显示都成立（`selected=id 88`、`actual_output=id 88`）。卡住的是第一个：

```swift
var isReadyForTestTone: Bool {
    selectedDevice != nil && engine?.isRunning == true
}
```

**它要求引擎正在运行。** 而循环恰好发生在引擎空闲时——也就是自造配置变化会发生、且完全没有东西需要恢复的时候。于是抑制在最该生效的场景下不可用，每一次自己造成的变化都被当成真实硬件变化去恢复，而恢复动作又造成下一次变化。

判据本身拿错了：`engine.isRunning` 证明的是「音频正在流动」，不是「绑定仍然正确」。而 `currentOutputDevice()` 读的是引擎输出单元当前指向的设备（`AudioUnitGetProperty(kAudioOutputUnitProperty_CurrentDevice)`），这才是「还绑着」的直接判据，且不要求引擎在跑。

## 修复

抽出 `AudioEngineConfigurationChangePolicy.needsRecovery(selectedDeviceID:currentOutputDeviceID:)`，只比较这两个设备 id：相等即忽略，任一为 nil 则朝「需要恢复」方向失败（引擎没有输出设备、或尚未选定，都不是绑定正常的证据）。通知回调改为走该策略。

`isReadyForTestTone` 保留，它在测试音门禁与 `isAudioOutputReady` 处仍是正确判据，只是不再参与「这次配置变化要不要恢复」的决定。

## 验证

**真机行为验证（决定性）。** 循环当时正在本机持续发生，因此直接对比同一台机器上两个版本各运行 3 分钟：

| | `AUDIO RECOVERY begin` | `configuration_ignored` | 新增日志行 |
| --- | --- | --- | --- |
| 修复前（安装版 1.8.25-fork.5） | 约 144 次（48/分钟） | 0 | 约 900 |
| 修复后（本次构建） | **0** | **2** | **57** |

`configuration_ignored reason=still_bound` 出现 2 次，正是那两次自造变化被正确忽略；在旧代码下它们各会启动一轮恢复并再生下一轮。

同时确认正常功能未受影响（同一 3 分钟窗口内）：`VOICE FN MAPPING applied=true power_suppressed=true matched=1 applied=1`、`HID START mode=adaptive`、`BLE CONNECTED`、`BLE READY`、`AUDIO READY`（`engine_running=true` 且绑定正确）。

自动化：

- `swift test`：409 项、37 个 suite 通过（新增 5 项、1 个 suite；基线 404/36）；
- `./scripts/test.sh`、`./scripts/check-repository-boundaries.sh`、`swift build -c release`：通过。

新增测试覆盖：绑定未变必须忽略（回归本体）、绑定被改必须恢复（正向对照，否则「永不恢复」也能通过）、任一侧未知必须恢复、判定不得依赖引擎是否运行、以及按现场日志形态回放整个周期必须收敛为 0 次重绑。

## 自动化与真机边界

**未覆盖**：通知回调本身的接线。`observeConfigurationChanges` 是私有的且需要真实 `AVAudioEngine`；在测试进程里让引擎绑定真实设备正是本仓库其他 suite 崩溃的原因，因此没有为它建注入点。新增测试验证的是决策函数与循环形态，接线只由上面的真机对比证明。

**仍未验证**：

- 真实拔插外接音频设备时恢复是否仍然及时（本次只观测了稳态空闲，没有做拔插）；
- 语音会话进行中发生配置变化的行为，与 [`Bugs/2026-08-21-voice-session-wedges-when-audio-reconfigures-mid-drain.md`](2026-08-21-voice-session-wedges-when-audio-reconfigures-mid-drain.md) 记录的场景是否有交互；
- 长时间运行（数小时）后循环是否会以其他形式回来。

这三项按 [`Testing/AudioConfigurationChangeRecovery.md`](../Testing/AudioConfigurationChangeRecovery.md) 由用户实测。
