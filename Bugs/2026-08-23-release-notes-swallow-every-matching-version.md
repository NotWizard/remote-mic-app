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
该输入与规范要求的 `## X.Y.Z` 相违，且 `ReleaseHistorySection.parse` 也不会把它当成版本卡片，故按残余风险记录而非阻断。

**负向对照**：把终止规则改回 `active && /^## / { exit }` → `swift test --filter ReleaseNotesExtraction`
退出 1，5 项失败共 28 处 issue（含 `theCurrentTopEntryComposesABilingualBody` 的 `status == 1`，
即发布脚本会拒绝空正文）；恢复后与备份 `diff -q` 无输出。全量 `swift test` 退出 0，361 项 / 33 套。

**边界**：`notarize-release.sh` 的这段改动只在本地用真实历史文件按同一命令核对过输出，
完整签名与公证流程没有在本次执行；App 内「版本历史」Sheet 的分节过滤有单元覆盖（去掉守卫后
负向对照报 11 处 issue，含 `sections.count → 4` 与卡片标题变成 `⚠️ 注意事项`），但**没有真实窗口渲染验收**，
按 `Testing/AboutUpdateCenter.md` 的回归项做真实 UI 验收。
