# 连接页出现无法删除的幽灵遥控器卡片

- 时间：2026-08-25
- 状态：已修复，自动化通过；真机验收未完成
- 影响范围：附近存在其他小米遥控设备（或同一只遥控器出现第二个 BLE 身份）的用户；用户现场为 `1.8.25-fork.4`，但幽灵条目本身早于该版本
- 功能点：BLE 连接回调向 `remoteDeviceProfiles` 落盘设备档案
- 简单描述：连接页出现两张遥控器卡片，一张是真实遥控器，另一张永久显示为「小米遥控器」且无型号无电量。界面没有删除设备的入口，该卡片无法清除。

## 复现

用户现场（`1.8.25-fork.4`，`/Applications/Remote Mic.app`）：

1. 打开设置的连接页。
2. 观察遥控器卡片列表。

错误行为：出现两张卡片，「小米蓝牙遥控器 2」（真实遥控器，打勾选中）与「小米遥控器」（永久存在，电量显示 `—`）。

正常行为边界：语音、按键映射、音频链路均正常；用户配置未丢失。点击幽灵卡片会通过 `selectRemoteProfile` 把当前映射切换到那份独立配置，看起来像设置丢失，但两份配置各自完好。

## 日志与存储结论

存储（`defaults export com.hd838a.RemoteMic` → `remoteDeviceProfiles`）确认确实是两条持久化档案，而不是渲染重复：

| id 前缀 | model | bluetoothIdentifier | hidFingerprint |
| --- | --- | --- | --- |
| `42FA1DE7` | `rc001` | `F4812B1C…` | 已绑定 |
| `6AA1224D` | `unknown` | `0D4C74C3…` | 无 |

`selectedRemoteProfileID` 指向 `42FA1DE7`。显示名来自 `SettingsView.swift:1452` 的 `profile.displayNameFallbackKey`，`remote.device.model.unknown` 在中文串表中就是「小米遥控器」（`Resources/zh-Hans.lproj/Localizable.strings:184`），所以第二张卡片是**型号未知**的档案，不是第二种型号。

日志：`~/Library/Logs/RemoteMic/runtime.log` 与 `runtime.log.1`。

两份日志中除真实遥控器外，只出现过一个第二设备，广播名为 `MI RC`：

```text
2026-08-10T11:20:56Z BLE CONNECTING source=scan name=MI RC
2026-08-10T11:20:56Z BLE CONNECTED name=MI RC
2026-08-10T11:21:05Z BLE DISCONNECTED phase=disconnecting(1) cached_identifier_cleared=false error=none
2026-08-23T06:51:33Z BLE CONNECTING source=scan name=MI RC
2026-08-23T06:51:33Z BLE CONNECTED name=MI RC
2026-08-23T06:51:42Z BLE DISCONNECTED phase=disconnecting(2) cached_identifier_cleared=false error=none
```

`MI RC` 在 `XiaomiVoiceRemoteNameMatcher.approvedNames`（`BluetoothLifecycle.swift:5`）白名单内，所以常驻发现桥（`BridgeAppModel.startBluetoothDiscoveryIfNeeded`）会主动连它。两份日志中**没有任何一条 `BLE READY name=MI RC`**，`BLE MODEL identified=` 全程只出现一次且为 `rc001`，与 `model=unknown` 的第二条档案一致。

真实遥控器的正常连接次序（同一份日志，今日）确认了关键时序——电量和型号都在 `BLE READY` **之前**到达：

```text
01:44:54Z BLE CONNECTED name=小米蓝牙语音遥控器
01:44:54Z BLE BATTERY level=73
01:44:54Z BLE MODEL identified=rc001
01:44:54Z BLE READY name=小米蓝牙语音遥控器
```

**未能确认的部分**：可用日志起始于 `2026-08-10T11:16`，`MI RC` 的两次连接窗口内没有任何电量、电源、型号或就绪记录，因此**无法证明**这两次就是创建 `6AA1224D` 的那一次；该档案可能更早产生。`MI RC` 是另一只实体遥控器，还是同一只遥控器未绑定状态下的第二个 CoreBluetooth 身份，也无法从日志判定（两次相隔 13 天复用同一个 peripheral 身份，更像独立设备，但这是推断）。下文根因是对**机制**的确认，不是对该条具体档案来源的确认。

## 根因

落盘入口不止 `.ready` 一处。`remoteProfileID(for:)`（`BridgeAppModel.swift`）原本是：

```swift
return settings.profileID(forBluetoothIdentifier: identifier)
    ?? settings.registerBluetoothRemote(identifier: identifier)
```

即"查不到就建"。它的三个调用方是 `didUpdateBatteryLevel`、`didIdentifyRemoteModel`、`didUpdatePowerState` 三个纯读数回调，而上面的日志证明这些读数**先于** `.ready` 到达。于是任何通过名称白名单、连上并回答了一次电量读取的外设都会立刻留下一条持久化档案，之后即使 ATVV 握手从未完成、连接就此断开，档案也已经写进 `UserDefaults`。

由于型号只在 `didIdentifyRemoteModel` 写入，这类档案通常停在 `model = .unknown`，界面就退回「小米遥控器」这个兜底名。

放大后果的两点：

- `registerBluetoothRemote`（`AppSettings.swift:899`）只在存在"未绑定且型号未知"的空档案时复用槽位；真实遥控器早已占用该槽位，因此幽灵一定是 `append`，即新增一张卡片。
- 全仓没有任何 remove / delete / forget 设备档案的实现或文案，所以这张卡片一旦产生就无法从界面清除。

## 修复

只保留一个落盘入口，并保证不因此丢读数。

- `remoteProfileID(for:)` 改为纯查询，不再创建。
- 三个读数回调在档案尚不存在时，把值按 **peripheral identifier** 暂存进 `pendingRemoteBatteryLevels` / `pendingRemotePowerStates` / `pendingRemoteModels`。
- `registerBluetoothBridgeIfNeeded` 成为唯一创建点（由 `didChange` 的 `.ready` 分支与语音开始的 `activateRemoteProfile` 进入），落盘后立即调用新增的 `applyPendingRemoteTelemetry` 把暂存值补进 `remoteBatteryLevels` / `remotePowerStates` / `updateRemoteProfileModel`。

- 暂存表在桥离开就绪状态时（`didChange` 的非 `.ready` 分支）连同现存值一并清空；读数回调收到 `nil`（读取失败）时直接把对应键删除，而不是保留上一次成功值。

`.ready` 由 `confirmCapabilities`（`XiaomiBluetoothBridge.swift:501`）设置，前置条件是 ATVV 能力协商被接受，因此它等价于"这确实是一只小米语音遥控器"。

关于清空时机，最初的判断是错的，由独立审查推翻并已修正：原以为 `state = .discovering` 在 `requestCapabilities`（`:465`）中赋值、可能晚于电量读数，因此清空会丢合法读数。实际 `.discovering` 早在 `didConnect`（`:583`）就已赋值，且在 `discoverServices`（`:585`）之前，所有特征读取必然晚于它；而 `state` 的 `didSet` 有变化去重（`:152-157`），`:465` 的第二次同值赋值不会再次通知委托。所以清空不可能吃掉正在建立的这次连接的读数。不清空反而会留下一个真实缺陷，见下。

未放宽名称白名单，未改动 `registerBluetoothRemote` 的槽位复用语义，未新增删除设备的能力（现存的那张幽灵卡片不在本次修复范围内）。

## 审查发现并已修复的次生缺陷

暂存机制本身引入了一个过期数据回放路径，初版没有清空时确实成立：某外设上报电量 4%、握手失败、断开；数小时后同一外设握手成功，而这次电量读取失败（`didUpdateBatteryLevel(nil)`）。初版既不缓存 `nil` 也不让它作废已有暂存值，于是几小时前的 4% 和当时读到的 `rc001` 被刷到新建的卡片上。清空 + `nil` 作废两项修正共同关闭该路径，并各有一项测试与反向验证。

## 已知并接受的代价

- 真实遥控器若连上但 ATVV 初始化失败，现在完全不出卡片（此前会出一张型号未知的卡片）。连接状态仍由 `connectionStatus` 反映。
- 常驻发现桥的排除集合只包含 `bluetoothBridges` 的键（`BridgeAppModel.swift:1426-1429`），而该表在启动时由已持久化的档案填充。修复前幽灵档案会在下次启动时获得独立桥，从而把该身份从发现桥的候选中"退休"；修复后幽灵不再落盘，发现桥可能反复挑中它、初始化失败、重连、再挑中。**这不是锁死**：`finishAttempt`（`XiaomiBluetoothBridge.swift:411-434`）会 `resetPeripheral()` 后重新走 `beginConnectionCycle`，发现桥不会钉在该外设上，真实新遥控器仍可能在后续扫描中被选中，代价是首次配对可能变慢。真实失败率未测量，因此**刻意不加**失败身份退避——在没有真机数据前，一个过于激进的退避会把偶发初始化超时的真实遥控器锁在当次会话之外，比本代价更严重。

## 验证

三项反向验证，每项都单独撤掉一处修复，确认只有对应测试变红：

| 撤掉的修复 | 变红的测试 | 失败信息 |
| --- | --- | --- |
| `remoteProfileID(for:)` 改回"查不到就建" | 幽灵路径 + 正向对照 | `remoteDeviceProfiles.count → 2` |
| 非就绪分支不清空暂存表 | 过期回放 | `batteryLevel → 4`、`model → .rc001` |
| 电量暂存重新加 `let level` 守卫 | 读取失败作废 | `batteryLevel → 73` |

第一项的失败信息与用户现场症状同形。每次撤改后都按 `shasum -a 256` 确认源文件逐字节还原（`e79dbd1e…` → 最终 `7e5d2172…`）。

修复后：

- `swift test`：400 项测试、35 个 suite 全部通过（新增 4 项、1 个 suite；基线 396/34）；
- `./scripts/test.sh`：42 项项目自检通过；
- `swift build -c release`：通过；
- `./scripts/check-repository-boundaries.sh`：通过。

新增测试 `Tests/RemoteMicTests/RemoteProfilePersistenceTests.swift` 四项：

- 幽灵路径：先占满唯一空槽位，再让一个外设依次上报电量、电源、型号后进入 `.failed`，档案数必须仍为 1 且该身份查不到档案；
- 正向对照：同样次序的读数之后进入 `.ready`，档案必须新增，且 `batteryLevel`、`powerState`、`model` 三项都要是握手前读到的那些值。缺少这一项时，"永不落盘"也能通过第一项；
- 过期回放：读数 → `.failed` → 之后才 `.ready`，三项都必须为空，不得继承被放弃那次尝试的值；
- 读取失败作废：先成功读到 73，再收到 `nil`，`.ready` 后必须为空而不是 73。

## 自动化与真机边界

单元测试驱动的是 `BridgeAppModel` 的委托回调，`XiaomiBluetoothBridge` 由注入 `targetIdentifier` 构造，**没有真实 CoreBluetooth**。以下均未验证：

- 真实 `MI RC` 类设备在附近时，确实不再新增卡片；
- 全新一只 RC001/RC003 首次连接后，卡片上的型号与电量确实正确显示（这是本次改动最主要的回归风险）；
- 真实遥控器在电量读数与 `.ready` 之间断连重连时的表现；
- 上面"已知并接受的代价"第二条：发现桥反复挑中失败外设对真实新遥控器首次配对的实际影响时长；
- 现存的那条 `6AA1224D` 幽灵档案不受本修复影响，仍会显示。

另一处自动化缺口（由审查指出）：测试中外设身份来自注入的 `targetIdentifier`，在生产语义里对应"已有档案的专属桥"；而现场幽灵来自**发现桥**通过 `peripheral.identifier` 解析身份。两者在身份解析之后的路径完全相同（都只是一个 UUID 进入同样的回调与落盘门禁），但"发现桥解析身份"这一段本身未被测试覆盖，要覆盖需要给 `XiaomiBluetoothBridge` 增加测试注入点，本次未加。

真机验收按 [`Testing/GhostRemoteProfileGate.md`](../Testing/GhostRemoteProfileGate.md) 执行，完成前不得认为本 Bug 关闭。
