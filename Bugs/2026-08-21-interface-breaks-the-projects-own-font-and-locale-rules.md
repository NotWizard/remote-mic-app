# 界面违反本仓库自己写下的字号与本地化规则

- 编号：A9
- 时间：2026-08-21
- 状态：已修复，自动化通过；**未做任何真实窗口渲染验收**
- 影响范围：设置窗口全部页面的小号文字（52 处）、附近连接与网页版授权弹窗（英文用户）、按键映射页遥控器插图（窄窗口）
- 功能点：`SettingsView`、`RemoteMappingCanvas`、`BridgeAppModel` 授权弹窗、两份 `Localizable.strings`
- 定位：**规范与实现长期脱节，其中两项是用户可见缺陷，一项是不可达但已写进验证工具的布局缺陷**

## 关于严重性的诚实定位

四个子项的成熟度完全不同，不能一起概括：

- **A9-1（字号）**：真实存在且所有用户可见。中文界面在 52 处以 10pt 或 11pt 渲染。
- **A9-2（弹窗中文硬编码）**：真实存在且英文用户必然命中。授权弹窗是安全决策界面，英文用户在此处看到全中文。
- **A9-3（遥控器插图被压）**：布局计算确实错误，但**在生产窗口下不可达**——`minSize` 为 1020 × 772，画布宽度不会低于 867pt。它可达的唯一路径是 `SettingsScreenshotRenderer`，该工具接受 `800 × 650` 并绕过最小尺寸；也就是说，用来满足 `AGENTS.md` 门禁的那个工具本身渲染的是重叠版本。
- **A9-4（`minSize` 与 `800 × 650` 门禁矛盾）**：`8b30824` 当次只出结论；后续 `a7b5c4d` 已把门禁改为跟随生产 `minSize`（`minSize` 未改），详见文末 A9-4 的更新。

**没有用户报告过这四项中的任何一项。** 全部来自代码审计。

## 复现

### A9-1 字号

只读复现：统计 `Sources/` 中低于 12pt 的文字样式。macOS 语义样式的实际磅值为 `.caption`/`.caption2`/`.footnote` = 10pt、`.subheadline` = 11pt。

```
SettingsView.swift        .caption 26 + .caption.weight(.bold) 3 + .caption.weight(.semibold) 1
                          + .caption2.weight(.medium) 1 + .subheadline 11
                          + .subheadline.weight(.semibold) 9            = 51
RemoteMappingCanvas.swift .caption                                      =  1
SettingsView.swift:3730   .font(.system(size: 10)) 作用于 Text(detail)   =  1
```

合计 53 处文字低于 12pt 门槛。错误行为：中文以 10pt / 11pt 渲染。正常边界：`.callout` = 12pt、`.body`/`.headline` = 13pt 本来就合规，未计入。

同时确认两处**不构成**违规，不做改动：

- `SettingsView.swift:1381` 的 `.font(.system(size: 7, weight: .bold))` 作用于 `Image(systemName: "bolt.fill")` 充电角标，是 SF Symbol 图形而非中文文字。
- `minimumScaleFactor(0.75)` 作用于 21pt 的统计数值，缩到底为 15.75pt，仍 ≥ 12pt。**当时合规，但没有任何机制保证它继续合规**——磅值和缩放系数是两行无关字面量。

### A9-2 授权弹窗

只读复现：`BridgeAppModel.swift` 中 11 处中文字面量，其中 10 处属于两个 `NSAlert`：

- `requestPhoneApproval`：标题、Apple Watch 说明、iPhone 说明、校验码无障碍标签、「允许连接」、「拒绝」
- `requestWebApproval`：标题、说明、校验码无障碍标签、「允许连接」、「拒绝」

错误行为：把语言切到英文后，这两个弹窗仍然全中文。正常边界：同一弹窗的第三个按钮已经走 `LocalizedMessage("connection.phone.cancel_waiting")`，说明机制本来就在，只是这两处没用。

另有 6 个文件含中文字面量，逐一核对后确认**不是界面文案**，不改：`KeyboardInjector.swift`、`VoiceInputDestinationCoordinator.swift`、`RemoteButtons.swift` 是窗口标题/输入框启发式匹配的关键词表，`RemoteVoiceFunctionMapper.swift` 是注释，`OnboardingScreenshotRenderer.swift` 是截图工具的窗口标题。

### A9-3 遥控器插图

只读复现，用布局函数直接算。遥控器照片是固定 202 × 410 的 frame，`.position` 钉在画布正中；配置卡片在 `ZStack` 中**晚于**照片绘制，因此卡片多占的宽度不是把照片压窄，而是盖住照片。

设置页内容宽度 = 窗口宽 − 108（侧栏）− 1（分隔线），映射页内容栈再各留 22pt padding，故画布宽 = 窗口宽 − 153。

原公式 `min(300, max(270, (canvasWidth - 260) / 2))` 中，`- 260` 就是中央通道（202 照片 + 两侧各 29pt），但 `max(270, ...)` 的下限**优先级高于**通道项。画布宽低于 800pt 后卡片被钉在 270pt，开始吃掉中央通道：

| 窗口宽 | 画布宽 | 卡片宽 | 卡片内缘到照片的间距 |
| --- | --- | --- | --- |
| 1020（生产最小） | 867 | 300 | +32.5pt |
| 895 | 742 | 270 | 0pt（间距耗尽） |
| 800（`AGENTS.md` 门禁） | 647 | 270 | **−47.5pt（每侧盖住照片 47.5pt）** |
| 600 | 447 | 270 | −146.5pt |

−47.5pt 这个数字由负向对照实测打印出来，不是手算：见「验证」。

## 根因

**A9-1**：规则写在 `AGENTS.md`，但实现里没有任何一个地方持有这条规则。52 个调用点各自写着一个语义样式名，而这些名字在 macOS 上恰好都低于门槛。审查是唯一的执行手段，于是它失效了。会话中较早一次修复（`CorruptedSettingsNotice` 提示条）改用显式 `.system(size: 12)` / `.system(size: 13)`，方向对，但只覆盖了那一处，反而多出第二套写法。

**A9-2**：这两个是 `NSAlert` 而不是 SwiftUI 视图，需要**已解析的字符串**而不是 `Text` 的 key。少了一步 `LocalizedMessage(...).text(using:)` 就能直接写字面量并且编译通过，这是它们退化成硬编码的直接原因。更糟的是失败模式很安静：key 缺失时 `LocalizationStore.text(_:)` 返回 key 本身，不崩溃，用户看到的是按钮上写着 `connection.approval.deny`。

**A9-3**：`max(270, ...)` 表达的是「卡片至少 270pt」，而真正不可让的约束是「中央 260pt 必须留给照片」。两个约束都写进了同一行 `min/max` 链，谁赢由数值大小决定，而不是由设计意图决定。照片不能反过来缩小——所有连接线锚点都是相对 `remoteSize` 的 `UnitPoint`，缩放照片会移动全部 13 个热点。

## 修复

### A9-1：六个字号 token，一处定义

新增 `Sources/RemoteMic/InterfaceFonts.swift`：

```swift
enum InterfaceTextStyle: String, CaseIterable {
    case caption, captionMedium, captionStrong, captionHeavy, body, bodyStrong
    var pointSize: CGFloat { ... }   // caption 系列 12pt，body 系列 13pt
    var weight: Font.Weight { ... }
    var font: Font { .system(size: pointSize, weight: weight) }
}
```

调用点通过 `extension Font` 写作 `.font(.appCaption)` 等。映射逐一保持原有字重，只抬升磅值：

| 原样式 | 磅值变化 | token | 站点数 |
| --- | --- | --- | --- |
| `.caption` | 10 → 12 | `appCaption` | 27 |
| `.caption.weight(.bold)` | 10 → 12 | `appCaptionHeavy` | 3 |
| `.caption.weight(.semibold)` | 10 → 12 | `appCaptionStrong` | 1 |
| `.caption2.weight(.medium)` | 10 → 12 | `appCaptionMedium` | 1 |
| `.subheadline` | 11 → 13 | `appBody` | 11 |
| `.subheadline.weight(.semibold)` | 11 → 13 | `appBodyStrong` | 9 |
| `.system(size: 10)`（`Text(detail)`） | 10 → 12 | `appCaption` | 1 |

`.subheadline` 选 13pt 而不是 12pt，是为了保住原有的「标题 / 正文」两级层次：仓库里已有几十处 `.system(size: 13, weight: .semibold)` 作为卡片标题，而较早那次 `CorruptedSettingsNotice` 修复也正是用 13 标题 + 12 正文。若两者都压成 12pt，层次只剩字重。

同时把该文件内已有的、与 token 完全等价的 12pt 与 13pt-semibold 字面量一并折叠进 token（含 `CorruptedSettingsNotice` 的两处标题），避免「token + 字面量」两套写法并存。**边界**：14pt 及以上的标题/图标字号、以及 `weight` 随状态变化的条件字号（如 `weight: selected ? .semibold : .regular`）保留字面量，它们既高于门槛也无法一对一映射到单个 token。`OnboardingView.swift` 未改动——它最小字号本就是 12pt，无违规。

最终 `SettingsView.swift` 92 处 + `RemoteMappingCanvas.swift` 6 处使用 token。

`minimumScaleFactor` 那处改为从 `InterfaceTypography` 读取磅值与系数，使「缩到底仍 ≥ 12pt」成为一条可断言的乘积，而不是两行互不相干的字面量。

### A9-2：两个弹窗走同一套 key

新增 `BridgeAppModel.ConnectionApprovalAlertText`，把两个弹窗的每一句都声明为 `LocalizedMessage`，并暴露 `referencedKeys`。之所以集中声明而不是在赋值处内联，正是为了让「key 缺失」可被测试枚举到。

两份 `Localizable.strings` 各新增 7 个 key（中文沿用原硬编码原文，用户无感知变化）：

```
connection.approval.nearby.title    connection.approval.watch.detail
connection.approval.phone.detail    connection.approval.web.title
connection.approval.web.detail      connection.approval.allow
connection.approval.deny
```

复用已有的 `connection.web.pairing_code_accessibility`（校验码无障碍标签）与 `connection.phone.cancel_waiting`（第三按钮），未重复造 key。

网页版弹窗与手机弹窗是同一类缺陷、同一段代码相邻两个函数，一并修复；只修其中一个会留下明显不一致。

### A9-3：中央通道不可让

```swift
static let centerChannelGap: CGFloat = 29
static let centerChannelWidth: CGFloat = remoteSize.width + centerChannelGap * 2

static func cardWidth(for canvasWidth: CGFloat) -> CGFloat {
    let widthAvailableForEachCard = max(0, canvasWidth - centerChannelWidth) / 2
    return min(preferredCardWidth, widthAvailableForEachCard)
}
```

去掉 270pt 下限，改为「卡片只能用通道之外剩下的宽度」。这保证对任意 `canvasWidth` 都有 `2 × cardWidth + 260 ≤ canvasWidth`，照片两侧恒有 ≥ 29pt 间距。窄窗口下改为卡片变窄，卡片文字本来就带 `.lineLimit(1)` 与 `.truncationMode(.tail)`。

**生产行为逐位不变**：画布 867pt 时 `(867 − 260) / 2 = 303.5`，取 `min(300, 303.5) = 300`，与原公式同值。页面结构、连接线控制点、箭头几何、锚点全部未动。

另新增 `cardToRemoteClearance(for:)`，把这条不变式变成一个可断言的数值。

## 验证

- `swift test`：**本次改动单独作用时 EXIT=0，325 项 / 28 个 suite 全部通过**（见下方「与并发改动的隔离验证」）。基线为 313 项 / 26 个 suite，本次贡献 12 项（`InterfaceTypographyTests` 5 项、`RemoteMappingCanvasGeometryTests` 6 项、`LocalizationTests` 1 项）。
  共享工作区中执行同一命令目前为 **EXIT=1，336 项 / 29 个 suite，2 个 issue**：多出的 11 项与 1 个 suite（`XiaomiBluetoothBridgeSessionTests`）以及那唯一一项失败（`RemoteButtonsTests.aPressDeclinedByRoutingIsLoggedAsDeclinedNotAsAMissingProfile`）均来自同一工作区中另一代理的并发改动，不属于本次交付，也不由本次改动引起。
- `./scripts/test.sh`：**EXIT=0，`RESULT passed=42 failed=0`**（共享工作区实测）。
- `./scripts/check-repository-boundaries.sh`：**EXIT=0，`REPOSITORY BOUNDARY PASS`**（共享工作区实测）。
- 三条命令均独立执行、各自重定向到日志后单独读取 `$?`，未经管道。

### 负向对照（逐项人工打断，确认变红，再逐字节还原）

| 打断方式 | 结果 |
| --- | --- |
| `InterfaceTextStyle` 的 caption 系列磅值 12 → 11 | `everyTextTokenClearsTheTwelvePointFloor` 4 个 issue 变红；`corruptedSettingsBanner...` 4 个 issue、`mobileConnectionStatusMeetsFontAndSnapshotGates` 1 个 issue 同时变红 |
| 仅从 `en.lproj` 删除 `connection.approval.deny` | 新测试与既有键集对齐测试**同时**变红 |
| 从**两份**文件都删除 `connection.approval.deny` | 既有键集对齐测试**通过**（它只做两文件互比），新测试**变红**（`localized[key] → nil`）——证明新测试补上的正是既有测试看不见的缺口 |
| 把 `en.lproj` 的该 key 值改成中文「拒绝」 | 新测试变红：`!(containsCJKText("拒绝") → true)` |
| `cardWidth` 还原为 `min(300, max(270, (canvasWidth - 260) / 2))` | 3 个几何测试变红；门禁窗口实测打印 `cardToRemoteClearance(for: gateCanvas) → -47.5`，以及扫描区间内 −0.5pt 一直到 −147.5pt 的大量 issue |

还原后，对四个被打断的文件逐一与「打断前立即制作的备份」做字节比对，全部 `IDENTICAL`：

```
IDENTICAL  Sources/RemoteMic/InterfaceFonts.swift
IDENTICAL  Resources/en.lproj/Localizable.strings
IDENTICAL  Resources/zh-Hans.lproj/Localizable.strings
IDENTICAL  Sources/RemoteMic/RemoteMappingCanvas.swift
```

（更正一处自查失误：最初试图对「7 个已跟踪文件的 `git diff` + 2 个新增文件全文」取一个总 SHA-256，但该命令在 zsh 下把未加引号的变量当作**单个** pathspec，实际没有匹配到任何文件，那个哈希只覆盖了两个新增文件，不足以证明已跟踪文件已还原。上面的逐文件字节比对是实际有效的证据。）

### 与并发改动的隔离验证

交付时同一工作区内另有代理正在编辑 `XiaomiBluetoothBridge.swift`、`BluetoothLifecycle.swift` 与 `RemoteButtonsTests.swift`，其 `RemoteButtonsTests.aPressDeclinedByRoutingIsLoggedAsDeclinedNotAsAMissingProfile` 当前为红。为确认与本次改动无关，把 `HEAD` 用 `git archive` 导出到独立目录，**只覆盖本次改动的 9 个文件**（其余保持 `HEAD`），在该目录单独执行：

```
ISOLATED swift test EXIT=0
✔ Test run with 325 tests in 28 suites passed
```

325 = 基线 313 + 本次 12，28 = 基线 26 + 本次 2，逐项吻合。**本次改动单独作用时全绿**；共享工作区里那一项红色属于另一代理的进行中改动，涉及 `HIDRemoteMonitor` 的日志路径，与本次改动的文件无交集。

### 测试形态说明

三项证据都不是「grep 源码找字符串」：

- 字号：断言 `InterfaceTextStyle.allCases` 的 `pointSize` 与 `font` 真实值。
- 本地化：断言生产代码实际请求的 `referencedKeys` 在两份 `.strings` 中都能解析出非空值、占位符数量与调用点传参一致、且英文值不含 CJK 字符。
- 布局：断言 `cardToRemoteClearance` 在 600–2000pt 窗口逐 1pt 扫描下恒 ≥ 29pt，并校验该间距与连接线终点 `cardEdgePoint` 描述同一条边。

两处**既有**源码文本断言被改写而非删除：`mobileConnectionStatusMeetsFontAndSnapshotGates` 与 `corruptedSettingsBannerIsInlineAndNeverShrinksChineseBelowTwelvePoints` 原先钉的是字面量 `.font(.system(size: 12, weight: .semibold))`，该字符串已不存在。改为要求命名 token，并各自补上一条基于真实值的磅值断言。提示条测试仍保留「禁用语义样式」「禁用 Sheet/Popover」「必须挂在映射页」三组原有保护，且新增「token 数 + 显式字号数必须等于 `.font(` 总数」，防止出现第三套未被检查的写法。

## 自动化与真机边界

**本会话无法渲染界面、无法截图、无法打开真实窗口。以下全部未验证，需要人工在真实窗口上看：**

1. 52 处字号抬升（10 → 12、11 → 13）后的实际排版。`.subheadline` 抬 2pt 会让文字变宽变高，**固定高度容器存在裁切风险**，其中 `RemoteMappingCanvas` 的卡片高度硬编码为 72pt，标题从 13pt 未变但页面内其它卡片受影响，必须逐页确认无裁切、无换行溢出、无按钮挤压。
2. 中英文两种语言下全部侧边栏页面的观感与层次是否仍然可读。
3. 两个授权弹窗的英文实际文案长度是否导致 `NSAlert` 异常换行或过宽；英文说明比中文长，需在英文系统下真机触发一次 iPhone 连接与一次 Apple Watch 连接、一次网页版扫码。
4. 按键映射页在窄窗口下的实际观感。**注意：由于 `minSize` 为 1020 × 772，用户无法把窗口拖到触发该分支的宽度**，因此这一项只能通过 `SettingsScreenshotRenderer`（`REMOTE_MIC_SETTINGS_SCREENSHOT_SIZE=800x650`）渲染验证，或在 A9-4 决策后验证。
5. 统计页数值在缩放到 15.75pt 时的实际可读性。

四项 fork 专有行为（可配置语音触发键、外接麦克风采集、右侧修饰键不粘滞、自定义快捷键左右保真）**未做真机回归**；本次改动不触碰蓝牙、HID、音频与按键注入路径，`XiaomiBluetoothBridge.swift`、`BluetoothLifecycle.swift`、`BluetoothLifecycleTests.swift` 未被本次改动修改（由另一代理并发编辑）。

对应测试手册：[`Testing/InterfaceFontAndLocaleCompliance.md`](../Testing/InterfaceFontAndLocaleCompliance.md)。

## A9-4：`minSize` 与 `800 × 650` 门禁的矛盾——结论与后续落地

`AGENTS.md:64` 曾要求「设置页面内容或容器发生变化时，至少在 `800 × 650` 窗口逐一点击全部受影响的侧边栏入口」。生产 `RemoteMicApp.swift:721` 的 `window.minSize = NSSize(width: 1020, height: 772)` 使该窗口尺寸不可达，门禁按字面无法执行。**本节写于 `8b30824` 时确为「只出结论、未实施」；此后 `a7b5c4d` 已把 `AGENTS.md:64` 改为跟随当前生产 `minSize`（现为 `1020 × 772`，见 `RemoteMicApp.swift`）而不写死尺寸，`minSize` 本身仍未改。** 下文「最小的诚实调和方案」的三步现已落地，见该节末尾的更新。

### 哪一个是过期物：`AGENTS.md` 的 `800 × 650`

由提交历史确定，不是推断：

| 时间 | 提交 | `window.minSize` |
| --- | --- | --- |
| 2026-07-23 | `0823d74` | **800 × 650** |
| 2026-08-05 01:56 | `67f2c42` | 860 × 700 |
| 2026-08-08 | `0da5b7e` | 1000 × 720 |
| 2026-08-09 | `f7d93a1` | **1020 × 772**（同一提交新建 `RemoteMappingCanvas.swift`，即居中遥控器映射页） |

而 `800 × 650` 门禁写入 `AGENTS.md` 的提交是 `b08db6b`，时间 2026-08-05 **00:06**。也就是说：门禁写下时 `minSize` 正是 800 × 650，**当时准确且可执行**；1 小时 50 分钟后 `67f2c42` 把最小宽度提到 860，门禁当晚即失效，此后 16 天内又抬升两次，`AGENTS.md` 一直没跟。

结论：`1020 × 772` 是四次为容纳真实内容而做的产品决定，最后一次正是居中遥控器映射页；`800 × 650` 是一条被产品演进甩开的、从未回填的旧文档常量。

### 若 `minSize` 降到 800 × 650 会坏什么

已由代码确认（页面内容宽 = 800 − 109 = 691，去掉左右各 22pt padding 后可用 647）：

1. **映射页页头（`SettingsView.swift:988`–`998`）最可能真正裁切。** 该行是 `PageHeader` + 启用开关 + `Spacer()` + `remoteDeviceSelector().frame(width: 400)`。固定 400pt 的遥控器选择器只留下约 247pt 给页面标题与开关；在 1020 下同一行有约 467pt。这正是门禁措辞里点名的「页头」。
2. **关于页语言选择行（`SettingsView.swift:2628`）** 同样内联固定 400pt 分段控件，加图标 34pt 与 20pt 间距后只剩约 193pt 给标签与说明文字。
3. **映射卡片可读性下降（非裁切）。** 修复后画布 647pt 时卡片为 193.5pt，每张卡要放三个触发按钮，约 60pt/个，动作摘要会被大量省略。照片本身不再被盖住。
4. **高度 650 比 772 少 122pt。** 映射页画布是固定 570pt 高，加 56pt 拖拽区与页头后需要 700pt 以上，实际会依赖滚动；门禁本身也要求确认「滚动未裁切」。
5. 三处 `.frame(width: 540)`（邀请码）、`.frame(width: 640, height: 520)`（版本历史）位于 Sheet 内，Sheet 自行定尺寸，**不受 `minSize` 影响**。

另发现一处第三个常量在漂移：`SettingsView.init` 的 `minimumContentSize` 默认值是 `CGSize(width: 980, height: 732)`，既不等于生产的 1020 × 772（生产显式传入），也不等于门禁的 800 × 650；截图工具传 `.zero`。

`Testing/` 目录同样已经分裂：`AboutUpdateCenter.md`、`FirstRunOnboarding.md`、`FirstUseSuccess.md` 写 `1020 × 772`，而 `VoiceTriggerKey.md`、`ConfigurationImportValidation.md`、`QuickCommandsPrivateIntegration.md`、`CustomApplicationFocus.md` 写 `800 × 650`。其中 `CustomApplicationFocus.md:149` 是**已勾选**的 `[x]`「按键映射页面在 `800 × 650` 窗口下没有裁切」——这一条不可能在生产窗口上真实执行过，因为窗口拖不到那个尺寸。

### 最小的诚实调和方案（建议，待用户决定）

**把门禁尺寸改成跟着生产最小尺寸走，而不是写死一个数。** 具体三步，改动量最小且不牵动产品决定：

1. `AGENTS.md:64` 的 `800 × 650` 改为「生产 `window.minSize`（当前 `1020 × 772`）」，并说明该值以 `RemoteMicApp.swift` 为准。这样门禁永远可执行，且不会再被下一次抬升甩开。
2. 增加一条真正可自动执行的补充门禁：`SettingsScreenshotRenderer` 已支持 `REMOTE_MIC_SETTINGS_SCREENSHOT_SIZE`，可要求在生产最小尺寸下渲染全部 5 个页面；它绕过 `minimumContentSize`，是本仓库唯一能跑「窗口级」检查的现成工具。
3. 把 `Testing/` 中 4 份写 `800 × 650` 的手册统一到同一表述，并把 `CustomApplicationFocus.md:149` 那个已勾选项退回未验证——它记录的是一次不可能发生的验收。

不建议把 `minSize` 降到 800 × 650：那要求重做映射页页头与关于页语言行的固定 400pt 布局，属于产品级返工，与本次四个缺陷无关；上面第 1 条是不改产品行为就能让门禁重新可执行的最小改法。

**更新（后续已落地）**：上述三步现已实施，`minSize` 本身按建议未改。第 1 步由 `a7b5c4d` 完成（`AGENTS.md:64` 改为跟随生产 `minSize`）；第 2 步由 `SettingsPageRenderingTests`（`a908e11`）以离屏渲染器覆盖 5 个页面；第 3 步在整改收尾轮统一了余下写 `800 × 650` 的手册（`VoiceTriggerKey.md`、`ConfigurationImportValidation.md`、`QuickCommandsPrivateIntegration.md`）并把 `CustomApplicationFocus.md:149` 那个已勾选项退回未验证。

（原文此处曾写「以上三步本次一步都没做」，那只适用于 `8b30824` 那次会话；后续提交已按上述更新落地，故删去该句以免与实际提交矛盾。）
