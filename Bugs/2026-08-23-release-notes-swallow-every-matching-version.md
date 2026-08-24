# 发布说明会把四个版本的内容拼成一份

## 复现与现场证据

不需要真机。在当前 `main` 上直接跑发布脚本用的提取逻辑：

```
VERSION=1.8.25   # 来自 Resources/Info.plist 的 CFBundleShortVersionString
```

`scripts/publish-release.sh` 的 `generate_release_notes()` 用这个 `VERSION` 从
`Resources/zh-Hans.lproj/ReleaseHistory.md` 里抽取本次发布的条目。实测抽出 **38 行**，
内容依次包含 `1.8.25-fork.4`、`1.8.25-fork.3`、`1.8.25-fork.2` 和 `1.8.25（预发布）`
四个版本的全部说明——而 fork.4 自己只有 13 行。

正常行为边界：一次发布的说明只应描述这一次发布。

## 根因

原始 awk 规则顺序如下（`publish-release.sh:191-195`）：

```awk
index($0, "## " version) == 1 { active = 1; next }
active && /^## / { exit }
active { print }
```

awk 按顺序匹配规则。问题出在 `index(...) == 1` 是**前缀**匹配，而本仓的版本号互为前缀：
`## 1.8.25-fork.3（本分支）` 也满足 `index($0, "## 1.8.25") == 1`。于是走到 fork.3 的标题时，
**第一条规则先命中**，`next` 直接跳过后面所有规则——本该终止抽取的 `exit` 永远不会执行。
每遇到一个共享前缀的标题就重新 `active = 1`，一路吞到文件末尾。

关键点是 `VERSION` 取自 `Info.plist` 的 `CFBundleShortVersionString`，值是裸的 `1.8.25`；
fork 后缀只存在于 tag 和 ReleaseHistory 标题里。所以这个缺陷在本 fork 上是**必然触发**，
不是边角情况。

**这不是本次引入的**：fork.2 和 fork.3 两次发布的说明同样被污染，且每加一个 fork 条目就多吞一段。

为什么一直没被发现：`scripts/test-preview-branch-lifecycle.sh` 用的是 `1.8.14`、`1.8.15`、
`1.8.16`，彼此都不是前缀，正好绕过了这条路径。

## 修复

把提取逻辑抽到 `scripts/extract-release-notes.sh`，并**把终止规则放到匹配规则之前**：

```awk
active && /^## / { exit }
index($0, "## " version) == 1 { active = 1; next }
active { print }
```

这样一旦 `active`，任何 `^## ` 行都会先命中 `exit`，前缀相同的后续标题再也没机会重新激活。
`publish-release.sh` 改为调用该脚本，逻辑只有一处，测试可以直接驱动它——原先内嵌在
shell 函数里，任何测试都碰不到。

抽成独立脚本而不是就地改顺序，是因为就地改顺序无法被测试覆盖：测试要么重复一遍 awk
（那就变成测试自己的副本，生产坏了照样绿），要么断言脚本源码文本（正是本轮在消除的东西）。

## 第二个缺陷：GitHub 正文只有中文

`Release_Notes_Guidelines.md` 明确要求「中文全文在前，英文全文在后，不得逐行交替」。
但 `publish-release.sh:622` 用 `--notes-file "$RELEASE_NOTES"` 作为 Release 正文，而
`$RELEASE_NOTES` 只从 `zh-Hans` 抽取——英文用户看到的是一份纯中文说明。

仓库里已经有 `ZH_RELEASE_NOTES` / `EN_RELEASE_NOTES` 两份本地化文件，但那是给 Sparkle
appcast 用的更新说明，与 GitHub 正文是两条不同的路径。所以「有英文文件」并不代表正文有英文。

**修复**：新增 `scripts/compose-release-body.sh`，按「中文全文 → 分隔线 → 英文全文」组装，
并对两种语言各做一次「必须有 `- ` 列表项」检查。任一语言缺条目就报错退出，而不是默默发一份
半翻译的说明——沉默降级正是本轮一直在消除的失败模式。`publish-release.sh` 改为调用它。

同样抽成独立脚本，理由与上一节一致：留在 shell 函数里的逻辑没有任何测试碰得到。

**验证过程中发现并修掉的第三个问题**：`print "---"` 在 zsh 里不会输出 `---`——`print` 把
前导短横当选项解析，分隔线整行消失，两种语言会直接连在一起。必须写成 `print -r -- "---"`。
第一版测试没抓到它（只断言了顺序和标题存在），已补上对分隔线的断言。

（记录一次我自己的误判：中途我用 `grep -n "^---$\|^## "` 检查，BSD grep 对 `\|` 的处理让我
误以为加了 `--` 之后分隔线仍然缺失。实际用 `grep -c '^---$'` 单独查是有的；能确认 `print "---"`
确实丢行的证据是负向对照，不是那次 grep。）

## 验证

`Tests/RemoteMicTests/ReleaseNotesExtractionTests.swift`，9 项，全部驱动真实脚本与真实字节。抽取部分 5 项：

- 裸版本号必须停在下一个标题，不得吞掉任何 fork 条目（三条"不得包含"断言）
- 精确 fork 版本只抽自己那一段
- 文件里最后一个条目仍能被抽出（`exit` 前置不能让末尾条目漏掉）
- 不存在的版本返回空，而不是别人的说明
- 中英两份 ReleaseHistory 的当前首条都能抽出 `- ` 列表项，满足 `publish-release.sh` 的
  `rg -q '^- '` 门禁

正文组装部分 4 项：

- 正文必须同时含两种语言，且中文出现在英文之前，并含分隔线；两半都不得夹带邻近版本
- 缺英文条目必须报错退出，不得只发中文
- 缺中文条目同样报错退出
- 仓库当前首条能真实组装出中英双语正文（`## 更新内容` 在 `## What's New` 之前）

**负向对照**：把规则顺序改回原样 → 退出码 1，恰好 3 处失败，就是那三条"不得包含旧条目"
的断言；恢复后与备份逐字节相同（`diff -q` 无输出）。

命令输出（各自单独执行，退出码单独取）：

- `swift test --filter ReleaseNotesExtraction` → 退出 0，5 项通过
- 负向对照同一命令 → 退出 1，3 处 issue
- `swift test` → 退出 0
- `./scripts/test.sh` → 退出 0，`RESULT passed=42 failed=0`
- `./scripts/check-repository-boundaries.sh` → 退出 0

## 自动化与真机边界

- 本项完全是构建期文本处理，**不涉及任何硬件**，也不改 App 运行时行为；`swift build` 与
  `build-app.sh` 的通过只说明没有连带破坏。
- 未验证：`publish-release.sh` 的**完整**发布流程从未在本会话真实执行过（需要签名证书、
  公证和远端写权限）。本项只证明了被抽出的文本正确，没有证明整条发布链路可用。
- 已发布的 fork.2、fork.3 两个 Release 的说明**仍是被污染的**；本修复不会追溯改写它们，
  需要时得手动编辑那两个 Release 的正文。

## 后续：一个条目内部也有 `## ` 标题（1.8.25-fork.4）

`Release_Notes_Guidelines.md` 要求正文按「⚠️ 注意事项 / 🎉 新功能 / ✨ 改进 / 🐛 问题修复」
分节。这四个标题写在**同一个版本条目内部**，于是上面那条「一旦 active，任何 `^## ` 行都 exit」
会在第一个分节标题处截断，整段说明变成空。

终止规则因此改成允许清单，而不是放开所有 `## `：

```awk
active && /^## / && !is_section_heading($0) { exit }
```

只有这四个分节标题算条目内部结构，其他 `## ` 标题照旧终止。方向是刻意选的：一个条目被
未知标题截断是看得见的缺失，而把未知标题当成内部结构会重新把两个版本合成一份正文——正是
本文件记录的那个更糟的失败。

**同一份 awk 的第二个副本**：`scripts/notarize-release.sh` 的 `extract_release_notes()` 里还留着
最初的顺序（先匹配后终止），Sparkle 的纯文本更新说明一直是用它生成的，因此同样吞掉了
`1.8.25-fork.*` 的其他条目；加上分节标题后它会先在 `## ⚠️` 处终止，输出为空并被自己的
`rg -q '^- '` 拦下，整条签名/公证链路会直接失败。现在它调用共享脚本的 `--bullets-only`，
逻辑仍然只有一处。

`Tests/RemoteMicTests/ReleaseNotesExtractionTests.swift` 由 9 项增加到 16 项、1 套增加到 2 套：新增分节标题必须
保留、非分节标题仍必须终止、`--bullets-only` 必须取到分节下的每一条且不越界、中英两份条目的
分节与条目数必须一致，以及 App 内 Sheet 的分节过滤 2 项；原先「当前首条不得含 `## `」的断言换成与文件自身切片逐字节相等。
**不是单纯变强**：新断言能抓越界和截断（旧断言抓不到截断），但旧断言禁止任何标题，因此能抓到
「用分节 emoji 开头的版本标题」这一种合并，新断言抓不到——复核用 `## 🎉 9.9.8 …` 实测两条确实会并成一条。
该缺口最初按残余风险记录，**现已补上守卫**，见下节「第四个缺陷」。

**负向对照**：把终止规则改回 `active && /^## / { exit }` → `swift test --filter ReleaseNotesExtraction`
退出 1，5 项失败共 28 处 issue（含 `theCurrentTopEntryComposesABilingualBody` 的 `status == 1`，
即发布脚本会拒绝空正文）；恢复后与备份 `diff -q` 无输出。全量 `swift test` 退出 0，361 项 / 33 套。

**边界**：`notarize-release.sh` 的这段改动只在本地用真实历史文件按同一命令核对过输出，
完整签名与公证流程没有在本次执行；App 内「版本历史」Sheet 的分节过滤有单元覆盖（去掉守卫后
负向对照报 11 处 issue，含 `sections.count → 4` 与卡片标题变成 `⚠️ 注意事项`），但**没有真实窗口渲染验收**，
按 `Testing/AboutUpdateCenter.md` 的回归项做真实 UI 验收。

## 第三个缺陷：置顶的注意事项其实没有置顶

### 复现

不需要真机。直接跑组装脚本：

```
zsh scripts/compose-release-body.sh 1.8.25-fork.4 \
  Resources/zh-Hans.lproj/ReleaseHistory.md Resources/en.lproj/ReleaseHistory.md
```

正文里的标题顺序（`grep -n '^#'`）：

```
1:## 更新内容
4:## ⚠️ 注意事项
12:## ✨ 改进
16:## 🐛 问题修复
29:## What's New
32:## ⚠️ Heads-up
40:## ✨ Improvements
44:## 🐛 Bug fixes
```

`Release_Notes_Guidelines.md` 要求有注意事项时必须置顶，并且「正文直接从一句话开场或第一个分节开始」。
实际用户看到的第一个标题是 `## 更新内容`。

正常行为边界：每种语言的第一个标题就是该语言的第一个规范分节。

### 根因

`compose-release-body.sh:33,38` 给两种语言各加了一个包裹标题。`## 更新内容` 和 `## What's New`
与规范固定的四个分节**同级**，于是它们既排在注意事项之前，又在 GitHub 依标题生成的大纲里
多出两个不属于规范清单的条目。注意事项在条目内部确实是第一个分节，但在正文里不是第一个标题。

### 修复

删掉两个包裹标题，语言分界只保留原有的 `---`。选分隔线而不是换成 `###` 或加一个语言标签：
任何标题都会重新进入标题层级和大纲，并再次挤到 `## ⚠️` 前面，也就是把同一个缺陷换个字号；
分隔线是唯一既能划出可见边界、又完全不参与标题层级的 Markdown 结构。分隔线前后各补一个空行，
避免未来某个条目以普通段落结尾时 `段落 + ---` 被解析成 setext 标题。`print -r -- "---"` 的
`--` 保留不动——去掉它 zsh 会把前导短横当选项，整行消失。

修复后同一命令的标题顺序：

```
2:## ⚠️ 注意事项
10:## ✨ 改进
14:## 🐛 问题修复
29:## ⚠️ Heads-up
37:## ✨ Improvements
41:## 🐛 Bug fixes
```

`^---$` 恰好 1 行，`^# ` 0 行。

### 验证

`theCurrentTopEntryComposesABilingualBody` 的断言从「含 `## 更新内容`、含 `## What's New`、前者在后者之前」
换成对整份正文的约束：分隔线恰好 1 条、正文无 H1、按分隔线切成两半后**每一半的每一个标题都必须是
该语言的规范分节**、第一个标题必须是规范分节、有注意事项时它必须是该半的第一个标题、分节顺序与规范一致、
两半各自都有 `- ` 列表项。旧断言只钉住 2 个标题，新断言钉住全部标题，并且能抓到旧断言抓不到的
「多出一个同级标题」「注意事项不在最前」「出现 H1」。

**负向对照**：把两个包裹标题加回去 → `swift test --filter ReleaseNotes` 退出 1，
`theCurrentTopEntryComposesABilingualBody` 单项 10 处 issue（两半各 4 处，加 2 处
「不得含包裹标题」）；恢复后与备份 `diff -q` 无输出。

### 自动化与真机边界

- 纯构建期文本处理，不涉及硬件，也不改 App 运行时行为。
- **未验证**：没有真的创建 GitHub Release，因此「GitHub 网页上渲染出来的样子」只由 Markdown 结构推断，
  没有页面截图证据；`publish-release.sh` 完整链路同样未执行。

## 第四个缺陷：带分节表情的标题既可能合并两个版本，也可能静默丢掉一个分节

### 复现

不需要真机。两个方向都实测过。

**方向一（合并）**：允许清单只比对开头的表情符号，于是构造：

```
## 9.9.9（本分支）

## ⚠️ 注意事项

- Current heads-up bullet

## 🐛 问题修复

- Current fix bullet

## 🎉 9.9.8 emoji-prefixed version

- NEXT VERSION BULLET THAT MUST NOT MERGE

## 9.9.7（本分支）

- Older bullet
```

`zsh scripts/extract-release-notes.sh 9.9.9 <file>` 的输出包含
`## 🎉 9.9.8 emoji-prefixed version` 和 `- NEXT VERSION BULLET THAT MUST NOT MERGE`——
正是本文件开头那个「两个版本并成一份正文」的失败。

**方向二（静默截断，复核阶段发现，是真实缺陷不是假设）**：先按「标题里出现数字就是版本标题」
修过一轮，复核用一个合法分节加批次号构造：

```
## 1.9.0

## ⚠️ 注意事项

- 旧版配置需要重新导入。

## 🐛 问题修复（第 2 批）

- 修复了连接后立刻断开的问题。
- 修复了音频卡顿。

## 1.8.0
```

`第 2 批` 里的数字使条目在中途终止。实测（修复前）：

- `zsh scripts/extract-release-notes.sh 1.9.0 zh.md` 退出 0，输出只有注意事项一节，两条修复消失；
- `zsh scripts/compose-release-body.sh 1.9.0 zh.md en.md` 退出 0，正文就是这份被截断的说明；
- `publish-release.sh:192` 与 `notarize-release.sh:237` 的门禁都是 `rg -q '^- '` 存在性检查，
  注意事项那一条列表项就足以让**两个门禁都通过**。

也就是说面向用户的修复同时从 GitHub 正文和 Sparkle 更新说明里消失，全链路没有任何报错。

正常行为边界：一次发布的说明只应描述这一次发布，并且必须包含这次发布写下的全部分节。

### 根因

两次都栽在「用一条启发式规则猜标题是什么」上。

- 前缀判定（`以 ## ⚠/🎉/✨/🐛 开头即分节`）把命名版本的标题当成条目内部结构 → 合并。
- 数字判定（`标题含数字即版本`）把带批次号的分节当成下一个版本 → 静默丢分节。

上一轮把数字判定写成「安全方向」，理由是「截断看得见，且空正文会被两个 `- ` 门禁拦下」。
这个理由不成立：门禁只在整条说明**一条列表项都不剩**时才触发，而只有当带数字的标题恰好是第一个
分节时才会出现这种情况。带数字的标题出现在中间时，前面的列表项照样让门禁通过。

### 修复

不再猜。条目内部遇到 `## ` 标题只有三种结局：

1. 与八个规范分节标题（四个分节 × 两种语言）之一逐字节相等 → 条目内部结构，保留；
2. 以规范分节表情开头但不等于其中任何一个 → **歧义，退出码 3，stderr 指出该标题和所在文件**；
3. 其他 → 下一个版本，终止条目（这是本脚本最初的版本边界行为，保持不变）。

八个字符串是抄来的不是编的：`## ⚠️ 注意事项`、`## ✨ 改进`、`## 🐛 问题修复`、`## ⚠️ Heads-up`、
`## ✨ Improvements`、`## 🐛 Bug fixes` 直接取自两份 `Resources/*.lproj/ReleaseHistory.md`
（`⚠️` 带 U+FE0F）；两个 `## 🎉` 取自 `Release_Notes_Guidelines.md` 与 `AGENTS.md`，因为至今没有
一个已发布条目用过新功能分节。

「相等」的宽松度只放开尾随空白（空格、Tab、CRLF 的 `\r`）：这三种在 Markdown 里渲染结果相同。
`##` 后多一个空格、表情后少一个空格、大小写不同、缺 U+FE0F、后面多几个字，全部算第 2 种结局，
因为这些正是前缀判定当年放过去的近似匹配。

**另一个真实陷阱**：`/usr/bin/awk`（one-true-awk 20200816）的 `==` 走 locale 排序表，
在 `en_US.UTF-8` 下两个由排序表未覆盖字符组成的标题会相等——
`"## 🎉 版本九点九点八" == "## 🐛 问题修复"` 为真，允许清单会退化成「凡是奇怪的都算分节」。
因此 awk 用 `LC_ALL=C` 调用，并且比较写成 `length` + `index` 的逐字节实现，两道都留着：
只删掉其中一道不会重新打开这个洞。

### 验证

`extract-release-notes.sh` 的实测（`kind` 说明该标题**是什么**，决定正确答案；
「旧」= 复核前的前缀判定版本，即 `git show HEAD:`）：

| kind | 候选标题 | 新退出码 | 下一段是否进来（新/旧） | 结果 |
| --- | --- | --- | --- | --- |
| section+批次号 | `## 🐛 问题修复（第 2 批）` | 3 | 否 / 是 | 拒绝，不再静默丢分节 |
| version | `## 🎉 9.9.8 emoji-prefixed version` | 3 | 否 / **是** | 拒绝，旧版会合并 |
| version | `## 🎉 v9.9.8 (this fork)` | 3 | 否 / **是** | 拒绝，旧版会合并 |
| version | `## 🎉 版本九点九点八`（无 ASCII 数字） | 3 | 否 / **是** | 拒绝，数字规则抓不到的一种 |
| version | `## 🎉 ９.９.８ fullwidth digits`（全角） | 3 | 否 / **是** | 拒绝，数字规则抓不到的另一种 |
| 近似 section | `## ⚠️ HEADS-UP`（大小写不同） | 3 | 否 / 是 | 拒绝 |
| 近似 section | `## ⚠️Heads-up`（表情后无空格） | 3 | 否 / 是 | 拒绝 |
| 近似 section | `## ⚠ 注意事项`（缺 U+FE0F） | 3 | 否 / 是 | 拒绝 |
| 近似 section | `## 🎉`（只有表情） | 3 | 否 / 是 | 拒绝 |
| 近似 section | `##␠␠⚠️ 注意事项`（`##` 后多空格） | 3 | 否 / 否 | 拒绝（旧版静默截断） |
| section | `## ⚠️ 注意事项␠␠␠`（尾随空格） | 0 | 是 / 是 | 正确保留在条目内 |
| section | `## 🐛 问题修复` | 0 | 是 / 是 | 正确保留在条目内 |
| section | `## ⚠️ Heads-up` | 0 | 是 / 是 | 正确保留在条目内 |
| version | `## 9.9.8（本分支）` | 0 | 否 / 否 | 正确终止 |
| version | `## 9.9.8 🎉 shipped`（表情不在开头） | 0 | 否 / 否 | 正确终止 |
| foreign | `## 新功能`（缺表情） | 0 | 否 / 否 | 正确终止 |
| foreign | `## Something else entirely` | 0 | 否 / 否 | 正确终止 |

整张表在 `LANG=en_US.UTF-8` 和 `LANG=zh_CN.UTF-8` 下逐行一致。

**错误传播**（按两个调用方各自的写法实测，不靠推断）：

- `compose-release-body.sh` 用 `zh_body="$(...)"` 取值，zsh 在 `set -euo pipefail` 下会因命令替换
  失败直接退出：实测退出码 3、标准输出 0 字节，`publish-release.sh` 的 `rg -q '^- '` 根本轮不到执行。
- `notarize-release.sh` 的 `extract_release_notes()` 是「函数内重定向 + `rg -q`」，同样在
  `set -euo pipefail` 下退出 3；用该函数原文做的复刻脚本实测在第一次抽取处停下，
  `generate_appcast`、`sign_update` 与后续发布步骤都没有执行。换成改好标题的同一份文件后复刻脚本退出 0。
- 失败时目标文件里会留下截断的半份 Sparkle 说明。整条链路已经中止，且下次运行以 `>` 覆盖，
  不会被 appcast 取用；但这份残留文件确实存在。
- `package-macos-release-variants.sh` 顺序模式在 `set -e` 下直接失败，并行模式显式
  `exit 1`（`parallel signed release variant packaging failed: … exit=3`）。

**历史一致性**：中英两份 `ReleaseHistory.md` 各 55 个 `## ` 标题（其中 52 个是版本标题）。
按「每个标题原文 + 其数字前缀」两种键 ×「默认 + `--bullets-only`」两种模式 × 两份文件 = 440 次抽取，
与 `git show HEAD:scripts/extract-release-notes.sh` 逐字节比较，**0 处差异**，0 次空输出，
列表项累计 1458 行。再与分节功能之前的最初版本（`git show 7c21157:`）比，52 个版本里 51 个完全相同，
唯一不同的是最新条目 `1.8.25-fork.4`——它现在合法地包含自己的分节标题，这正是分节改动本身的预期结果。

**新增与加强的回归项**（`Tests/RemoteMicTests/ReleaseNotesExtractionTests.swift`，共 22 项 / 2 套）：

- `aHeadingWearingASectionEmojiWithoutBeingOneIsRefused`：10 个歧义标题 × 两种模式都必须非 0 退出，
  stderr 必须同时含该标题和文件名，且输出里不得出现歧义标题之后的任何内容；
- `theRefusalStopsTheComposedBodyInsteadOfPublishingASubset`：复核那个中途截断的输入，
  先断言「截断后的输出仍含列表项」（说明 `- ` 门禁为何拦不住），再断言 `compose-release-body.sh` 非 0 退出、正文为空；
- `theSectionMatchIsByBytesNotByLocaleCollation`：同一输入在 `en_US.UTF-8`、`zh_CN.UTF-8`、`C` 三种 locale 下都必须拒绝；
- `anExactMandatedSectionHeadingStaysInsideTheEntry`：八个规范标题加一个带尾随空格的变体必须留在条目内；
- `aHeadingWithoutALeadingSectionEmojiStillEndsTheEntry`：版本标题、无表情标题、表情不在开头的标题必须仍然终止条目；
- `everyShippingSectionHeadingIsStillTreatedAsInnerStructure` 的断言由
  `dropFirst(3).first?.isNumber != true` 换成「必须属于八个规范标题」。旧断言比脚本的规则弱：
  `## 🐛 问题修复（第 2 批）` 与 `## 🎉 版本九点九点八` 都能通过旧断言，而脚本现在直接拒绝这两种，
  所以旧断言抓不到发布文件漂移成这类标题（实测两者 `old-assertion-passes=true`、`strengthened=false`）。
  `theCurrentTopEntryExtractsBulletsInBothLanguages` 里同一处弱断言一并换掉。

**负向对照**（每次改脚本 → 跑 `swift test --filter ReleaseNotes` → 从备份恢复 → 校验 SHA-256
`73c76dc7a71347183b82371e4e97c69b29a3d0015d0b935765714c88ebc4541e`）：

| 拆掉的守卫 | 退出码 | 失败项 | issue 数 |
| --- | --- | --- | --- |
| 恢复前缀判定（歧义判定整体删掉） | 1 | 3 项 | 85 |
| 把逐字节比较换回 `==` 并去掉 `LC_ALL=C` | 1 | 2 项 | 18 |
| 允许清单整体删掉（任何 `## ` 都终止） | 1 | 11 项 | 118 |
| 版本边界删掉（任何 `## ` 都算内部结构） | 1 | 12 项 | 152 |
| 把发布文件的 `## 🐛 问题修复` 改成 `## 🐛 问题修复（第 2 批）` | 1 | 2 项 | 7（含加强后的断言与脚本退出码 3） |

### 自动化与真机边界

- 纯构建期文本处理，不涉及硬件，也不改 App 运行时行为。
- `notarize-release.sh` 的传播是用其函数原文的复刻脚本实测的，**真实签名、公证与 Sparkle appcast 生成没有在本次执行**。
- 已发布的历史 Release 正文不会被本修复追溯改写。

## 2026-08-23（第三轮复核）：Tag/版本/标题/前缀四处仍然错配

前两轮只处理了「一个条目的边界在哪里」。这一轮发现「要发哪个版本」本身没人校验，
以及标题从来不符合规范。三个缺陷都先复现再改。

### 缺陷 A：Tag 与标题用的是上游版本号

`Resources/Info.plist` 的 `CFBundleShortVersionString` 是 `1.8.25`（无 fork 后缀），
`publish-release.sh` 由它得出 `VERSION`，再由 `RELEASE_TAG="${REQUESTED_RELEASE_TAG:-v$VERSION}"`
得出 Tag。而两份 `ReleaseHistory.md` 的最新条目是 `1.8.25-fork.4`。

**复现**：

```
$ /usr/bin/plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist
1.8.25
$ grep -m1 '^## [0-9]' Resources/zh-Hans.lproj/ReleaseHistory.md
## 1.8.25-fork.4（本分支）
$ DRY_RUN=1 zsh scripts/publish-release.sh prerelease     # 修复前
EXIT=1        ← 无任何输出，死在 verify_local_artifacts 的 test -f 上
```

即：发布会打出 `v1.8.25`、标题写 `Remote Mic 1.8.25`，而版本历史说这次发的是
`1.8.25-fork.4`；链路上没有一处比较过这两者。修复前的 DRY_RUN 甚至连一行诊断都没有，
因为它先撞上缺失的制品并被 `set -e` 静默终止。

**修复**：`publish-release.sh` 在工具链检查之后、任何制品校验和网络调用之前，
要求被发布的版本必须是两份版本历史各自的**最新条目**，两种拒绝各自指出
「找的版本 + 来源」「文件」「实际最新条目」：

1. 没有任何条目叫这个版本 → `no release-history entry names <版本>`；
2. 有这个条目但不是最新 → `<版本> is not the newest release-history entry`。

`VERSION`（来自 Info.plist）和 `${RELEASE_TAG#v}`（可来自环境变量）都要过这道门，
所以 `promote` 用环境变量指定 Tag 的路径同样拦得住。

`notarize-release.sh` 也补了同一道门（仅在 `GENERATE_SPARKLE_UPDATE=1` 时）：
它把 `$VERSION` 的列表项签进 Sparkle 说明和 appcast，原先唯一的校验是
`rg -q '^- '`，任何非空条目都能满足，所以错配只会得到「另一个版本的说明」而不会报错。
门放在构建之前，拒绝成本是秒级而不是一整轮签名。

**当时不在范围、现已确定**：fork 用什么版本号和什么 Tag 当时由用户决定，因此没有改
`Resources/Info.plist`。`publish-release.sh` 还有一条**早于**本门的既有规则
`RELEASE_TAG must be a stable semantic version tag`（`^v[0-9]+\.[0-9]+\.[0-9]+$`），
`v1.8.25-fork.4` 过不了；也就是说把 Info.plist 改成 fork 版本号并不足以发布，
Tag 格式必须一并决定。该阻塞当时固化为测试 `aForkStyleVersionIsStoppedByTheExistingTagRule`。
用户已给出决定，见本文件末节「版本号与 Tag 格式的决定」；该测试也已按新契约重写。

### 缺陷 B：Release 标题不符合规范

`--title "Remote Mic $VERSION"` 既没有关键词，也正是
[`Release_Notes_Guidelines.md`](../Release_Notes_Guidelines.md) 点名反对的「vX.Y.Z 发布了」式标题。

**修复**：标题改为 `v$VERSION: $RELEASE_TITLE_KEYWORDS`，关键词由**环境变量**传入。

选环境变量而不是位置参数的理由：本脚本其他每一个按次发布变化的输入（`RELEASE_TAG`、
`DRY_RUN`）都走环境变量；`$# -ne 1` 的 `prerelease|promote` 调用约定不必改动；
`promote` 根本不写标题（沿用预发布已有的标题），位置参数在那条路径上要么是死参数，
要么只能做成可选参数——而「可选的关键词」正是静默发出通用标题的成因。

关键词缺失、只有空白、跨多行，或已自带 `v<版本>:` / `#` 前缀，一律非 0 退出并说明原因，
绝不退化成通用标题。解析出的标题在任何东西被创建之前就打印为 `RELEASE TITLE: …`，
DRY_RUN 也因此能读到它。另外 `generate_release_notes` 增加了「正文不得含 H1」的门禁，
因为标题本身就是 H1，正文再写一次页面会出现两次标题。

**本版本的关键词建议**（仅建议，未写进脚本）：正文实际写了三件事——30 天信任到期、
录音中途切换音频设备后语音键失灵、中文字号低于 12 号，因此建议
`v1.8.25-fork.4: 信任 30 天到期、录音不再失灵、中文字号加大`。

### 缺陷 C：版本查找是前缀匹配，今天的正确纯属巧合

`extract-release-notes.sh` 用 `index($0, "## " version) == 1` 判定，
所以查 `1.8.25` 会先命中位置更靠前的 `## 1.8.25-fork.4`。

**复现**（修复前）：

```
$ zsh scripts/extract-release-notes.sh 1.8.25 Resources/zh-Hans.lproj/ReleaseHistory.md --bullets-only | head -1
- **已信任的手机和手表现在会在 30 天后过期。**      ← fork.4 的内容
$ sed -n '45p' Resources/zh-Hans.lproj/ReleaseHistory.md
- 在打开错误架构的安装包时，会明确提示当前 Mac 所需的正确版本。   ← 真正的 1.8.25
$ zsh scripts/extract-release-notes.sh 1.8.2 Resources/zh-Hans.lproj/ReleaseHistory.md --bullets-only | head -1
- **已信任的手机和手表现在会在 30 天后过期。**      ← 1.8.2 也返回 fork.4
```

用独立解析器对两份文件全量比对，修复前**每份文件有 4 个真实历史版本**返回了别人的说明，
且退出码全是 0：`1.8.25`（被 `1.8.25-fork.4` 抢走）、`1.8.2`、`1.8.1`（被 `1.8.19` 等抢走）、
`1.6.1`（被 `1.6.11` 抢走）。上游真正的 `## 1.8.25（预发布）` 用自然键根本取不到。

**修复**：匹配改为逐字节相等，只允许两份文件实际使用的一种装饰——版本号后一个括号标签：
中文 `（本分支）`/`（预发布）`，英文 ` (this fork)`/` (Pre-release)`；两份文件各 52 个版本条目中
有 17 个完全没有标签，所以标签是可选的。**没有对任何单个版本做特例。**

装饰的定位用 `index()` / `substr()` 而不是字符组：在 `LC_ALL=C` 下 `[^（）]`
只是「不属于这四个字节的字节」，而 `分`（E5 88 86）含其中的 `0x88`，
用字符组会把 CJK 标签从字符中间切断。终止规则仍然排在匹配规则之前：
逐字节相等已经能防住前缀重复命中，但**同名重复标题**仍会重新激活并用 `next` 跳过终止。

同时新增 `--newest-version <文件>` 模式，输出该文件最新条目的裸版本号。
两个发布脚本的门禁都用它，好处是「一个标题代表哪个版本」只有一份实现——
上一轮的教训正是 `notarize-release.sh` 里那份复制品。

### 调用方实测行为（改后）

| 调用方 | 行为 |
| --- | --- |
| `compose-release-body.sh` | 命令替换取值，`set -euo pipefail` 下条目为空即 `no Chinese/English entry with bullets` 非 0 退出，正文 0 字节 |
| `publish-release.sh` | 新门禁在制品校验和网络调用之前拒绝，退出 1，五行诊断 |
| `notarize-release.sh` | 新门禁在 `build-app.sh` 之前拒绝，退出 1，四行诊断；`GENERATE_SPARKLE_UPDATE=0` 时不适用（该路径不产出说明） |
| `package-macos-release-variants.sh` | 顺序模式 `set -e` 直接失败并透传子进程 stderr；并行模式取消另一个变体并 `exit 1`（`parallel signed release variant packaging failed: apple-silicon exit=1`）——用一个必败的 `RELEASE_VARIANT_RUNNER` 实测 |

没有一个调用方会输出空的或只有一半的说明。

### 历史一致性（本轮自测数字）

用独立 Python 解析器重建两份文件的 版本 → 条目 映射，再逐条与脚本输出逐字节比较：

- 每份文件 **52 个版本条目**（`## ` 标题共 55 个，其中 3 个是 fork.4 条目内部的分节标题）；
- 3 种 locale（`en_US.UTF-8`、`zh_CN.UTF-8`、`C`）× 2 份文件 ×（52 版本 × 2 种模式 + 1 次 `--newest-version`）
  = **630 次查找，全部通过**，且每个条目都至少有一条列表项；
- 同一套 630 次查找跑在修复前的脚本（`git show HEAD:`）上：**54 处失败**，
  即上文那 4 个版本 × 2 种模式 × 2 份文件 × 3 种 locale，外加 `--newest-version`（修复前它退出 0 但输出为空，不是非零失败）。

### 新增回归项

`Tests/RemoteMicTests/ReleaseNotesExtractionTests.swift` 从 22 项 / 2 套增加到 44 项 / 3 套，
新套件 `Release publish identity gates` 会把 `scripts/` 与 `Resources/` 复制到一次性 ROOT，
在其中运行真实的 `publish-release.sh` 和 `notarize-release.sh`。
既有断言只在语义随精确匹配改变时同步更新（例如 `1.8.25` 现在应当解析到上游条目），
没有删除测试，也没有放宽任何断言。

### 负向对照（改脚本 → 跑测试 → 从备份恢复）

| 拆掉的守卫 | 退出码 | 失败项 |
| --- | --- | --- |
| 删掉 `require_release_history_entry "$VERSION" …` 调用 | 1 | 4 项：`aVersionThatIsNotTheNewestReleaseHistoryEntryIsRefused` 起，且 `RELEASE TITLE: v1.8.25: a、b、c` 真的被解析出来 |
| 把关键词必填条件换成 `if false; then` | 1 | 3 项，`RELEASE TITLE: v1.9.0: ` —— 正是要防的通用标题 |
| 精确匹配换回 `index($0, "## " version) == 1` | 1 | 6 项，跨两套；`1.8.25` 重新返回 fork.4 的内容且 stderr 为空 |
| 把 `notarize-release.sh` 的门禁条件换成 `if false; then` | 1 | 1 项（`notarizingRefusesAVersionThatIsNotTheNewestEntry`） |

三个「负向对照测试」本身也在守卫存在时反向验证过：它们从脚本副本里删守卫，
若守卫文本已不在脚本中会抛 `GuardTextMissing` 而不是假装通过。

### 自动化与真机边界

- 仍是纯构建期文本处理，不涉及硬件，也不改 App 运行时行为。
- **DRY_RUN 只走到了拒绝**：本仓库当前 `dist/` 没有已签名公证的 Sparkle zip、appcast 和
  Intel 变体，所以 `verify_local_artifacts` 之后的路径本轮没有执行。标题解析用一次性副本
  （改副本的 Info.plist 和版本历史，不动仓库文件）验证到 `RELEASE TITLE:` 行为止。
- **真实签名、公证、appcast 生成、Sparkle 安装更新和任何真机验收本轮都没有执行。**
- 未创建 Tag、未创建 Release、未 push；改动全部留在工作区。

## 版本号与 Tag 格式的决定（用户已确定，本轮落地）

用户的决定：**保留 `-fork.N` 后缀**，把发布版本抬到 `1.8.25-fork.4`，并把 Tag 规则放宽到
接受这个后缀。上一节留下的阻塞至此关闭，本节记录改了什么、为什么、以及验证到哪一步。

### `Resources/Info.plist`

`CFBundleShortVersionString`：`1.8.25` → `1.8.25-fork.4`。
`CFBundleVersion`：`122` → `123`。

Build 必须递增，不是可选项，两条独立证据：

1. **历史用法**：本 fork 的 Build 一直是唯一单调计数器，因为营销版本号一直停在 `1.8.25`。
   实测各 Tag 的 `CFBundleVersion`：`v1.8.25`=119、`v1.8.25-fork.1`=120、
   `v1.8.25-fork.2`=121、`v1.8.25-fork.3`=122。也就是说 122 **已经随 fork.3 发布过**，
   fork.4 沿用 122 就是用同一个 Build 发两个不同的包。
2. **Sparkle 语义**：`notarize-release.sh` 用 `--versions "$BUILD"` 生成 appcast 并断言
   `<sparkle:version>$BUILD</sparkle:version>`，`publish-release.sh` 也对两个 appcast 断言同一行。
   Sparkle 比较的是 `sparkle:version`（即 `CFBundleVersion`），
   `sparkle:shortVersionString` 只用于显示。Build 不变意味着装了 fork.3 的用户
   **永远收不到 fork.4**，而且不会有任何报错。

第三条旁证：`verify-preview-branch.sh` 要求 `CFBundleVersion` 必须大于上一个 Tag 的 Build。
实测 `git for-each-ref --sort=-version:refname 'refs/tags/v[0-9]*'` 的首位是
`v1.8.25-fork.3`（排在 `v1.8.25` 之前），所以该门禁取到的上一个 Build 就是 122，
122 会被拒绝，123 通过。`is-at-least 1.8.25-fork.3 1.8.25-fork.4` 实测为真，
版本序也成立。

### Tag 规则

`scripts/publish-release.sh`：

```
- '^v[0-9]+\.[0-9]+\.[0-9]+$'
+ '^v[0-9]+\.[0-9]+\.[0-9]+(-fork\.[0-9]+)?$'
```

**接受**：`v1.8.8`、`v1.8.25`、`v1.8.25-fork.4`（以及任意 `-fork.<数字>` 序号）。
**仍然拒绝**：`v1.8.25-fork`（无序号）、`v1.8.25-fork.`（空序号）、
`v1.8.25-fork.x`（非数字）、`v1.8.25-fork.4-fork.5`（两个后缀）、
`v1.8.25-fork.4.5.6`（多出数字段）、`v1.8.25-rc.1`（其他后缀）、
`v1.8.25-fork.4-dirty`（尾部多余文字）、`v1.8.25fork.4`（缺分隔符）、缺 `v`、空串。

同一形状还出现在另外五处，都跟着放宽，否则真实发布会被自己的门禁挡在半路：

| 脚本 | 原规则 | 为什么必须一起改 |
| --- | --- | --- |
| `verify-preview-branch.sh` | `^release/pre-v([0-9]+\.[0-9]+\.[0-9]+)$` | `publish-release.sh` 的真实（非 DRY_RUN）预发布路径调用它，`release/pre-v1.8.25-fork.4` 会被拒 |
| `verify-preview-candidate-ci.sh` | `^release/pre-v[0-9]+\.[0-9]+\.[0-9]+$` | 签名打包前的候选 CI 门禁，且它自己又调用上一个脚本 |
| `reconcile-release-event.sh` | `^v[0-9]+\.[0-9]+\.[0-9]+$` | `publish-release.sh` 发布成功后用该 Tag 触发 `release-guard.yml`，workflow 原样传给它 |
| `fast-release.sh` | `^[0-9]+\.[0-9]+\.[0-9]+$`（版本，不是 Tag） | 它从 Info.plist 推出 Tag 与候选分支后再调用上面两个脚本，否则成为唯一还卡三段版本号的入口 |
| `.github/workflows/mac-stable-promote.yml` | `^v[0-9]+\.[0-9]+\.[0-9]+$`（bash） | 它把 Tag 直接交给 `publish-release.sh promote`；不改则 `-fork.N` 候选永远无法晋升正式版 |

### 查过但**没有**改的地方

- `notarize-release.sh:71` 的 Tag 规则本来就是
  `^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$`，已经接受 `v1.8.25-fork.4`。它比新形状宽松
  （还接受 `-rc.1`，其自身报错文案也这么写），但**能用**，收紧它是另一个决定，本轮不动。
- 文件名构造全部是字符串拼接，后缀只是变长：`Remote-Mic-1.8.25-fork.4.dmg`、
  `MiRemoteV2ch-Driver-1.8.25-fork.4.dmg`、`Remote-Mic-1.8.25-fork.4.{zh,en}.txt`、
  `Remote-Mic-1.8.25-fork.4.dmg.sha256`、DMG 卷名和 `build-app.sh` 的
  `/private/tmp/remote-mic-swiftpm/$VERSION-$BUILD/…` scratch 路径，实测全部正常。
- `publish-release.sh` 的资产清单排序用 `LC_ALL=C sort`（纯字典序，不是 `sort -V`），
  与版本形状无关。仓库里没有任何 `sort -V`。
- `Sources/RemoteMic/UpdateInformationStore.swift` 的 `UpdateVersion.normalized` 原先只接受
  `^\d+(?:\.\d+){1,3}$`，`1.8.25-fork.4` 归一化失败。**这是本轮引入的真实回归，复核否决后已修**。
  最初的判断三点全错，复核逐条用执行推翻：
  ① 不是「fork 没有 appcast 所以走不通」——`RemoteMicApp.swift:117` 的检查目标写死为**上游**
  `api.github.com/repos/HD838A/remote-mic-app/releases`，上游 Release 带 `appcast.xml`，该路径通着，
  fork 自己有没有资产无关；
  ② 不是 `latestFeed` 抛 `feedNotFound`——归一化失败的是 `RemoteMicApp.swift:784-790` 传入的
  **App 自己的短版本号**，`isNewer` 只要任一侧解析失败就返回 `false`；
  ③ 不是「早就存在」——fork.1–fork.3 的 `CFBundleShortVersionString` 全部是 `1.8.25`，
  能解析；把它改成带后缀才第一次让这条路径失效。
  实测后果：`isNewer("1.8.26", than:"1.8.25-fork.4")` 为 `false`（`1.9.0`、`2.0.0` 同样），
  `:787` 的 `guard` 必然失败 → `setUpToDate()` 直接返回，`checkForUpdates` 再也到不了，
  「检查更新」和关于页横幅会永远显示已是最新。不崩溃、不显示 Unknown，纯静默。
  修法：归一化接受 `-fork.N`，排序上 fork 序号排在最后——fork 构建派生自它标注的上游版本，
  所以上游 `1.8.26` 比 `1.8.25-fork.4` 新，而 `1.8.25` 本身不算新，序号只在基版本相同时比较。
  负向对照：把正则改回三段式，新增回归项报 7 处 issue、退出 1，还原后 sha256 一致。
  Sparkle 自身用 `CFBundleVersion` 比较，但它根本没被问到，所以那一点也不构成豁免。

### 验证（各命令单独执行，退出码单独取）

| 命令 | 退出码 | 关键输出 |
| --- | --- | --- |
| `DRY_RUN=1 RELEASE_TITLE_KEYWORDS='信任 30 天到期、语音键不再失灵、中文字号加大' zsh scripts/publish-release.sh prerelease` | 1 | `RELEASE TITLE: v1.8.25-fork.4: 信任 30 天到期、语音键不再失灵、中文字号加大`；`zsh -x` 显示它已通过版本身份门与标题门，走过卸载 pkg、`Remote-Mic-1.8.25-fork.4.dmg` 及其 `.sha256`，停在缺失的 `dist/Remote-Mic-1.8.25-fork.4.zip` |
| `zsh scripts/extract-release-notes.sh 1.8.25-fork.4 <中/英两份>` | 0 | 各自抽出本条目；`--newest-version` 两份都是 `1.8.25-fork.4` |
| `zsh scripts/extract-release-notes.sh 1.8.25 <中/英两份>` | 0 | 仍是上游 `1.8.25（预发布）`/`(Pre-release)` 的内容，没有回归成 fork 条目 |
| `zsh scripts/compose-release-body.sh 1.8.25-fork.4 …` | 0 | 6 个标题、`^---$` 恰好 1 行、`^# ` 0 行，中文半在英文半之前 |
| `zsh scripts/build-app.sh` / `verify-app.sh` | 0 / 0 | `APP VERIFY PASS` |
| `BUILD_COMPONENTS=0 zsh scripts/build-dmg.sh` / `verify-dmg.sh` | 0 / 0 | `Remote-Mic-1.8.25-fork.4.dmg`，`VERSION: 1.8.25-fork.4 (123)` |
| `zsh scripts/build-driver-dmg.sh` | 0 | `MiRemoteV2ch-Driver-1.8.25-fork.4.dmg`，两个 pkg 校验通过 |
| `lsbom -s` 驱动安装 pkg 的 payload BOM | 0 | 35 条，`Applications` 条目 **0** 条（091b70e 事故的反向门禁） |
| `swift test` | 0 | 390 项 / 34 套（改前 389 项 / 34 套：1 项按新契约重写，1 项新增负向对照） |
| `zsh scripts/test.sh` | 0 | `RESULT passed=42 failed=0` |
| `zsh scripts/check-repository-boundaries.sh` | 0 | `REPOSITORY BOUNDARY PASS` |
| `zsh scripts/test-preview-branch-lifecycle.sh` | 0 | 新增 `release/pre-v1.8.15-fork.1` 候选通过并打印 `VERSION: 1.8.15-fork.1 (109)`，四个畸形分支名仍被拒 |

### 回归项与负向对照

- `aForkStyleVersionIsStoppedByTheExistingTagRule` 记录的是被用户否决掉的旧规则，
  已重写为 `aForkStyleTagIsAcceptedAndNothingLooserIs`：既断言 `1.8.25-fork.4` 通过并解析出
  `RELEASE TITLE: v1.8.25-fork.4: …`，又对 8 个畸形版本逐个断言非 0 退出、
  错误里含 `RELEASE_TAG must be a version tag`、且**没有**打印标题。断言只增不减。
- `restoringTheThreeComponentOnlyTagRuleStopsTheForkVersionAgain`：在脚本副本里把规则换回
  `^v[0-9]+\.[0-9]+\.[0-9]+$`，fork 版本重新被拒且无标题。规则文本对不上时
  `applying(_:to:)` 会抛 `GuardTextMissing`，不会假装通过。
- 工作区级负向对照（改真脚本 → 跑 → 从 `/private/tmp` 备份恢复 → 校验 SHA-256 相同）：
  - 把 `publish-release.sh` 的规则改回三段式：
    `swift test --filter aForkStyleTagIsAcceptedAndNothingLooserIs` 退出 1（2 处 issue），
    同一条 DRY_RUN 命令退出 1 并打印 `RELEASE_TAG must be a version tag such as v1.8.8 or v1.8.25-fork.4`；
    恢复后 `a33c1df3effb915d8e44de4bf328648f71378d87504c9b53e8263b840717a3b0` 一致。
  - 把 `verify-preview-branch.sh` 的分支规则改回三段式：
    `zsh scripts/test-preview-branch-lifecycle.sh` 退出 1，
    停在 `preview branch must match release/pre-v…`（只回滚了正则、没回滚文案，所以打印的是新文案，
    但被拒这件事证明正则是起作用的那一半）；恢复后
    `6663360de61f4130f0e3d9ef6367d8095d32c257580bae7d68060fa52dddcd12` 一致。

### 自动化与真机边界

- 本轮仍不改 App 运行时逻辑，只改发布元数据与发布脚本的形状规则。
- **未执行**：真实签名、公证、appcast 生成、Sparkle 安装更新，以及非 DRY_RUN 的
  `publish-release.sh`。本机没有 Developer ID 证书，`dist/` 也没有已签名的 Sparkle zip
  与 Intel 变体，所以 DRY_RUN 只能走到该 zip 缺失处为止。
- `verify-preview-candidate-ci.sh` 与 `reconcile-release-event.sh`：**拒绝那一半本地实测过**，
  因为两者的形状检查都排在任何 `gh` 调用和网络访问之前。
  `zsh scripts/reconcile-release-event.sh <畸形 tag> someactor` 对
  `v1.8.25-fork`、`v1.8.25-fork.x`、`v1.8.25-fork.4-fork.5`、`v1.8.25-rc.1` 全部退出 1，
  打印 `usage: … vX.Y.Z|vX.Y.Z-fork.N actor [record-preview]`；
  `GITHUB_REF_NAME=<畸形分支> zsh scripts/verify-preview-candidate-ci.sh` 对
  `release/pre-v1.8.15-fork`、`…-fork.x`、`…-fork.1-fork.2`、`…-rc.1` 全部退出 1，
  打印 `candidate CI verification requires release/pre-vX.Y.Z or release/pre-vX.Y.Z-fork.N`。
  **接受那一半只做了静态审查**：形状检查通过后它们立刻需要 `gh`、远端与 Release 状态，本轮没有执行。
  `.github/workflows/mac-stable-promote.yml` 的同一形状只用 `bash` 单独跑过该正则
  （`v1.8.25`、`v1.8.25-fork.4` 接受；`v1.8.25-fork`、`v1.8.25-rc.1`、
  `v1.8.25-fork.4-fork.5`、`v1.8.25fork.4` 拒绝），**workflow 本身没有执行**。
- **未验收**：「关于」页的当前版本号从 `1.8.25`（6 字符）变成 `1.8.25-fork.4`（13 字符），
  以 28pt semibold 显示。`SettingsPageRenderingTests` 里 `Bundle.main` 是测试可执行文件，
  读不到本仓 `Info.plist`，渲染出的是「未知/Unknown」，因此**这个更长的版本号没有任何自动化覆盖**，
  需要在真实窗口按 `Testing/AboutUpdateCenter.md` 与本仓 minSize 门禁看一次是否换行或裁切。
- 未创建 Tag、未创建 Release、未 commit、未 push；改动全部留在工作区。
