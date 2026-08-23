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

## 验证

`Tests/RemoteMicTests/ReleaseNotesExtractionTests.swift`，5 项，全部驱动真实脚本与真实字节：

- 裸版本号必须停在下一个标题，不得吞掉任何 fork 条目（三条"不得包含"断言）
- 精确 fork 版本只抽自己那一段
- 文件里最后一个条目仍能被抽出（`exit` 前置不能让末尾条目漏掉）
- 不存在的版本返回空，而不是别人的说明
- 中英两份 ReleaseHistory 的当前首条都能抽出 `- ` 列表项，满足 `publish-release.sh` 的
  `rg -q '^- '` 门禁

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
