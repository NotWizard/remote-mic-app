# 音频配置变化恢复测试手册

## 适用范围

- 目标版本：本次修复起（`1.8.25-fork.6` 及之后）
- 覆盖改动：`AVAudioEngineConfigurationChange` 的恢复判定改为只看引擎是否仍绑在选定设备，不再要求引擎正在运行
- 缺陷记录：[`Bugs/2026-08-27-idle-audio-rebind-loop.md`](../Bugs/2026-08-27-idle-audio-rebind-loop.md)

## 测试前准备

1. 在设置里选定虚拟音频设备（`MiRemoteV 2ch`）。
2. 观察命令：

```
grep -E "AUDIO RECOVERY begin|configuration_ignored|configuration_changed" ~/Library/Logs/RemoteMic/runtime.log | tail -30
```

## 用例

### AC-01 空闲不再刷屏重绑（核心用例，已由代理真机验证）

1. 连接遥控器，选定 `MiRemoteV 2ch`，然后**什么都不做**，静置 5 分钟。
2. 统计：

```
grep "AUDIO RECOVERY begin" ~/Library/Logs/RemoteMic/runtime.log | cut -c1-16 | uniq -c | tail -6
```

预期：`AUDIO RECOVERY begin reason=engine_configuration_change` **不再以每分钟数十次的速率出现**。偶发的 `configuration_ignored reason=still_bound` 是正常的、期望的。

失败判定：`AUDIO RECOVERY begin ... engine_configuration_change` 持续每分钟数十次；或日志文件几分钟内涨到 4MB 触发轮转。

> 代理已在本机对比：修复前 3 分钟约 144 次，修复后 0 次。此用例请在你的日常使用环境再确认一次。

### AC-02 真实拔插外接设备仍能及时恢复（须实测，代理未做）

这是本次改动最需要真机确认的一项：修复缩小了「需要恢复」的判定范围，必须确认真实设备变化没有被一起忽略掉。

1. 选定 `MiRemoteV 2ch`，触发一次语音让音频真正开始播放。
2. 插拔一个外接音频设备（如 USB 声卡、DJI Mic 接收器、外接显示器自带音箱），或在系统声音设置里切换默认输出再切回。
3. 观察日志。

预期：出现 `AUDIO RECOVERY begin`（这次是应该的），且音频最终仍绑回 `MiRemoteV 2ch`，语音可继续正常播放。

失败判定：设备变化后 App 不再恢复，音频停留在错误设备上；或语音播放中断且不恢复。

### AC-03 语音播放中不受影响

1. 按住语音键，说一段较长的话（10 秒以上）。
2. 全程观察日志。

预期：语音音频连续、完整，不因配置变化被打断；与上一正式版体验一致。

失败判定：语音中途卡顿、丢尾、或会话卡死（参见 `Bugs/2026-08-21-voice-session-wedges-when-audio-reconfigures-mid-drain.md`）。

### AC-04 长时间运行不复发

1. 让 App 正常运行数小时（含息屏、睡眠唤醒各一次）。
2. 统计当天日志的 `AUDIO RECOVERY begin ... engine_configuration_change` 总数与每分钟峰值。

预期：不出现持续的高频重绑段。

失败判定：任意时段重新出现每分钟数十次的重绑。

## 日志收集

```
cp ~/Library/Logs/RemoteMic/runtime.log ~/Desktop/ac-runtime.log
grep -c "AUDIO RECOVERY begin" ~/Desktop/ac-runtime.log
```

## 验证边界

- 已完成（自动化）：`Tests/RemoteMicTests/AudioConfigurationChangeRecoveryTests.swift` 五项，覆盖决策函数与循环形态；`swift test` 409 项、`scripts/test.sh` 42 项、边界检查、Release 构建。
- 已完成（代理真机观测）：AC-01，同机对比修复前 48 次/分钟 → 修复后 0 次/3 分钟。
- **未完成（须用户实测）**：AC-02 真实拔插、AC-03 语音播放中、AC-04 长时间运行。其中 AC-02 是本次改动的主要回归风险——代理只观测了稳态空闲，没有做任何真实设备变化。
- 无法由代理执行：AC-02 至 AC-04 都需要真实音频设备操作与长时间真实使用。
