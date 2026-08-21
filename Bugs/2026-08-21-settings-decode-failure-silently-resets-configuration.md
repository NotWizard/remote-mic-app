# 持久化配置解码失败被静默当作首次运行，用户配置无声重置

- 编号：A1
- 时间：2026-08-21
- 状态：已修复，自动化通过；真机未验收
- 影响范围：所有从 `UserDefaults` 读取的 JSON 编码配置项，共 10 个键
- 功能点：`AppSettings.init(defaults:)` 的配置加载
- 定位：**防御性加固，而非已发生故障的修复**

## 关于严重性的诚实定位

**没有证据表明已有用户命中过解码失败。** 这一点必须说清，因为本次整改期间确实发生过一次用户配置丢失，但那次的根因是别的：安装包因 macOS bundle relocation 删除了已安装的 App，随后新版按全新安装写入默认值（见 [`2026-08-21-installer-bundle-relocation-deleted-installed-app.md`](2026-08-21-installer-bundle-relocation-deleted-installed-app.md)）。另一次按键映射失效的根因是 HID 就绪竞态，且当时明确记载「用户配置未丢失」（见 [`2026-08-21-remote-reconnect-loses-custom-button-mapping.md`](2026-08-21-remote-reconnect-loses-custom-button-mapping.md)）。

本条是代码审计发现的潜伏缺陷：一旦发生，用户会丢失全部按键映射与自定义动作，且**没有任何线索可供排查**。修复的价值在于把不可诊断变为可诊断、把不可恢复变为可恢复。

## 复现

在受控环境中构造：向 `buttonBindings` 键写入无法解码的数据（非 JSON 字节，或结构不匹配的合法 JSON），然后构造 `AppSettings(defaults:)`。

错误行为：全部按键映射回退到默认值，无日志、无界面提示，原始数据在下一次保存时被覆盖销毁。
正常行为边界：该键从未保存过时（真正的首次运行）回退到默认值是正确的。

## 根因

10 处加载点写作：

```swift
if let data = defaults.data(forKey: Keys.buttonBindings),
   let decoded = try? JSONDecoder().decode([String: ButtonAction].self, from: data) {
```

`try?` 把两种语义完全不同的情况合并进同一个 `else`：

1. `data == nil`——从未保存，用默认值正确
2. `data != nil` 但解码抛错——数据存在却读不出来，属于故障

`try?` 同时承担「可选存在性判断」和「错误抑制」两种职责，这是根因。

放大伤害的一点由测试实测确认：`remoteDeviceProfiles` 在同一次 `init` 内会被二次写入并触发 `didSet` 保存，因此**没有备份的话，损坏字节在首次启动时就被覆盖，永久不可恢复**。`buttonBindings` 只赋值一次、无 `didSet`，字节得以保留——这一不对称已被测试钉住。

## 修复

新增静态 helper `AppSettings.decodeSetting(_:forKey:from:corrupted:)`，把两种情况分开：

- 无数据：静默返回 `nil`，走默认值
- 有数据但解码抛错：记录日志（含键名、字节数、`DecodingError`）、把原始字节另存到 `<键>.corrupt`、把键名累加进 `corruptedSettingKeys`

之所以是 static 且用 `inout` 累加，是因为调用点位于 `init` 内、实例尚未完全初始化，不能调用实例方法。

10 处加载点全部切换，**每一处原有的默认值语义逐一核对未变**，包括 `remoteDeviceProfiles` 的 `!decoded.isEmpty` 守卫与旧版迁移分支。

`firstUseEvents` 那处位于计算属性 getter 内，故意不上报 `corruptedSettingKeys`：getter 可被重复调用会重复追加，且引导遥测不是用户配置、不应触发「配置丢失」告警；但仍记日志并备份字节。

### 界面提示

独立复核指出首版存在缺口：`corruptedSettingKeys` 零消费者，原缺陷描述的「无 UI」并未闭合。已补上按键映射页顶部的内联提示（`CorruptedSettingsNotice`）：说明哪些配置受影响、原始数据仍保留、以及重新设置一次即可。判定与文案组装抽为纯函数以便测试。

放在按键映射页的理由：10 个可损坏键中 7 个是映射数据，且它是侧边栏首项，用户发现按键行为不对时会来这里。未采用菜单栏角标——角标无法说明丢了什么。

字号使用显式 `.system(size: 12)` 及以上，未使用 macOS 的 `.caption`（实为 10pt），符合 `AGENTS.md` 的中文不小于 12pt 约束；提示为内联面板，未使用 Sheet 或弹窗。

## 验证

- `swift test`：275 项通过（A1 相关新增 15 项，均为真实行为测试，无源码文本断言）
- `./scripts/test.sh`：42 项通过
- `./scripts/check-repository-boundaries.sh`：通过
- 复核者实测有效性：把 helper 降级回 `try?` 行为后，7 个损坏恢复测试中 **5 个变红、12 个 issue**；其中 2 个是合法的假阳性对照（防止 helper 误报全部键），不计入回归防护
- `.corrupt` 字节比对是 `Data == Data` 真逐字节，复核者用独立探针确认同长度不同字节返回 `false`
- 两份 `Localizable.strings` 键集合仍完全对齐（各 616 键）

## 自动化与真机边界

自动化覆盖解码失败的判定、备份、上报与提示文案组装。**未验证**：真实用户在真实损坏场景下的完整体验、提示在 `800 × 650` 与更大窗口下的布局表现、以及中英文实际渲染字号。

已知未处理项（非阻塞，经复核确认不构成必须现在修）：`<键>.corrupt` 在该键下次成功保存后不会被清理。由于是键替换而非追加，最坏为每键一份副本、上限 10 键；`voiceSessionRanking` 被 `.prefix(10)` 限制约 2 KB，`dailyStatistics` 十年量级仅数百 KB。最小正确修法是在下次成功保存后删除对应 `.corrupt` 键。
