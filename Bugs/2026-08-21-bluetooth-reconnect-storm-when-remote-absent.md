# 遥控器不在范围内时每小时 317 次蓝牙重连

- 编号：A4
- 时间：2026-08-21
- 状态：已修复，自动化通过；**真机未验收**
- 影响范围：所有安装，任何遥控器离开蓝牙范围的时间段
- 功能点：`XiaomiBluetoothBridge` 连接周期、`CBCentralManager` 生命周期

## 复现与现场证据

触发条件极其普通：**已登记遥控器，App 常驻运行，遥控器关机或被带离蓝牙范围**（下班回家、遥控器没电）。不需要任何用户操作。

证据来自 A3 备份的真实日志 `~/Desktop/remote-mic-audit-evidence/runtime.log.1`，跨度 `2026-08-10T11:16:14Z` → `2026-08-21T15:55:46Z`（约 11.2 天），共 113242 行。

| 消息 | 行数 |
| --- | --- |
| `BLE CONNECTING` | 21675 |
| `BLE CONNECT TIMEOUT` | 21329 |
| `BLE CONNECTED` | 118 |
| `BLE READY` | 116 |
| `BLE CONNECT FAILED` | **1** |

**21675 次连接尝试里 21329 次（98.4%）以 App 自己的超时收场，而 CoreBluetooth 在整整 11 天里只报告过 1 次真正的连接失败。** 也就是说系统从未放弃，是 App 主动取消了 21329 次待连请求。

来源分布确认这不是扫描路径的问题：

```text
21671 source=target_identifier
    2 source=scan
    1 source=connected_peripheral
    1 source=saved_identifier
```

按小时分桶，峰值 318 次/小时，长时间稳定在 317 次/小时（183 个不同小时有连接尝试）：

```text
318 2026-08-12T19
318 2026-08-12T16
317 2026-08-20T12
317 2026-08-13T00
...
```

节奏与代码里的常量完全对得上：

```text
2026-08-12T19:00:00Z BLE CONNECTING source=target_identifier name=小米蓝牙语音遥控器
2026-08-12T19:00:08Z BLE CONNECT TIMEOUT        ← +8 s，startConnectionTimeout
2026-08-12T19:00:11Z BLE CONNECTING             ← +3 s，finishAttempt(reconnectAfter: 3)
2026-08-12T19:00:19Z BLE CONNECT TIMEOUT
2026-08-12T19:00:22Z BLE CONNECTING
```

对 `2026-08-12T15`–`19` 共 1587 次尝试统计相邻间隔，只有两种取值：11.0 s（1038 次）与 12.0 s（548 次），平均 11.35 s，即 317.2 次/小时。日志时间戳只有秒级精度，多出的约 0.35 s 是派发与 CoreBluetooth 调用开销。

正常行为边界：遥控器在范围内时一切正常（118 次 `BLE CONNECTED` 中 116 次走到 `BLE READY`），语音、按键、音频都不受影响。问题只在"遥控器不在"这一段时间。

## 日志结论

日志能确认的：尝试次数、11–12 秒的固定节奏、超时全部由 App 发起、来源是 `target_identifier`（已保存的遥控器）。

日志**不能**确认的：这些尝试实际消耗了多少电量或射频时间。日志里没有功耗数据，本文档不对省电幅度做任何量化声明。

## 根因

`Sources/RemoteMic/XiaomiBluetoothBridge.swift` 把一个由硬件驱动的免费等待，改成了 App 自己的忙等轮询。循环由五步构成：

1. `beginConnectionCycle()` 在 `central == nil` 时**新建一个 `CBCentralManager`**。
2. `discoverOrScan(using:generation:)` 用 `retrievePeripherals(withIdentifiers:)` 找到已保存的遥控器并 `connect(...)`。
3. `connect(...)` 先 `startConnectionTimeout(generation:)` 再 `central.connect(candidate, options: nil)`。
4. `startConnectionTimeout` 在 **8 秒**后打印 `BLE CONNECT TIMEOUT`、`cancelPeripheralConnection`，然后 `finishAttempt(reconnectAfter: 3)`。
5. `finishAttempt` 把 central 整个拆掉（`central?.delegate = nil; central = nil`），3 秒后再回到第 1 步。

`CBCentralManager.connect(_:options:)` **按设计就没有超时**：待连请求会一直留在蓝牙控制器里，等外设回到范围时由控制器完成，App 不轮询、不重复付射频代价。正确实现是"一个长期存活的 central + 一个挂着的 `connect()`"，用户走回来时自己就连上了。

因此这不只是日志噪音，而是两个实质缺陷：

- **把免费等待换成了忙等**：每 11 秒一次取消 + 重建 central + 重新 connect。
- **存在真实的连接空窗**：第 4 步取消到第 1 步重建之间有 3 秒没有任何待连请求，且每次都换一个新的 `CBCentralManager`。遥控器如果恰好在这个窗口出现，这一轮就会被漏掉。

## 修复

最小改动，只针对已确认根因。共三处实质修改加一处命名。

**1. 一个 central 活到桥的生命周期结束。** `beginConnectionCycle` 改为复用 `central ?? CBCentralManager(...)`，`CBCentralManagerOptionShowPowerAlertKey: true` 原样保留。`finishAttempt` 不再销毁 central；只有不再重试的路径（即 `stop()`）才调用新增的 `releaseCentral()`。

原来的 `guard shouldRun, central == nil` 同时承担了重入保护——`central == nil` 恰好等价于 `lifecycle ∈ {.stopped, .waitingReconnect}`，因为只有 `finishAttempt` 会把 central 置空并留下这两种相位。central 现在跨周期存活，该等价关系失效，所以改成显式相位判断 `hasConnectionCycleInFlight`。这保住了"已连接时再次 `start()` 不会踢掉现有连接"的行为。

**2. 时间流逝不再取消待连请求。** `startConnectionTimeout` 改名 `startPendingConnectDeadline`，行为由新增的纯策略 `BluetoothReconnectPolicy` 决定。策略返回 `nil` 时只做两件事：把显示状态改成 `.reconnecting`、写一行 `BLE CONNECT PENDING waiting_for_remote`。**待连请求、`peripheral` 引用、`.connecting(generation)` 相位全部不动**——相位保持 `.connecting` 正是后来 `didConnect` 仍被 `acceptsDidConnect` 接受的前提。

**3. 保留真正承重的超时。** `startInitializationTimeout` 完全不动：它守的是**连接成功之后**的服务发现与能力握手，一个连上却卡住的外设否则会永久挂着。只有连接前的超时是缺陷。

**4. 真实失败路径仍然重试。** 搜过全文件所有 `finishAttempt` / `scheduleReconnect` / `beginConnectionCycle` 的调用点：`didFailToConnect`、`didDisconnectPeripheral`（两个重载）、`handleDisconnect`、`failInitialization`、`rejectUnsupportedAudio`、服务/特征/订阅失败，全部继续经由 `scheduleReconnect` 或 `finishAttempt` 在 3 秒后开新一轮。硬编码的 `3` 统一改为 `BluetoothReconnectPolicy.failureRetryDelay`，让重试节奏只有一个来源。

### `stop()` 与 `reconnectNow()` 改为确定性

这两处原来的写法是：如果 `peripheral.state != .disconnected` 就只发 `cancelPeripheralConnection` 然后 `return`，靠断连回调再走到 `finishAttempt`。

对一个**从未连接成功**的待连请求，`cancelPeripheralConnection` 不保证产生任何 delegate 回调。修改前待连窗口最长 8 秒，撞上的概率低；修改后待连状态可能持续数小时，这就成了现实风险：`stop()` 可能永久留着 central，`reconnectNow()` 可能永久卡在 `.disconnecting`。

两处都改成"请求取消后立即落到 `finishAttempt`"：`stop()` 走 `finishAttempt(reconnectAfter: nil)` → `releaseCentral()`，同步释放，不留待处理项；`reconnectNow()` 走 `finishAttempt(reconnectAfter: 0.1)`，0.1 秒后必定开新周期。迟到的 `didFailToConnect` 会被 `isCurrent(peripheral)` 挡掉（此时 `peripheral` 已为 nil），不会重复调度。

### 复核补充：唤醒与授权状态必须重新发起

独立复核否决了第一版，理由成立：被删掉的 8 秒循环同时也是**睡眠唤醒后唯一的自愈机制**。

`installWorkspaceWakeObserver`（`RemoteMicApp.swift:244`）原来只刷新两项权限。修改前，睡眠期间待连请求即使被系统丢掉且没有任何 delegate 回调，唤醒后那个无条件的 8 秒 `asyncAfter` 也会到期并在约 11 秒内重建整条链路。改成永久待连之后，这条隐式自愈路径消失了：桥会停在 `.connecting(g)` 且零待处理项，只能靠用户点「立即重连」。而"隔夜回来"正是这个功能存在的理由。现在唤醒时额外调用 `model.reconnect()`（该方法本身 `guard started`，并分发到各桥的 `reconnectNow()`），代价是每次唤醒 1 次尝试，而不是每小时 328 次。

同一轮复核还发现 `centralManagerDidUpdateState` 的 `.unauthorized` 分支只调 `resetSession()`，把 `lifecycle` 留在 `.connecting(g)`。此后即使状态回到 `.poweredOn`，`discoverOrScan` 的 `lifecycle == .scanning(generation)` 断言也不成立，桥就死了。改前靠 8 秒超时自愈，改后不会。该分支已与 `.poweredOff` / `.resetting` 对齐：`resetPeripheral()` + `lifecycle = .scanning(generation)`。

**一项已接受的代价**（复核指出，不作为否决项）：复用同一个 central 之后，`self.central === central` 不再区分 generation，而 CoreBluetooth 会复用同一个 `CBPeripheral` 实例。因此 `reconnectNow()` 取消再于 0.1 秒后重连时，上一代迟到的 `didDisconnectPeripheral` 有可能被新一代接受。后果是多走一轮 3 秒重试，可自愈，不会卡死；改前靠置空 delegate 排除这种情况。没有为它加 generation 校验，因为代价小于新增一层状态。

### 界面不说假话

修改前是那个 8 秒超时把显示状态从 `.connecting` 翻到 `.reconnecting` 的。现在 8 秒的信息性截止时间做同一件事，只是不再动连接请求，所以用户不会一直盯着「正在连接遥控器」。

**没有新增任何用户可见字符串**：复用已有的 `connection.status.reconnecting`（「连接断开，准备重连」/「Connection lost; preparing to reconnect」），也就是修改前在同一时刻显示的同一条文字，界面行为差异为零。措辞对"从未连上就在等"的场景略有偏差，但现场主流场景确实是"本来连着，用户走了"，且改字符串会牵动双语文案与 `LocalizationTests`，不属于本次根因范围。`BluetoothBridgeState` 的消费方 `BridgeAppModel.refreshBluetoothPresentation` 与 `bluetoothBridge(_:didChange:)` 对 `.reconnecting` 的处理也完全没变（同样是非 ready 分支）。

### 为什么策略是一个两个 case 的枚举

`BluetoothReconnectPolicy` 放在 `Sources/RemoteMic/BluetoothLifecycle.swift`，紧邻 `BluetoothLifecyclePhase` 与 `ATVVSessionGate`，形态对齐 `RemoteButtons.swift` 里的 `HIDMappingRetryPolicy`：纯类型、零依赖、单元测试直接驱动。该文件同时被 `swift test` 与 `scripts/test.sh` 编译。

生产代码消费 `retryDelayAfterPendingConnectDeadline()` 的返回值并处理 `nil` 与非 `nil` 两种答案，而不是把结论硬编码——这与 `HIDMappingRetryPolicy.retryDelayMilliseconds` 返回 `UInt64?`、生产代码两种都处理的既有形态一致。`.restartAttempt(retryDelay:)` 这个 case 因此既是修改前行为的文档，也是回归测试的基线输入：测试用它算出"修改前"的数字，这个数字才是从真实延迟推导出来的，而不是从本文档抄的。

## 修复前后对比

`Tests/RemoteMicTests/BluetoothLifecycleTests.swift` 里的 `authorizedConnectAttempts(policy:remoteAbsentFor:)` 沿一条时间线走钟，每次推进都取自策略声明的延迟，统计策略授权了多少次 `connect()`。

| 缺席时长 | 修改前 `.restartAttempt(retryDelay: 3)` | 修改后 `.keepOutstandingRequest` |
| --- | --- | --- |
| 1 小时 | **328** | **1** |
| 24 小时 | **7855** | **1** |

修改后与缺席时长无关：请求已经交给蓝牙控制器，不需要第二次 `connect()`。

理论值 328/小时（8 + 3 = 11 s 一轮）与真实日志实测的 317–318/小时的差异，来源是日志秒级时间戳下相邻间隔为 11 s 与 12 s 两种取值，平均 11.35 s；多出的约 0.35 s 是派发与 CoreBluetooth 调用开销。两个数字互相印证，本文档同时保留。

**负向对照**：把 `pendingConnect` 改回 `.restartAttempt(retryDelay: 3)`，`swift test --filter BluetoothLifecycleTests` 退出码 1，`anAbsentRemoteCostsOneConnectAttemptInsteadOfHundredsPerHour` 报 3 个 issue（1 小时计数、24 小时计数、`retryDelayAfterPendingConnectDeadline()` 非 nil）。改回后重跑退出码 0、8 项通过。测试确实在测行为，不是恒真断言。

## 验证

每条命令单独执行，输出重定向到文件后单独取退出码（不经 `tail`/`head` 管道，避免读到分页器的状态）。

```text
$ swift build                                  → 退出码 0（Build complete!）

$ swift test                                   → 退出码 0
  ✔ Test run with 283 tests in 24 suites passed after 18.040 seconds.

$ ./scripts/test.sh                            → 退出码 0
  RESULT passed=42 failed=0

$ ./scripts/check-repository-boundaries.sh      → 退出码 0
  REPOSITORY BOUNDARY PASS
```

关于测试项数的准确归属：本会话开始时基线为 **277 项 / 24 套**，但同一工作区有另一个代理在并行处理 A6（HID 静默返回），期间它自己新增了 4 项测试，因此原始总数在本项进行中发生了变化。为隔离本项贡献，把本项三个改动文件单独 stash 后重跑：

| | 项数 | 套数 |
| --- | --- | --- |
| 仅去掉本项改动 | 281 | 24 |
| 含本项改动 | 283 | 24 |

差值 **+2**，与本项新增的两项测试一致；套数不变，未删除或弱化任何既有测试。复核时如果看到的总数不是 283，应先确认 A6 的改动进度。

新增两项测试，均为行为测试，不含"源码里还存在某段文字"式断言：

- `anAbsentRemoteCostsOneConnectAttemptInsteadOfHundredsPerHour`：上表两种策略、两种缺席时长的授权次数。
- `aGenuineFailureStillBuysAFreshAttempt`：真实失败路径仍按 `failureRetryDelay` 持续重试（60 秒内 21 次），修复不会造成死桥。

未执行打包脚本：本次不涉及打包。

四项分支特有行为未被本次改动触及（改动只在 BLE 连接生命周期），对应测试套在上述 279 项内全绿：语音键触发键可配置、外接麦克风采集、右侧修饰键不粘滞、自定义快捷键左右保真。

## 自动化与真机边界

**没有真机验收。本次修改完全没有在真实遥控器上跑过——本会话没有硬件访问权限。任何"已完成真机验收"的表述都是错的。**

自动化只覆盖 `BluetoothReconnectPolicy` 的纯决策：给定缺席时长，策略授权多少次 `connect()`。它**不驱动真实 CoreBluetooth 回调**，本仓库也没有可注入的 CoreBluetooth 事件回放设施（没有任何测试实例化 `XiaomiBluetoothBridge`）。

因此以下各项**均未验证**：

1. **核心假设**：遥控器回到范围时，蓝牙控制器真的会完成那个挂了几小时的待连请求。依据只是 `CBCentralManager.connect(_:options:)` 的公开文档语义，没有本项目的真机证据。**这是整个修复成立与否的前提，必须由真机用例验收。**
2. 真机上每小时实际的 `BLE CONNECTING` 行数是否真的降到 1。
3. 长时间挂起的待连请求在 macOS 睡眠/唤醒、蓝牙关开、系统蓝牙栈重启后是否仍然有效。
4. 待连期间 `stop()` 是否真的没有留下系统层面的连接请求。
5. 待连期间点击「立即重连」后能否可靠开新周期（代码上已改为确定性，但未经真机）。
6. `didFailToConnect` 在真机上不会高频触发——日志 11 天只有 1 次，样本极小。
7. 省电幅度。日志里没有功耗数据，本文档不做量化声明。

真机测试手册：[`Testing/BluetoothAbsentRemoteReconnect.md`](../Testing/BluetoothAbsentRemoteReconnect.md)，用例 1–7 全部待验收，其中用例 2 是第 1 项假设的唯一验收手段。

## 已知未处理项

- **扫描路径没有任何截止时间**。`targetIdentifier == nil` 的发现型桥进入 `scanForPeripherals` 后如果什么都没找到，会一直扫描下去（持续扫描本身有射频代价）。这是修改前就有的行为，日志也证实本次缺陷走的是 `target_identifier` 路径（21671/21675），因此不在本项范围内。
- **真实失败仍是固定 3 秒重试**，没有退避。如果某台机器上 `didFailToConnect` 会立刻反复触发，就是 1200 次/小时——比修复前更差。日志里 11 天只有 1 次，暂不认为是现实问题；修改前同样是 3 秒，本项未引入回归。真要加退避应另开一项。
- `connection.status.reconnecting` 的措辞对"从未连上就在等"的场景不够准确，未改（见上文）。
