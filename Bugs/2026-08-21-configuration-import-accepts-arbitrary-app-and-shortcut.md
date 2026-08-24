# 导入配置几乎不校验，可为遥控器按键装上任意应用与快捷键触发器

- 编号：A10
- 时间：2026-08-21
- 状态：已修复，自动化通过；真机与真实第三方 APP 未验收
- 影响范围：`关于` 页「导入配置」入口；受影响数据为按键映射、自定义应用动作、自定义快捷键、音频设备标识；另含受信任手机/手表设备存储
- 功能点：`AppSettings.importConfiguration(from:)`、`AppSettings` 受信任设备存储
- 定位：**防御性加固（信任边界校验缺失），而非已发生故障的修复**

## 关于严重性的诚实定位

**没有证据表明已有用户收到过恶意配置文件。** 这是代码审计条目，不是现场故障。

同时必须把危害说准，不能夸大：导入本身不执行任何代码；真正执行发生在按键按下之后，而执行路径
`KeyboardInjector.resolveCustomApplicationURL` 已经要求「路径上的 bundle 的 `bundleIdentifier` 等于配置里声明的
`bundleIdentifier`」，否则退回按 bundle id 查找已安装应用。因此修复前的真实后果是：

- 可以把遥控器任意按键绑定到**这台 Mac 上存在的任意 App bundle**（包括用户刚下载到 `~/Downloads` 里的 `.app`），用户自己完全不知道；
- 可以写入越界的 `keyCode`、超长字符串等垃圾值，随按键合成到系统事件流里；
- 不能直接用 `/bin/sh` 之类的非 bundle 路径拉起进程（`NSWorkspace.openApplication(at:)` 会失败）。

即：修复前导入会**静默安装一个触发器**，而不是当场执行代码。下面所有结论都按这个边界表述。

## 复现

在受控环境中构造（对应自动化用例 `anApplicationPathThatIsNotAnApplicationBundleIsNeverInstalled`、
`aBundleClaimingSomebodyElsesIdentifierIsRefused`）：

1. 正常导出一份配置（其中 Menu 键单击绑定「打开自定义应用」）。
2. 手工把 JSON 里 `customApplicationProfiles[0]` 的 `applicationPath` 改成 `/bin/sh`、`bundleIdentifier` 改成
   `com.evil.payload`；或改成一个真实存在但 `bundleIdentifier` 不匹配的 `.app`。
3. 在另一台（或另一个 `UserDefaults` 域的）实例里导入。

修复前错误行为：导入返回成功，界面显示「配置已导入并应用」，被篡改的条目原样落到
`customApplicationProfiles`，Menu 键随即指向它，全过程无提示、无日志。
修复前同样被接受的还有：越界 `keyCode`（如 60000）、任意修饰键位、超长 `keyLabel`/`displayName`/路径/音频设备
标识、未知按键键名。

正常行为边界：**合法配置必须继续可导入**，包括源 Mac 装了目标 Mac 没装的应用（跨机迁移是该功能存在的理由），
以及旧版导出文件缺少可选字段的情况。

## 日志

修复前该路径**没有任何日志**：`importConfiguration` 不写 `AppLogger`，界面只有成功/失败两种结果。这本身也是问题的
一部分——真出事时无从追查。修复后不可信条目会写一行
`SETTINGS import_filtered rejected=<键列表> missing_apps=<数量>`。

## 根因

`AppSettings.importConfiguration(from:)` 只做了两件校验：`formatVersion == 1` 与 `gainDB ∈ 0...24`。其余字段直接
赋值。三处具体原因：

1. **按键名以外无域校验**：只用 `RemoteButton(rawValue:)`/`ButtonTrigger(rawValue:)` 过滤字典键，值一律照收。
2. **`CustomKeyboardShortcut` 的 `Codable` 绕过了它自己的构造器**。构造器
   `init(keyCode:modifierFlags:keyLabel:)` 会把修饰键掩到 `supportedModifiers ∪ deviceDependentModifiers`，
   但合成的 `Decodable` 直接给 `let modifierFlagsRawValue: UInt` 与 `let keyCode: UInt16` 赋原始值。
3. **应用引用完全未校验**：`applicationPath` / `bundleIdentifier` 是自由字符串，而它们最终决定按键会拉起什么。

第二部分（受信任设备）的根因同类：`security.trustedPhoneIdentityFingerprints` 是一个纯 `[String]`，
`isPhoneIdentityTrusted` 只做 `contains`。一次批准即等于该安装周期内永久批准，既无有效期也无自动吊销。

## 修复

### 1. 导入前逐条校验（`Sources/RemoteMic/AppSettings.swift`）

**整文件拒绝 vs 逐条丢弃**：文档级值继续整文件抛错（`formatVersion`、`gainDB` 不合法说明整份文件不可信）；
单条目不可信只丢该条目，其余照常导入。理由有两条：一是原实现对未知按键键名本来就是逐条丢弃，保持一致；
二是把 99% 合法的配置整份丢掉是在惩罚用户。丢弃的内容不再静默——见下方「用户如何知道」。

具体校验域基本从代码推导，但有一条例外，见本节末尾的复核记录：

| 字段 | 校验 | 不通过时 |
| --- | --- | --- |
| `buttonBindings` / `buttonApplicationProfileIDs` 键 | `RemoteButton(rawValue:)` | 丢该条并上报 |
| `secondaryButtonBindings` 键 | `RemoteButton` / `ButtonTrigger` | 丢该条并上报 |
| 快捷键 `keyCode` | `<= 127`（macOS 虚拟键码是 7 位；本 App 自己的标签表止于 126） | 丢该快捷键并上报 |
| 快捷键 `keyLabel` | `<= 64` 字符 | 丢该快捷键并上报 |
| 快捷键修饰键位 | 重新走 `CustomKeyboardShortcut` 构造器，掩到 `supportedModifiers ∪ deviceDependentModifiers` | 多余位被丢弃，**左右侧位保留** |
| `ConfiguredButtonAction` 内快捷键 | 同上 | 丢整个 trigger 条目（`customShortcut` 少了快捷键等于按键无声失效） |
| `bundleIdentifier` | 非空、`<= 256`、仅字母数字与 `._-`（**不限 ASCII**）、不以 `.` 开头/结尾、无 `..` | 丢该应用并上报 |
| `applicationPath` | 绝对路径、`<= 1024`、无 `..` 段、扩展名为 `.app` | 丢该应用并上报 |
| `applicationPath` 已存在时 | `Bundle(url:)?.bundleIdentifier` 必须等于声明的 `bundleIdentifier` | **保留该应用并提示「这台 Mac 上没装」** |
| `displayName` | `<= 256` 字符 | 丢该应用并上报 |
| `accessibilityTarget` 各字符串 | 各 `<= 256`，`normalizedFrame` 各值有限 | 只清空 `accessibilityTarget`，保留应用 |
| `focusShortcut` | 同快捷键规则 | 只清空 `focusShortcut`，保留应用 |
| `selectedAudioDeviceUID` | `<= 256` | 置空并上报 |

**复核否决与修正**：第一版把 `bundleIdentifier` 限制为纯 ASCII，这一条不是从代码推导的，而是假定的，并且是错的。
独立复核在本机 130 个已安装 App 中找到 3 个反例：脚本编辑器的「导出为应用程序」会把 App 名称原样拼进
`com.apple.ScriptEditor.id.<名称>`，所以 `/Applications/阿里内外.app` 的 bundle id 就是
`com.apple.ScriptEditor.id.阿里内外`。选择器（`SettingsView.swift`）本来就接受任何非空 `Bundle.bundleIdentifier`，
这类配置完全合法。复核实跑证明：这样一个**当前就装在本机**的 App，导出再导入后配置数量为 0，
`buttonApplicationProfileIDs` 指向一个解析不到任何东西的 UUID——按键静默失效。对一个中文市场产品来说这是
比原漏洞更严重的回归，因此 ASCII 限制已移除。

同一轮复核还指出 bundle id 不一致时丢弃应用是错的：执行路径 `resolveCustomApplicationURL` 在真正打开之前会
再做一次同样的判等，并回退到按 bundle id 查找，所以在导入时丢掉只会销毁用户的绑定而不增加任何安全性。
该分支已改为降级为「这台 Mac 上没装」。

**`.app` 路径存在性的取舍（明确选择）**：结构不合法（路径不是绝对路径、含 `..`、扩展名不对、bundle id 含非法字符）
才丢弃，这才是「任意路径」攻击面所在。路径**不存在**、或存在但 bundle id 已变（App 升级换了标识、同路径换成了别的
App）都**保留该应用并单独提示「这台 Mac 上没装」**：否则从装得更全的 Mac 导出的配置每次迁移都会掉设置，跨机迁移这个
功能本身就没意义了。

`focusShortcut` 与 `accessibilityTarget` 只清空而不丢应用，是因为 `KeyboardInjector` 两条聚焦分支本来就是
`if let` 守卫，清空只降级聚焦，不会让按键失效。

### 2. 用户如何知道（复用既有机制，未新增第二套）

沿用 A1 建立的模式：`AppSettings` 发布状态 + 按键映射页顶部内联提示。

- `AppSettings.configurationImportNotice: ConfigurationImportReport?`（仅内存，描述一次用户动作，不跨启动保留）；
- `CorruptedSettingsNotice` 增加 `importRejectionSummary(...)` 与 `missingApplicationSummary(...)`，**复用同一套
  用户可读条目名与分隔符**，因此上报用的存储键天然都能落到已有条目名上（自动化用例
  `everyReportedStorageKeyIsNamedForTheUser` 钉住这点）；
- 「按键映射」页 `configurationImportBanner` 内联渲染，未使用 Sheet/Popover/弹窗；字号显式 `.system(size: 12)`
  与 `13`，未使用实为 10pt 的 `.caption`，符合 `AGENTS.md` 中文不小于 12pt 的约束；
- 「关于」页导入按钮旁的状态行新增 `configuration.import.partial`：部分采纳的文件不再显示为纯成功。

### 3. 受信任设备有效期（`Sources/RemoteMic/AppSettings.swift`）

- 新增存储键 `security.trustedPhoneIdentityTrustDates`（`[String: Date]`），记录每台设备的批准时间；
- **窗口 30 天**：日常使用的设备一个月内不会被重新询问，而借出、转卖或丢失的设备一个月内自动停止被静默接受；
  重新批准的代价只是一次两位校验码确认；
- 判定 `0 <= now - trustedAt < 30d`。未来时间戳（时钟跳变或被人改过 plist）同样视为过期——本机不可能在「未来」
  写下批准记录，它不构成批准证据；
- 清理时机：加载时（`init` 内的初始赋值不触发 `didSet`，因此显式回写一次）与每次新增批准时。查询路径
  `isPhoneIdentityTrusted` 由后台线程调用，故**只判定不改状态**，避免在读路径上改可观察状态；
- 兼容旧安装：加载时把旧 `[String]` 里没有时间戳的指纹按本次加载时间补戳，升级不会把已批准设备全部登出；
- 旧 `[String]` 键继续同步写入，使吊销对旧版本同样生效，也避免降级后把刚清除的设备复活。

## 未修复与超出范围（残余风险，明确记录）

- **导入一份配置仍然意味着采纳它写的「按键 X 打开应用 Y」，而校验不能替代用户的判断。** 具体地：路径在本机不存在
  时该条目被保留（用例见上文取舍），而执行时 `resolveCustomApplicationURL` 会退回按 `bundleIdentifier` 查找已安装
  应用——因此一份格式合法的文件仍可把按键绑定到**本机已安装的任意应用**。这与「同一个 App 装在不同路径」的合法迁移
  在结构上无法区分，因此没有拒绝。本次改动把这件事从「完全静默」改善为：引用必须格式合法且与路径上的 bundle 一致、
  本机缺失的应用会被点名提示、导入后「按键映射」页可逐键看到实际绑定的动作与应用名。**但没有逐个应用的确认弹窗**，
  用户从不可信来源导入文件时仍在自行承担这份采纳。
- **受信任设备存储仍在 `UserDefaults`，不是 Keychain 密钥对**。任何能写用户 preference 的进程都能插入一条带当前
  时间戳的信任记录。改为 Keychain 密钥对需要手机/中继侧协议配合，属于私有 iOS/relay 仓库的改动，本次明确不做。
- **仍未对每一帧远端指令做身份认证**。当前模型是「会话建立时校验一次身份指纹」，此后该连接上的按键与音频不再逐帧
  验证。逐帧认证同样需要跨仓协议改动，本次不做。
- 有效期是固定 30 天而非滑动窗口：一台每天都在用的设备满 30 天仍会被要求重新批准一次。滑动窗口需要在查询路径上
  写状态，而该路径运行在后台线程，权衡后没做。
- 导入提示只存在于本次会话（不落盘）。重启 App 后提示消失，被跳过的条目仍然是缺失状态；用户重新设置一次即可。
- 应用引用的存在性校验在**导入时刻**判定。导入后应用被删除或被同名 bundle 顶替，不在本次范围内；执行时的
  `resolveCustomApplicationURL` 判据仍然生效。

## 验证

命令逐条单独执行，退出码单独读取（未经 `tail`/`head` 管道）：

- `swift test` → 退出码 `0`，`Test run with 312 tests in 26 suites passed`。
  其中本条目新增 23 项（`Configuration import validation` 18 项 + `Trusted device expiry` 5 项）。
  基线为 283 项 / 24 套；312 − 283 = 29，差额中的 6 项来自同一工作区内另一并发改动
  （`AudioOutput.swift` / `VoiceFnTapSessionController.swift` 及其测试），不属于本条目。
- `./scripts/test.sh` → 退出码 `0`，`RESULT passed=42 failed=0`。
- `./scripts/check-repository-boundaries.sh` → 退出码 `0`，`REPOSITORY BOUNDARY PASS`。

### 复核者实测有效性（负向对照，共 3 次）

每次手工降级一处校验、跑测试、再用 `cp` 从改动前副本按字节还原，并比对
`git diff Sources/RemoteMic/AppSettings.swift` 的 SHA-256：
三次还原后均为 `28204ec1c4cb8ca07044aeeb67c75dbc95175592c12badb30b6a9576c7fd8d50`，与降级前完全一致。

| 降级内容 | 结果 |
| --- | --- |
| `validatedApplicationProfile` 一律返回 `.usable` | **6 项变红，26 个 issue** |
| `validatedShortcut` 原样返回入参 | **5 项变红，7 个 issue** |
| `isTrustCurrent` 一律返回 `true` | **4 项变红，9 个 issue**（另 1 项套件级） |

### 分叉功能未回归（重点：左右侧修饰键）

- `aLegitimateConfigurationStillRoundTripsWithSideFidelity`：录制的右 Command（设备相关位 `0x0000_0010`）
  经「导出 → 导入 → 再导出」后 `modifierFlagsRawValue` 仍为 `0x0010_0010`，`sideSpecificModifierKeyCodes == [54]`
  （右 Command 键码，不是左键 55）。
- `strayModifierBitsAreMaskedWhileTheRecordedSideSurvives`：叠加 Caps Lock、小键盘位与一个 App 从不记录的高位后，
  多余位被掩掉、右侧位仍在。
- 可配置语音触发键、外接麦克风采集：`VoiceTriggerKeyTests` 的导入往返用例未改动且继续通过。
- 右侧修饰键不粘滞：`buttonShortcuts` / `secondaryButtonBindings` 的注入路径未改动，只在导入时做域校验。

### 未削弱既有测试

未修改或删除任何既有测试。特别核对了会被本次改动波及的既有用例：
`customApplicationProfilesPersistPerRemoteAndRoundTripConfiguration`（其 `applicationPath` 为
`/Applications/Example Agent.app`，在测试机上不存在）仍要求导入后 profile 与源**完全相等**——这正是「不存在则保留」
这一取舍必须成立的原因，该用例继续通过。

## 自动化与真机边界

自动化覆盖：真实字节经真实 `importConfiguration` 的逐条判定、丢弃与上报；临时构造的真实 `.app` bundle
（含 `Contents/Info.plist`）用于 bundle id 一致性判定；真实 `UserDefaults` 域上的信任时间戳加载、迁移、过期与吊销；
两份实际 `Localizable.strings` 组装出的提示文案。断言全部针对**导入后的实际状态**，没有一条是对源码文本的断言。

**本次无法进行真机验证，也未进行任何真机验证**：本会话没有真实小米遥控器、真实 iPhone/Apple Watch、真实第三方
APP，也没有可见界面。以下**均未验收**：

- 导入被篡改的配置后，真实按键按下时的实际系统行为；
- 「按键映射」页新提示在当前生产 `minSize`（以 `RemoteMicApp.swift` 为准，现为 `1020 × 772`）及更大窗口下的实际布局、是否裁切、中英文实际渲染字号（更窄布局用 `REMOTE_MIC_SETTINGS_SCREENSHOT_SIZE` 离屏渲染，注明为离屏结果）；
- 「关于」页部分导入状态行的实际观感；
- 真实 iPhone / Apple Watch 在 30 天窗口内外的批准与重新批准流程（自动化只能注入时间戳，无法证明真实设备与固件
  在真实时间流逝后的行为）。

对应测试手册：[`../Testing/ConfigurationImportValidation.md`](../Testing/ConfigurationImportValidation.md)。
