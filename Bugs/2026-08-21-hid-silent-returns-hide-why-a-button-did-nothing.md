# HID 按键无响应时日志无法说明是哪一条分支拦下的

- 时间：2026-08-21
- 状态：已修复，自动化通过；真机验收未完成
- 影响范围：所有使用自定义按键映射的用户（诊断能力缺陷，不改变功能行为）
- 功能点：`HIDRemoteMonitor` 的监听启动、设备匹配、报告路由、按键分发
- 简单描述：`HIDRemoteMonitor.swift` 中多处提前 `return` 完全不写日志，或多个不同原因打印同一行文字。用户报「按了键但快捷键没触发」时，日志无法指出实际走了哪条分支。

## 复现

这是审计项 A6，属于可从源码直接确认的诊断缺陷，不需要现场条件即可复现「日志无法区分」这一现象。

现场先例（同日另一份记录，[`2026-08-21-remote-reconnect-loses-custom-button-mapping.md`](2026-08-21-remote-reconnect-loses-custom-button-mapping.md)）：遥控器隔夜休眠重连后自定义映射失效，决定性日志只有

```text
02:02:01Z HID START rejected power_suppressed=false
```

`mappingEnabled=false`（用户关掉了映射）与 `powerKeySuppressed=false`（映射写入未就绪）当时渲染同一行文字，只能靠读用户机器上的 `defaults read com.hd838a.RemoteMic` 排除前者。那一行已在上一次修复中补上两个入参，本次处理其余同类分支。

可重复的确认方式（本次采用）：把测试断言指向「该分支必须写出可区分的原因」，先确认断言在修复前失败、修复后通过（见「验证」中的反向验证）。

错误行为：用户可见动作被拦下时，日志或完全无输出，或多个原因输出同一行。
正常行为边界：按键成功时一直有 `HID BUTTON button=… trigger=… action=…`；失败路径才是盲区。

## 日志结论

按分支逐一核对 `HIDRemoteMonitor.swift`（修复前 762 行），能拦下用户可见动作且日志不可区分的位置如下。

完全静默（日志中查不到任何痕迹）：

| 位置 | 分支 | 后果 |
| --- | --- | --- |
| `start` 146 | 自定义映射关闭 | 监听根本没起，日志无任何输出 |
| `start` 161-165 | 输入监控未授权 / 辅助功能未授权 | 三个门禁原因中两个静默，只有第三个写日志 |
| `start` 196-205 | `IOHIDManagerOpen` 失败 | 只更新状态，日志看不出打开失败 |
| `deviceDidMatch` 234 | 匹配回调返回错误 | 只更新状态 |
| `deviceDidMatch` 245 | 取不到设备指纹 | 静默 |
| `deviceDidMatch` 246-248 | 等待报告路由 | 静默 |
| `handleReport` 316 | 监听未运行 / 映射关闭 | 两个原因合并且静默 |
| `handleReport` 317-320 | 报告位置不在白名单 | 静默 |
| `handleReport` 321-326 | 报告指纹未路由 | 静默 |
| `handleReport` 338-340 | 报告解析不出按键 | 静默 |
| `process` 376 | usage 不在按键表 | 静默 |
| `process` 414-419 | 路由拒绝执行 / profile 未解析 | 两个原因合并且静默，这是「按了没反应」最直接的分支 |
| `process` 447-451 | 非重复按键去抖丢弃 | 静默 |
| `performConfiguredAction` 668-672 | 动作注入被拒，随即 `stop()` | 静默，映射就此关停但日志只剩沉默 |

多因合一（同一行文字对应多个不同原因）：`start` 的门禁、`handleReport` 的首个 `guard`、`process` 的 profile/路由 `guard`，共三处各自把 2–3 个原因压成一条不可区分的路径。

## 根因

诊断信息缺失，不是功能缺陷。两类具体成因：

1. 提前 `return` 只做 `updateStatus` 或什么都不做。`updateStatus` 只驱动界面当前状态，不落盘、不留时序，事后无法回溯。
2. 复合 `guard` 把多个条件写在一起，任一条件为假都走同一个 `else`，因此即使补上日志也只能得到一行共用文字。

## 修复

诊断修复，不改行为。

- 新增 `HIDSuppressionReason`（`RemoteButtons.swift`，紧邻 `HIDPermissionGate` 与 `HIDMappingRetryPolicy`，沿用同一种纯判定类型写法）：`String` 原始值 + `CaseIterable` 的封闭集合，21 个 case 按调用点分组，每个 case 一个稳定 snake_case token。token 即日志契约，改名会让既有现场日志失效。
- 三个日志出口按频率区分处理：
  - `logStartRejected` / `logDeviceRejected` 为冷路径（每次 `start()` 或每次设备匹配回调至多一行），原样落盘。
  - `logInputIgnored` 为热路径（每份 HID 报告、每个按下沿都会经过），把消息本身作为 `foldKey` 交给 `AppLogger`，由 `LogFold` 折叠。
- `AppLogger.swift` 的 `LogFold.foldableMessagePrefixes` 增加第 4 条 `"HID INPUT ignored reason="`。该类消息只含固定 reason token 加最多一个按键名或 usage 数字，没有 `state={…}` 之类逐行内容，因此「整条消息即 key」这一安全前提成立：共用 key 的两行必然字节相同，被折叠的重复不可能藏起保留行没有的字段。
- 两处复合 `guard` 拆成逐条判断，**求值顺序与短路行为完全保持**：`deviceDidMatch` 仍是「先 activeDevice、再 targetFingerprint、最后 excludedFingerprints()」，`excludedFingerprints()` 仍只在前两项通过后才调用；`handleReport` 仍是「先 manager、再 customMappingEnabled」。
- `performConfiguredAction` 的动作注入失败分支补 `HID ACTION failed reason=action_injection_rejected`，`stop()` 与状态更新原样保留。

未改动任何 `updateStatus` 调用、控制流、状态机或门禁条件；未新增可变状态。已有 `HID DEVICE rejected unsafe_location` 统一为 `reason=unsafe_location` 形状。

刻意未改动的位置：`stop()` 的 `guard let manager`、`deviceDidRemove` 的非本机设备分支（都不会拦下用户可见动作，且 `stop()` 每次 `start()` 都会调用，加日志纯属噪声）；`handleSimulatedReport`（测试注入口，生产路径不可达）。

已知残留边界：`handleReport` 的指纹分支统一报 `report_fingerprint_not_routed`，未再细分「指纹取不到 / 与在用设备不符 / 在排除集 / 与目标不符」。细分需要改动纯函数 `resolvedFingerprintForReport` 的返回语义或在调用点复制其判定逻辑，两者都超出最小修复范围；这四个原因在设备接入阶段已由 `fingerprint_unavailable`、`another_device_active`、`fingerprint_excluded`、`fingerprint_not_target` 分别落日志。

## 验证

三条命令各自单独执行，退出码单独一行捕获（未经 `tail`/`head` 管道，避免读到分页器的状态）。

```text
$ swift test > /tmp/a6_final_swifttest.log 2>&1
EXIT_CODE=0
✔ Test run with 281 tests in 24 suites passed after 15.318 seconds.

$ ./scripts/test.sh > /tmp/a6_final_selftest.log 2>&1
EXIT_CODE=0
RESULT passed=42 failed=0

$ ./scripts/check-repository-boundaries.sh > /tmp/a6_final_boundaries.log 2>&1
EXIT_CODE=0
REPOSITORY BOUNDARY PASS
```

基线为 277 项测试 / 24 个 suite，本次新增 4 项，最终 281 项 / 24 个 suite。suite 数保持 24，未新增 suite，未删改或弱化任何既有测试。

需要说明计数口径：本工作区同时存在另一处与本次修复无关的并行改动（`BluetoothLifecycle.swift`、`XiaomiBluetoothBridge.swift`、`BluetoothLifecycleTests.swift`，均非本次修改）。该改动曾一度自带 2 项测试，因此中途某次运行显示 283 项；最终运行时其测试计数回到净零，得到 281 项。无论那侧如何变动，本次修复的贡献固定为 4 项，且这 4 项在最终运行中均已确认通过。

新增测试（全部在 `Tests/RemoteMicTests/RemoteButtonsTests.swift` 的 “Remote buttons” suite）：

1. `hidSuppressionReasonTokensStayDistinctNonEmptyAndGreppable` —— 纯判定：21 个 token 互不相同、非空、不含空格与 `=`（否则按空白切分会截断）、仅小写字母数字下划线；且每个 token 折叠成**互不相同**的 fold key，防止「多因合一」从源码转移到日志器内部。
2. `startRejectionNamesWhichBranchStoppedButtonMapping` —— 真实驱动 `HIDRemoteMonitor.start()` 并通过 `AppLogger.shared.addWriteObserver` 观察真实落盘行：映射关闭时必须出现 `reason=mapping_disabled`；映射开启但门禁拒绝时必须出现门禁三原因之一，且**不得**与前者混同。
3. `aPressDeclinedByRoutingIsLoggedAsDeclinedNotAsAMissingProfile` —— 真实驱动一次被路由拒绝的按下：动作确实一次都没执行（复现用户可见症状），日志必须报 `routing_declined` 而不是同一个 `guard` 里的 `profile_unresolved`。
4. `thePerReportIgnorePathNamesItsReasonWithoutFloodingTheLog` —— 真实驱动 40 次按下/释放：该 reason 必须出现，且**恰好一行**，锁定热路径不得回退成每报告一行。

四项测试均不通过 grep 源码文本断言。

反向验证（确认断言真的依赖本次修复，而不是恒真）：

- 移除 `LogFold` 的 `"HID INPUT ignored reason="` 白名单条目：测试 4 报 `(sink.lines.filter { $0 == expected }.count → 40) == 1` 失败，测试 1 报 `(Set(keys).count → 0) == (tokens.count → 21)` 失败。即 40 次按下会真的写 40 行。
- 把 `shouldPerformAction ? .profileUnresolved : .routingDeclined` 改成两边都返回 `.profileUnresolved`：测试 3 的两条断言同时失败，实际观察到 `["HID INPUT ignored reason=profile_unresolved button=ok"]`。

两次反向验证后源文件已从备份完整还原，并重新执行了上述三条命令。

fork 专有行为回归：`swift test` 中 `sideSpecificShortcutHoldsRealModifierAndReleasesInReverse`（右侧修饰键不粘滞、左右保真）、`rawHardwareRepeatStaysLatchedUntilAStableRelease`、`navigationRepeatStopsOnlyWhileRemoteMicIsFrontmost` 均通过。本次未改动 `usesNativePassthrough` 判定、`eventSuppressor.arm` 的调用位置与顺序、按键注入或语音触发键路径。

## 自动化与真机边界

**本次修复完全没有在真实硬件上验证，不能视为已完成真机验收。** 代理无法接入真实小米蓝牙语音遥控器、真实蓝牙链路或真实系统权限授权流程。

单元测试只覆盖：封闭原因集合的形状与折叠 key 唯一性、`start()` 两类拒绝分支经真实 `AppLogger` 落出的行、以及经 `connectSimulatedDevice` / `handleSimulatedReport` 注入口驱动的两条按键分支。

**以下均未验证**：

- 真实遥控器抖动时 `duplicate_press_debounced` 与 `report_not_parsed` 的实际行数，即折叠在真实报告速率下是否把日志量压到预期；
- `input_monitoring_denied` 与 `accessibility_denied` 两条分支在真实授权状态下各自的输出——测试进程的授权状态由环境决定，测试只断言「必属门禁三原因之一」，未能分别驱动这三条；
- `manager_open_failed`、`match_callback_failed`、`unsafe_location`、`another_device_active`、`fingerprint_not_target`、`fingerprint_excluded`、`report_location_not_allowed`、`report_fingerprint_not_routed` 八个 token：均需真实 IOKit 设备匹配回调或多遥控器接入才能触发，本次一次都没有实际产生过；
- `action_injection_rejected` 在真实辅助功能权限被撤销时的实际输出；
- 多遥控器同时接入时新增行的实际总量。

上述项目必须在真实遥控器上按一次完整「连接 → 按键 → 断连 → 重连 → 再按键」流程收集 `~/Library/Logs/RemoteMic/runtime.log` 后才能确认。当前只能确认自动化边界通过。

## 附带发现（本次未修复）

`start()` 中 `IOHIDManagerOpen` 失败分支无条件调用 `eventSuppressor.stop()`（`HIDRemoteMonitor.swift`，`logStartRejected(.managerOpenFailed…)` 上一行），未像 `stop()` 那样用 `if ownsEventSuppressor` 保护。

`BridgeAppModel` 把同一个 `hidEventSuppressor` 以 `ownsEventSuppressor: false` 分发给每个按 profile 创建的监听器（`BridgeAppModel.swift:1127-1128`），并在 `BridgeAppModel.swift:1034` 全局启动它。因此多遥控器场景下，任意一个监听器打开 HID manager 失败，都会把其他遥控器和 `BridgeAppModel` 共用的按键抑制一起关掉。

这是真实逻辑缺陷而非诊断问题，按本次「只补诊断、不改行为」的范围要求**刻意未修复**，另行报告。
