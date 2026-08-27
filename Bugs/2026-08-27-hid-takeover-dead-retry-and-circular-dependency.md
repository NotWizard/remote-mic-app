# 遥控器长时间休眠重连后按键接管失效（第二次报告，上一次的修复是死代码）

- 时间：2026-08-27
- 状态：已修复，自动化通过；真机验收未完成
- 影响范围：所有启用自定义按键映射的用户。`1.8.17`、`1.8.25-fork.1` 报告过，`1.8.25-fork.5`（含上次修复）**仍然复现**
- 功能点：BLE 就绪后写 HID 映射、`HIDRemoteMonitor` 启动门禁、映射重试
- 简单描述：遥控器长时间不用后重连，全部自定义按键失效并退回系统原生行为，重启 App 才恢复。上一次为此加的退避重试**从未执行过一次**。

## 复现

用户现场（`1.8.25-fork.5 (124)`）：

1. 遥控器长时间不使用，蓝牙断开。
2. 重新连接。
3. 按任意已配置按键。

错误行为：按键执行 macOS 原生行为，自定义动作全部不生效，当天不会自行恢复。
正常行为边界：语音键不受影响（走 BLE/ATVV，不经 HID 监听）；用户配置未丢失；重启 App 或切换设置即恢复。

## 日志结论

日志：`~/Library/Logs/RemoteMic/runtime.log`。2026-08-27T05:42:12Z 的三行，**顺序是关键**：

```text
05:42:12Z VOICE FN MAPPING applied=false neutralized=false power_suppressed=false matched=0
05:42:12Z HID START rejected reason=power_key_not_suppressed mapping_enabled=true power_suppressed=false
05:42:12Z BLE READY name=小米蓝牙语音遥控器
```

`matched=0` 表示枚举 IOHID 服务时一个都没找到，即遥控器的 HID 服务尚未注册完——这是**瞬时状态**，不是结论。

决定性证据：整份日志里**没有任何 `HID MAPPING RETRY` 行**。上一次修复新增的退避重试（`Bugs/2026-08-21-remote-reconnect-loses-custom-button-mapping.md`）本该在被拒后立刻排程。`strings` 检查确认该修复确实编译进了正在运行的二进制（命中 `HID MAPPING RETRY` 3 次），所以不是版本问题。

对照：2026-08-26T05:38:29Z 那次恢复了，但靠的是巧合——第一次 `matched=0` 之后，另一条与重试无关的路径又调了一次 `applyHIDSettings`，那时连接状态已经发布为 true，于是 `matched=1`。

## 根因

两层，缺一不可。

### 第一层：决策读到了陈旧的已发布状态

`bluetoothBridge(_:didChange:)` 的 `.ready` 分支里先调 `applyHIDSettings()`，而唯一给 `isConnected` 赋值的 `refreshBluetoothPresentation()` 在同一方法的**末尾**才执行。因此 `applyHIDSettings` 运行期间 `isConnected` 仍是上一轮的值；长时间断开后重连时该值为 `false`。

`scheduleHIDMappingRetryIfNeeded` 用它作为 `remoteConnected` 传入 `HIDMappingRetryPolicy`，而策略要求 `guard mappingEnabled, remoteConnected, !mappingApplied`（`RemoteButtons.swift`）。于是返回 nil、不排程、并把 `hidMappingRetryAttempts` 归零。日志中一条重试都没有，正是这个。

全仓 16 处 `isConnected` 读取中，只有重试判定这一处发生在 refresh 之前；视图层 9 处在渲染时读，长录音门禁 2 处由用户主动触发，`didChange` 内另一处位于 refresh 之后。所以受影响的消费方只有一个。

### 第二层：循环依赖，使唯一可靠信号不可达

`HIDRemoteMonitor.start()` 原本要求 `HIDPermissionGate.canMonitor(... powerKeySuppressed:)` 通过，才会走到 `IOHIDManagerCreate` 与 `IOHIDManagerRegisterDeviceMatchingCallback`。

而 `powerKeySuppressed` 来自 `RemoteVoiceFunctionMapper.apply` 的枚举结果。也就是说：

**映射写入失败 → 监听器提前返回 → 不创建 IOHIDManager → 不注册「设备出现」回调 → 没有任何事件能告知 HID 服务已就绪 → 只能靠轮询。**

而轮询又被第一层掐死。BLE 连接完成与 HID 服务注册是两条互不相关的时间线，用其中一条轮询另一条本身就是碰运气；把唯一的事件源挡在门后，则连兜底都没有了。

## 修复

### 打破循环（治本）

- 新增 `HIDPermissionGate.canObserve(mappingEnabled:inputMonitoringGranted:accessibilityGranted:)`，**不含** `powerKeySuppressed`。`start()` 改用它作为开 manager 的门禁，权限语义不变。
- 开关机键未接管不再拒绝整个监听器，只写一行 `HID START power_key_pending` 并继续。
- `deviceDidMatch` 在解析出指纹后、**在所有采纳门禁之前**触发新的 `onDeviceAppeared`——映射写入只需要 HID 服务存在，与本监听器是否采纳该设备无关。
- `BridgeAppModel` 收到该回调后重跑 `applyHIDSettings()`，这一刻设备确实存在，`matched>0` 是有保证的而非猜测。

### 安全代偿

监听器现在可能在开关机键仍具原生行为时运行。`process(usages:)` 因此在 `!powerKeySuppressed` 时跳过 `.power` 并记 `reason=power_key_not_neutralized`——否则按开关机键会同时触发自定义动作和 macOS 休眠/锁屏。其余按键照常接管。

由此附带修正了一个错误的影响范围：**原先一个只涉及开关机键的失败会连带禁用全部按键**，这正是用户「所有按键都失效」的直接原因。

### 防重入与防死循环

初版让「设备出现」直接重跑 `applyHIDSettings()`，被独立审查 VETO，理由成立：

- `applyHIDSettings` → `startHIDMonitors` → `stopHIDMonitors()` 会销毁**正在栈上执行 `deviceDidMatch` 的那个监听器**；控制流返回后它继续走到 `IOHIDDeviceOpen(...SeizeDevice)`，于是一个已无人持有的对象独占了设备，且 `HIDRemoteMonitor` 当时没有 `deinit`，这个句柄永不释放。新建的监听器随后打不开设备（`allowManagerFallback: false`），结果是**全部按键彻底失灵**——比原 Bug 更糟。
- 退避到顶后保持 15 秒一次且不放弃，意味着上述重启会**每 15 秒重复一次，永远**：一个原先不存在的周期性断连。

改为新增 `retryPowerKeyMappingWrite(reason:)`：只重跑映射写入，成功后用 `updatePowerKeySuppressed(_:allowedLocationIDs:)` 就地更新已在运行的监听器，**不重启任何东西**。既然不重启，就不会重新投递已存在的设备，也就不存在重入与死循环，初版为此加的 latch 一并删除。同时给 `HIDRemoteMonitor` 补了 `deinit { stop() }`：回调上下文是 `Unmanaged.passUnretained(self)`，管理器活得比对象久就是 use-after-free，这是本就存在的潜在缺陷，只是原先门禁挡着不开管理器而窗口很小。

### 开关机键的按下与松开必须成对

初版在按键循环里 `continue` 跳过 `.power`，但 `activeUsages = usages` 在跳过判断**之前**执行，于是松开时仍会 `eventSuppressor.arm(button: .power, edge: .up)`，把 key-up 吞掉——而 key-down 是故意留给 macOS 的。审查指出后改为在进入 `activeUsages` 之前就把 power usage 从集合中滤除，`onActiveButtons` 也不再把它报成按下。

### 永久失败必须说出来

`button_mapping.error.power_suppression_failed` 在改动后一度无人引用，意味着一个永远无法成功的写入会永久显示「仍在接管中」。现在退避次数超出延迟表长度后即改用该文案。

### 修活兜底

新增私有计算属性 `hasReadyBluetoothBridge`（直接读 `bluetoothBridgeStates`）。重试判定与 `refreshBluetoothPresentation` 发布 `isConnected` 都读它，`isConnected` 退化为纯镜像，两者不可能分叉。**不采用**「把 refresh 挪到前面」的方案：refresh 必须排在 `registerBluetoothBridgeIfNeeded` 之后，否则桥尚未进入 `bluetoothBridges`，`connectedRemoteProfileIDs` 会算成空，界面反而显示未连接——那是拿一个陈旧状态缺陷换另一个。

### 可见性

监听器在开关机键待接管时启动，若沿用原有状态文案会显示成普通「已连接」，用户无从得知开关机键仍是原生行为。新增 `button_mapping.status.connected_power_key_pending`（中英文），`activateDevice` 的 seize 与 monitored 两条路径都据此上报。

## 已知并接受的代价

映射写入失败时 `powerSuppressedLocationIDs` 为 nil，`isLocationAllowed` 因此放行所有 location。原先监听器在该状态下根本不启动，现在会启动，所以理论上可以采纳一个位置未经验证的同 VID/PID 设备。判断：location 白名单的用途是界定**开关机键接管范围**，而开关机键已改为逐次跳过；其余按键在未验证位置上被接管，与成功路径上的行为一致。未新增限制，因为没有证据表明存在需要区分的真实场景。此项无测试覆盖。

## 测试缺口的修补

上一次修复能带着缺陷全程绿灯，是因为唯一的测试直接调用纯函数 `HIDMappingRetryPolicy` 并手动传 `remoteConnected: true`，从未驱动真实调用顺序。`voiceFunctionMapper` 是 `private let`，无法注入，也就无法构造 `matched=0`。

本次把它改为带默认值的 init 参数作为测试注入点，新增 `Tests/RemoteMicTests/HIDMappingRecoveryTests.swift` 四项：

1. **回归本体**：注入一个服务列表为空的 mapper（等价于 `matched=0`），驱动 `didChange(.ready)`，断言必须出现 `HID MAPPING RETRY scheduled attempt=1 delay_ms=500`；
2. `canObserve` 不得考虑开关机键接管结果，但仍受两项权限与映射开关约束；
3. 恢复路径**不得重启监听器**：连续 10 次重跑后 `HID START` 行数必须不变（该行每次 `start()` 写一次，因此它就是重启计数器），且仍要留下 `HID MAPPING WRITE pending` 记录；
4. 写入成功后必须收尾：出现 `HID MAPPING WRITE applied`、不再排程重试，且第二次调用是空操作。

## 本次改动引起的测试稳定性问题（已解决）

改动放开了「写入失败时不开管理器」这道门，于是测试进程里会真的创建 CGEvent tap 与 IOHIDManager。`swift test` 随即变成间歇崩溃（EXC_BAD_ACCESS）。

不靠猜：从 `~/Library/Logs/DiagnosticReports` 取到崩溃栈，faulting 帧是 `keyboardEventSuppressorCallback` → `swift::RefCounts::incrementSlow`，触发点是另一个跑真实 NSRunLoop 的用例（`SettingsPageRenderingTests` → `SettingsScreenshotRenderer.renderAll`）。即：某个用例留下了已武装的事件 tap，而 tap 的回调上下文是 `Unmanaged.passUnretained`，对象释放后回调打进已释放内存。

定位到 `RemoteButtonsTests.startRejectionNamesWhichBranchStoppedButtonMapping`：它是唯一调用 `start()` 的用例，传 `runtimePermissions: { true }` 但 `ownsEventSuppressor: false`，于是拿到一个默认抑制器却不负责停它。改动前 `start()` 在门禁处提前返回，永远走不到建 tap；改动后走到了。

三项处置：

- 该用例改为 `ownsEventSuppressor: true`，自己创建的东西自己释放；
- `BridgeAppModel.init` 新增可注入的 `hidRuntimePermissions`（默认即原有的两项系统探测），并透传给它创建的每个监听器；9 处不涉及 HID 的现有测试改为注入 `{ false }`，从此不再触碰真实系统资源；
- `startHIDMonitors` 中启动共享 tap 也改为受同一探测约束——没有权限时监听器根本不会跑，那个 tap 只是空转且回调上下文比创建者活得久。

`HIDRemoteMonitor.start()` 现在以注入的 `runtimePermissions()` 为准而非直接读静态量。其默认值本就等于那两项探测之与，真机行为不变。

## 验证

反向验证：仅把重试判定改回读 `isConnected`，回归测试立即变红，失败信息 `HID MAPPING RETRY scheduled → 0`——与现场日志「一条重试都没有」同形。随后按 `shasum -a 256` 确认源文件逐字节还原（`ad89c5b5…`）。

稳定性验证（因为改动一度让套件不可信，所以单独跑够次数）：

| 代码 | 全量 `swift test` | 结果 |
| --- | --- | --- |
| 改动前 | 3 次 | 3/3 通过，400 项 |
| 初版改动 | 5 次 | 1/5 通过，其余 SIGSEGV/SIGBUS |
| 最终改动 | 8 次 | 8/8 通过，404 项 |

其余门禁：`./scripts/test.sh` 42 项通过；`./scripts/check-repository-boundaries.sh` 通过；`swift build -c release` 通过。

现有测试 `startRejectionNamesWhichBranchStoppedButtonMapping` 的契约随之变化，已同步更新而非放宽：开关机键未接管不再是「拒绝」，但仍必须留下 `HID START power_key_pending` 记录。断言写成「因权限被拒」与「留下待定记录」二者**恰好成立其一**，因此静默和两者同时成立都会失败——初版曾用 `#expect(!sink.lines.isEmpty)` 兜底，那条永远不可能失败（`HID PERMISSIONS` 总会先写一行），已由审查指出并改掉。

`HIDPermissionGate.canMonitor` 在生产代码中已无人调用，连同 `RemoteButtonsTests` 与 `Tests/SelfTest` 中对它的断言一并改为 `canObserve`——留着一个没人问的门禁，只会邀请后人把循环依赖重新加回去。

## 自动化与真机边界

单元测试驱动的是 `BridgeAppModel` 的委托回调与注入的 mapper，**没有真实 CoreBluetooth，也没有真实遥控器 HID 服务的注册时序**。以下均未验证：

- `deviceDidMatch` 触发的那一刻，`RemoteVoiceFunctionMapper` 的服务枚举是否一定 `matched>0`。两者查的是同一套 IOHID 服务，理论上一致，但**这是本次修复成立的核心假设，且完全未经真机检验**；
- 真实长时间休眠重连后，按键是否确实立即恢复，以及恢复耗时；
- 开关机键从「待接管」到接管成功的实际延迟，期间按它是否真的既不触发自定义动作也不触发系统休眠；
- 退避上限 15 秒对真实 HID 枚举耗时是否足够（仍是日志推断值，从未测量）；
- 新增状态文案在 1020×772 生产窗口与菜单栏中的实际显示是否截断。

真机验收按 [`Testing/HIDTakeoverRecoveryAfterIdle.md`](../Testing/HIDTakeoverRecoveryAfterIdle.md) 执行，完成前不得认为本 Bug 关闭。
