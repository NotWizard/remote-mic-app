# 长时间闲置重连后按键接管恢复测试手册

## 适用范围

- 目标版本：`1.8.25-fork.6` 及之后（本次修复起）
- 覆盖改动：开 IOHIDManager 不再要求开关机键已接管；「设备出现」事件驱动映射重跑；开关机键在未接管前逐次跳过；重试判定改读真实桥状态
- 缺陷记录：[`Bugs/2026-08-27-hid-takeover-dead-retry-and-circular-dependency.md`](../Bugs/2026-08-27-hid-takeover-dead-retry-and-circular-dependency.md)
- 上一次同症状记录：[`Bugs/2026-08-21-remote-reconnect-loses-custom-button-mapping.md`](../Bugs/2026-08-21-remote-reconnect-loses-custom-button-mapping.md)（其修复为死代码，本次修正）

## 测试前准备

1. 确认自定义映射已开启，且至少两个普通键绑定了可分辨的动作（例如 `tv` → 打开某 App，`menu` → 打开另一个 App）。
2. 清空日志起点：`: > ~/Library/Logs/RemoteMic/runtime.log`
3. 准备好这条观察命令，后续每个用例都用它：

```
grep -E "VOICE FN MAPPING|HID START|HID MAPPING (RETRY|REAPPLY)|HID CONNECTED|HID INPUT ignored reason=power_key|BLE READY" ~/Library/Logs/RemoteMic/runtime.log
```

## 用例

### TR-01 长时间闲置后重连必须自行恢复（核心用例）

必须制造出 `matched=0`。经验上遥控器需要真正断开较长时间（隔夜最稳，或关闭遥控器电源 30 分钟以上），仅短暂断开通常不会触发。

1. 让遥控器长时间断开（隔夜或 30 分钟以上关机）。
2. 唤醒遥控器，等待连接成功。
3. **不要重启 App，不要改任何设置。**
4. 等待 30 秒，然后按 `tv` 与 `menu`。

预期：

- 两个键都执行你配置的动作，不是 macOS 原生行为。
- 日志中若出现 `matched=0`，则**必须**紧随其后出现 `HID MAPPING REAPPLY reason=device_appeared` 或 `HID MAPPING RETRY scheduled`，且最终出现一次 `matched=1 applied=1`。

失败判定：按键仍是原生行为；或日志中出现 `matched=0` 却既无 `REAPPLY` 也无 `RETRY scheduled`（那是上一次修复的死代码形态，说明本次修复同样没生效）。

> 若本次重连一次就 `matched=1`，说明没触发到目标场景，该用例记为**未触发**，不得记为通过。请另择时间重试。

### TR-02 开关机键在待接管期间既不执行自定义动作也不休眠

这是本次为「提前开监听器」付出的安全代偿，必须实测。

1. 在 TR-01 出现 `matched=0` 之后、`matched=1` 之前的窗口内（可能只有几秒，可借助 `tail -f` 盯日志）。
2. 按一下遥控器开关机键。

预期：Mac **不**休眠、**不**锁屏，也**不**执行你给开关机键配的动作；日志出现 `HID INPUT ignored reason=power_key_not_neutralized`。

失败判定：Mac 休眠或锁屏；或自定义动作被执行。任一命中都属严重问题，须立即停止发布。

> 窗口太短抓不到时记为**未触发**，并在交付说明中明确标注该项未验证。

### TR-03 接管成功后开关机键恢复正常配置

1. TR-01 完成、日志已出现 `matched=1 applied=1` 之后。
2. 按开关机键。

预期：执行你配置的动作，Mac 不休眠不锁屏。

失败判定：Mac 休眠；或动作不生效；或日志仍出现 `power_key_not_neutralized`。

### TR-04 状态文案如实反映待接管

1. 在待接管窗口内点开菜单栏图标，并打开设置的「按键映射」页。

预期：状态显示「按键功能已连接；开关机键仍在接管中，暂时保持原功能」，而不是普通的「按键功能已连接」。

2. 接管成功后再看一次。

预期：变回「按键功能已连接」。

失败判定：待接管期间显示成普通「已连接」（用户无从得知开关机键仍是原生行为）；或文案被截断、换行破版；或中文显示字号目测小于 12pt。

### TR-05 四种映射开关状态（仓库门禁要求）

本次改动落在共享 HID 路径上，四种状态都要过一遍。每一步后按 `tv` 验证。

1. 开关缺失（全新用户）：`defaults delete com.hd838a.RemoteMic customMappingEnabled`，重启 App → 预期与上一正式版行为一致。
2. 明确关闭：设置里关掉自定义映射 → 预期按键全部退回原生行为，日志 `HID START rejected reason=mapping_disabled`。
3. 开启：打开 → 预期自定义动作生效。
4. 用后再关：再关掉 → 预期干净退回原生行为，无残留、无卡住的修饰键。

失败判定：任一状态下行为与上一正式版不一致；或关闭后仍有自定义动作触发。

### TR-06 不得出现重跑风暴

latch 与退避是防死循环的，必须确认没退化成刷日志。

1. TR-01 之后统计：

```
grep -c "HID MAPPING REAPPLY" ~/Library/Logs/RemoteMic/runtime.log
grep -c "HID MAPPING RETRY attempt=" ~/Library/Logs/RemoteMic/runtime.log
```

预期：单次重连中 `REAPPLY` 不超过 1 次；`RETRY attempt=` 为个位数并随退避拉长间隔。

失败判定：任一计数持续增长不停；或日志文件在几分钟内暴涨（4MB 级轮转）。

## 稳定功能回归

TR-01 完成后各做一次：

1. 语音键：按住说话，语音工具正常接收，松开停止。
2. 双击 / 长按绑定：各验证一个。
3. 遥控器电量与型号在连接页正常显示。
4. 断开遥控器再连回，按键仍正常。

## 日志收集

```
cp ~/Library/Logs/RemoteMic/runtime.log ~/Desktop/tr-runtime.log
```

附上每个用例前后的观察命令输出。

## 验证边界

- 已完成（自动化）：`Tests/RemoteMicTests/HIDMappingRecoveryTests.swift` 四项，覆盖「`matched=0` 时必须排程重试」「`canObserve` 不受开关机键接管结果影响」「latch 每次出现只放行一次」「latch 会复位」。均通过注入 mapper 与直接驱动委托回调实现，**没有真实 CoreBluetooth，也没有真实 HID 服务注册时序**。
- 已完成（自动化）：`swift test` 404 项、`scripts/test.sh` 42 项、仓库边界检查。
- **未完成且无法由代理执行**：TR-01 至 TR-06 全部用例与上面的稳定功能回归，都需要真实遥控器硬件与真实的长时间闲置。
- **最关键的未验证假设**：`deviceDidMatch` 触发那一刻，`RemoteVoiceFunctionMapper` 的服务枚举是否一定 `matched>0`。整个修复建立在这个假设上。TR-01 是唯一能证伪它的途径——若 TR-01 反复出现 `REAPPLY` 之后仍 `matched=0`，说明两套枚举并不同步，需要改为等待 IOKit 服务真正可写再重跑。
