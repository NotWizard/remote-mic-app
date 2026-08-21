# 遥控器长时间休眠后重连，自定义按键映射失效并退回系统默认

- 时间：2026-08-21
- 状态：已修复，自动化通过；真机验收未完成
- 影响范围：所有启用自定义按键映射的用户；`1.8.17` 现场复现，`1.8.25-fork.1` 同样存在
- 功能点：BLE 就绪后写 HID 映射与 `HIDPermissionGate` 门禁
- 简单描述：遥控器隔夜休眠后重连，App 写 HID 映射时匹配到 0 个服务，按键监听被永久拒绝，普通按键退回 macOS 原生行为，且当天不会自行恢复。

## 复现

用户现场条件（`1.8.17 (109)`，进程自 2026-08-15 14:00 起未重启）：

1. 前一天自定义映射工作正常（`tv` → 阿里钉，`menu` → ChatGPT）。
2. 遥控器隔夜休眠，Mac 侧 BLE 持续重连失败约 2 小时。
3. 次日遥控器唤醒并连接成功。
4. 按 `tv` 或 `menu`，动作不生效，表现为 macOS 原生按键行为。

错误行为：普通按键不再执行用户配置的动作。
正常行为边界：语音键仍然可用（走 BLE/ATVV，不经 HID 监听），用户配置未丢失。

## 日志结论

日志：`~/Library/Logs/RemoteMic/runtime.log`。

2026-08-21 本地 08:00–10:02 共 640 次 `BLE CONNECT` 尝试，仅 1 次成功。连接成功后：

```text
02:02:00Z BLE CONNECTED name=小米蓝牙语音遥控器
02:02:01Z VOICE FN MAPPING applied=false neutralized=false power_suppressed=false matched=0
02:02:01Z HID PERMISSIONS input=true accessibility=true
02:02:01Z HID START rejected power_suppressed=false
02:02:01Z HID PERMISSIONS input=true accessibility=true
02:02:01Z HID START rejected power_suppressed=false
```

当日 `HID BUTTON` 事件为 0，即 App 全天未收到任何按键；`HID START` 成功 0 次、拒绝 2 次，且此后无任何重试。

逐日对比确认这是当日独有状态：

| 日期 | `HID START` 成功 | 拒绝 | `matched=0` |
| --- | --- | --- | --- |
| 8/19 | 130 | 4 | 4 |
| 8/20 | 20 | 0 | 0 |
| 8/21 | 0 | 2 | 2 |

8/20 在同样的"连接后 1 秒写映射"时序下得到 `matched=1 applied=1 power_suppressed=true` 并 `HID START mode=adaptive` 成功。型号各日均为 `rc001`，权限各日均为 `input=true accessibility=true`。因此排除型号、权限和配置因素，指向就绪竞态。

配置侧核对（`defaults read com.hd838a.RemoteMic`）：`customMappingEnabled = 1`，`buttonBindings` 中 `tv`/`menu` 为 `openCustomApplication`，`buttonApplicationProfileIDs` 指向阿里钉与 ChatGPT。配置完好，排除"设置被重置"。

## 根因

`RemoteVoiceFunctionMapper.apply` 通过 `IOHIDEventSystemClientCopyServices` 枚举服务并按 VID/PID 过滤。匹配为 0 时直接返回 `false`（`RemoteVoiceFunctionMapper.swift:150-158`），不重试也不排程重试。

该返回值在 `BridgeAppModel.applyHIDSettings` 中成为 `powerKeySuppressed`，而 `HIDPermissionGate.canMonitor` 要求四项全真（`RemoteButtons.swift:714`）：

```swift
mappingEnabled && inputMonitoringGranted && accessibilityGranted && powerKeySuppressed
```

于是 `HIDRemoteMonitor.start` 拒绝启动监听并返回。

关键缺陷：HID event system 注册遥控器服务的时机与 BLE 连接完成相互独立。遥控器长时间休眠后重连时枚举慢于 1 秒，`matched=0` 必然发生。但 App 把这个**瞬时的"尚未就绪"**当作**终局判定**消费，且没有任何路径会重新评估：

- `startPermissionMonitor` 的轮询定时器在 `manager != nil` 之后才建立，启动被拒时根本不存在（`HIDRemoteMonitor.swift:707-718`）。
- 唯一的 `HID UPDATE RECOVERY` 仅在 Sparkle 更新完成后触发（`BridgeAppModel.swift:451-467`），兜不住本场景。

因此状态一旦进入就固定，直到用户重启 App 或切换设置才恢复。

## 修复

根治方向是让这个就绪判定重新变成可反复评估的，而不是猜一个固定延迟。

- 新增纯函数 `HIDMappingRetryPolicy`（`RemoteButtons.swift`，紧邻 `HIDPermissionGate`）：在自定义映射开启、遥控器已连接、映射尚未应用时给出退避延迟 `[500, 1000, 2000, 4000, 8000, 15000]` 毫秒；超出序列后维持在最后一个值。**刻意不设放弃点**——放弃会让同一个 Bug 以更慢的形式重现。
- `BridgeAppModel.startHIDMonitors` 是三条调用路径（`applyHIDSettings` 与两处语音模式切换）的唯一汇聚点，重试只在此处接入：失败排程重跑 `applyHIDSettings`，成功归零退避计数。
- 取消条件：`stop()`、自定义映射关闭、遥控器断连、重入 `startHIDMonitors`。重试任务执行时会二次校验前置条件。
- 新增 `HID MAPPING RETRY scheduled/attempt/abandoned` 日志。
- 修正 `HIDRemoteMonitor.swift:167` 的歧义日志：原先 `mappingEnabled=false` 与 `powerKeySuppressed=false` 打印同一条内容，本次排查因此无法从日志区分，只能靠读 UserDefaults 排除。现同时打印两个实际入参。

未改动 `RemoteVoiceFunctionMapper` 的返回语义，也未放宽 `HIDPermissionGate` 的任何门禁条件。

## 验证

修复前：新增测试无法编译（`cannot find 'HIDMappingRetryPolicy' in scope`），确认测试确实依赖本次修复。

修复后：

- `swift test`：247 项测试、21 个 suite 全部通过（新增 3 项）；
- `./scripts/test.sh`：42 项项目自检通过；
- `swift build` 与 `swift build -c release`：通过；
- `./scripts/check-repository-boundaries.sh`：通过。

新增测试覆盖：原始故障组合（开启 + 已连接 + 未应用）必须给出重试延迟、成功后不重试、关闭映射不重试、断连不重试、退避严格递增、越界后维持最后延迟、负数夹紧，以及 `BridgeAppModel` 确实从汇聚点接入并在 `stop` 取消。

## 自动化与真机边界

单元测试只覆盖策略判定与源码接线。**以下均未验证**：

- 真实 RC003/RC001 隔夜休眠后重连，重试确实等到 HID 服务注册并使 `matched>0`；
- 重试期间按 `tv`/`menu` 的实际动作恢复时间；
- 遥控器在重试过程中再次断连时退避正确终止；
- 退避上限 15 秒对真实枚举耗时是否足够。

这些必须按 [`Testing/HIDMappingReadinessRetry.md`](../Testing/HIDMappingReadinessRetry.md) 完成真机验收后才能认为本 Bug 关闭。当前只能确认自动化边界通过。
