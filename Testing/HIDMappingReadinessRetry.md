# HID 映射就绪重试测试手册

## 适用范围

- 版本：`1.8.25-fork.2` 及之后
- 分支：`NotWizard/remote-mic-app` `main`
- 对应缺陷：[`Bugs/2026-08-21-remote-reconnect-loses-custom-button-mapping.md`](../Bugs/2026-08-21-remote-reconnect-loses-custom-button-mapping.md)

验证目标：遥控器长时间休眠后重连，自定义按键映射能自行恢复，不需要重启 App 或切换设置。

## 测试前准备

1. 安装目标版本，确认「关于」页版本号为 `1.8.25`、Build `120` 或之后。
2. 系统设置中确认已授予「输入监控」和「辅助功能」。
3. 打开「按键映射」页，启用自定义映射，至少配置两个可肉眼区分的动作，例如 `TV` → 打开某个 App、`菜单` → 打开另一个 App。
4. 清空或记录日志起点：`~/Library/Logs/RemoteMic/runtime.log`。
5. 确认遥控器已配对且当前连接正常，按一次 `TV` 确认动作生效。

## 用例

### RC-RETRY-01 隔夜休眠后重连自动恢复（核心用例）

1. 保持 App 运行，不退出。
2. 让遥控器进入长时间休眠：静置一夜，或取出电池 / 长时间不操作直到 Mac 侧断连，且日志出现连续 `BLE CONNECTING`。
3. 次日唤醒遥控器，等待日志出现 `BLE CONNECTED`。
4. 观察日志。
5. 按 `TV`，再按 `菜单`。

预期结果：

- 若首次写映射失败，日志出现 `VOICE FN MAPPING ... matched=0`，随后出现 `HID MAPPING RETRY scheduled attempt=1 delay_ms=500`。
- 重试若仍失败，`attempt` 递增且 `delay_ms` 按 `500 → 1000 → 2000 → 4000 → 8000 → 15000` 退避，之后维持 `15000`。
- 最终出现 `VOICE FN MAPPING ... power_suppressed=true matched=1`（或更大）与 `HID START mode=adaptive`。
- `TV` 与 `菜单` 执行用户配置的动作，**不是** macOS 原生行为。

失败判定：

- 连接后 5 分钟内未出现 `HID START mode=adaptive`；
- 或按键仍执行系统默认行为；
- 或日志只有 `HID START rejected` 而无任何 `HID MAPPING RETRY scheduled`；
- 或需要重启 App / 切换映射开关才恢复。

### RC-RETRY-02 首次即成功时不产生多余重试

1. 在遥控器已连接且刚使用过的状态下，关闭再打开自定义映射开关。

预期结果：日志出现 `power_suppressed=true` 与 `HID START mode=adaptive`，且**不出现** `HID MAPPING RETRY scheduled`。

失败判定：成功路径仍排程重试，说明退避计数未归零。

### RC-RETRY-03 重试期间断连应终止

1. 制造首次写映射失败（可在遥控器刚唤醒、尚未稳定时立即观察）。
2. 在看到 `HID MAPPING RETRY scheduled` 后，立刻关闭遥控器或使其断连。

预期结果：日志出现 `HID MAPPING RETRY abandoned reason=preconditions_changed`，此后不再出现新的 `HID MAPPING RETRY scheduled`，直到下次连接。

失败判定：断连后仍持续排程重试。

### RC-RETRY-04 关闭自定义映射应终止重试

1. 在出现 `HID MAPPING RETRY scheduled` 后，于「按键映射」页关闭自定义映射。

预期结果：不再出现新的重试；按键回到系统默认行为，这是预期的。

失败判定：关闭后仍持续重试。

### RC-RETRY-05 退出 App 不留残留任务

1. 在出现 `HID MAPPING RETRY scheduled` 后立即完全退出 App。

预期结果：退出后日志不再新增任何 `HID MAPPING RETRY` 行。

失败判定：退出后仍出现重试日志。

### RC-RETRY-06 日志可区分两种拒绝原因

1. 关闭自定义映射开关，观察 `HID START rejected` 行。

预期结果：该行同时包含 `mapping_enabled=` 与 `power_suppressed=`，可据此区分是"未启用映射"还是"映射写入失败"。

失败判定：仍打印无法区分的旧格式。

## 稳定功能回归

以下在完成上述用例后必须逐项确认未退化：

- 语音键按住说话、松开结束，音频进入所选设备；
- 语音触发键设为 Fn 时豆包输入法路径正常；
- 语音触发键设为右 Command / Option / Shift 时无修饰键卡住；
- 自定义快捷键的左右侧修饰键仍然保真；
- 方向、确定、返回、音量键的单击、双击、长按行为不变；
- 「统计」页按键计数正常累加。

## 日志收集

```zsh
cp ~/Library/Logs/RemoteMic/runtime.log ~/Desktop/runtime-$(date +%Y%m%d-%H%M).log
grep -E 'BLE CONNECTED|VOICE FN MAPPING|HID MAPPING RETRY|HID START|HID BUTTON' \
  ~/Library/Logs/RemoteMic/runtime.log | tail -60
```

## 验证边界

- **自动化已覆盖**：`HIDMappingRetryPolicy` 的判定组合与退避序列（含越界维持、负数夹紧）、`BridgeAppModel` 的接线与取消点。共 247 项 Swift 测试与 42 项项目自检通过。
- **自动化无法覆盖**：真实 IOKit HID 服务注册时机、真实 BLE 重连、实际按键动作恢复。单元测试无法驱动 `IOHIDEventSystemClient`。
- **代理实测已完成**：构建、测试、Release 构建、DMG 构建与校验。
- **代理实测未完成**：任何真机遥控器操作。代理无法制造"隔夜休眠"条件，也无法代替用户按键。
- **用户实测必需**：RC-RETRY-01 至 RC-RETRY-06 全部用例，以及上述稳定功能回归。**在 RC-RETRY-01 通过前，本修复只能表述为"自动化通过、待真机验收"。**

特别说明：退避上限 15 秒是基于日志推断的取值，真实枚举耗时未测量。若 RC-RETRY-01 出现"重试一直进行但始终 `matched=0`"，需要记录从 `BLE CONNECTED` 到首次 `matched>0` 的实际间隔，据此调整退避序列。
