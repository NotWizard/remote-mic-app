# 右侧修饰键触发导致修饰键卡住

- 时间：2026-08-13
- 状态：已修复（自动化通过；待真机验收）
- 影响范围：把语音键触发键设为右 Command / Option / Shift 的 Mac App（v1.8.14 本地测试包）
- 功能点：语音键触发键发射机制
- 简单描述：修饰键触发靠“把 F5 硬件重映射成真·修饰键”实现，一旦某次 key-up 丢失，修饰键卡在按下态，连锁出“无法停止、误触发 VoiceOver、系统卡顿”。
- 原始记录：`~/Library/Logs/RemoteMic/runtime.log`；本文；修复见同批提交

## 复现与现象

- 触发键设为右⌘后：①按住启动、再次按下无法正确停止；②多次按压后触发 VoiceOver（旁白）；③多次按压后整机卡顿。
- 无法在无真机环境复现（我没有 RC003）；以下为只读诊断（日志 + 代码）。

## 日志证据（v1.8.14）

- `VOICE FN MAPPING applied=true neutralized=false ... matched=1 applied=1`：F5→触发键的**硬件重映射已生效**（这层是 IOHID `UserKeyMapping`，不需要权限）。
- `VOICE TRIGGER key=rightCommand`：触发键已切到右⌘。
- `HID PERMISSIONS input=false accessibility=false`：该 ad-hoc 包**未获授权**（重签名后 TCC 视为新程序）。但硬件重映射不依赖权限，故与本根因无关。
- 多组 `ATVV STREAM START/STOP`（含同秒内快速连按）。

## 根因

- 右侧修饰键此前与 Fn 共用同一机制：`RemoteVoiceFunctionMapper` 用 IOHID `UserKeyMapping` 把语音键 F5 重映射成目标 usage（右⌘=`0x0007_00E7`）。
- 把“按住说话键”映射成**真·修饰键**时，松开依赖 F5 的 key-up 被可靠投递并重映射为“修饰键 up”。一旦某次 key-up 丢失或被打断（快速连按、或改设置触发重映射重写），**修饰键卡在按下态**。
- 卡住的 ⌘ 解释全部三个现象：软件收不到干净松开→无法停止；⌘ 一直按着，点按/按键都成 ⌘ 组合→卡顿；VoiceOver 快捷键正是 **⌘+F5**，卡住的 ⌘ 再遇到一次漏掉重映射的 F5 即触发旁白。
- Fn 之前未暴露，是因为**卡住的 Fn/Globe 基本无害**；换成真修饰键才炸出来。
- 置信度：根因“卡住的修饰键”**高**；“为何某次 key-up 会丢”的精确 HID 时序**中**，需真机抓 HID 事件确认。

## 修复

- 右侧修饰键**不再用硬件重映射**，改为**软件注入**：`applyHIDSettings` 对修饰键触发调用 `applyVoiceFunctionMapping(neutralizeVoiceKey: true)` 屏蔽 F5（F5→0），触发键由注入产生。
- 注入随 ATVV 生命周期：`bluetoothBridgeDidStartVoice` 注入“修饰键按下”、`bluetoothBridgeDidStopVoice` 注入“修饰键松开”（均在各自守卫之前，覆盖收音开/关两种模式）；复用 `VoiceFunctionKeyLatch` 保证一次按下配一次松开、失败回滚。
- **保证松开**（force-release，经同一 latch 幂等）：`stop()`（退出）、蓝牙断连分支、`applyHIDSettings` 重映射前、`setVoiceTriggerKey`（用**旧键**先释放再切换）。
- Fn 维持现状：非 Typeless 走硬件重映射，Fn+Typeless 走既有点按会话。
- 权限：注入需辅助功能权限；缺失时 F5 保持屏蔽（惰性无害、不再卡键），并提示授权。
- 策略集中在 `VoiceKeyModePolicy`（`usesModifierHoldInjection` / `usesFnTapInjection` / `neutralizesHardwareVoiceKey`）。

## 验证与边界

- 自动化：`xcrun swift test`（222）与 `./scripts/test.sh`（42）通过。新增 `VoiceKeyModePolicy` 真值表；`VoiceFunctionKeyLatchTests` 证明一次按下/一次松开/失败回滚；默认 Fn 路径逐字节不变。
- 真机（未完成，必须由用户在 RC003 上做）：先给新包授予“输入监控 + 辅助功能”。重点：右⌘ 连按 10 次不再卡键、不触发 VoiceOver、系统不卡；传输中断连 / 退出 App 后修饰键被强制松开；日志出现成对 `VOICE TRIGGER INJECT down/up`。
- 边界：单测只证进程内逻辑与状态机；真机 HID 时序、连按稳定性、断连释放需真机复测，我无法真机复现原始卡键。
