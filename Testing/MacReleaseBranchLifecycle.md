# macOS 发布分支生命周期测试手册

## 适用范围

- 适用分支：包含候选基线、provenance schema 2 和候选回流门禁的 `main` 及后续 `release/pre-vX.Y.Z`。
- 适用流程：macOS Preview Candidate、macOS Signed Release Packages、Release Guard、macOS CI、macOS Stable Promotion。
- 本手册只验证发布分支与资产生命周期，不代替 App 功能、安装、Intel Ventura、签名或公证的专项验收。

## 测试前准备

1. 使用干净工作区，执行 `git fetch origin main --tags`，确认本地 `main` 与 `origin/main` 一致。
2. 选择尚未使用的测试版本和递增 build；候选分支必须命名为 `release/pre-vX.Y.Z`。
3. 候选只修改 `Resources/Info.plist` 的版本/build、两份 `ReleaseHistory.md` 和必要的 `Testing/*.md`。
4. 真正发布 Pre-release 前，仍需通过受保护 Environment 审批、两种架构打包、签名、公证及下载字节校验。

## 用例 1：从最新 main 创建单提交候选

1. 从最新 `origin/main` 创建 `release/pre-vX.Y.Z`。
2. 完成允许的发布元数据修改并生成一个普通提交。
3. Push 候选分支，运行 `./scripts/verify-preview-branch.sh`。

预期结果：输出 `PREVIEW BRANCH PASS`，`BASE_MAIN_COMMIT` 等于候选直接父提交和当时最新 `origin/main`，候选相对 main 只有一个提交。

失败判定：候选包含多个提交、merge commit、父提交不是最新 main，或包含产品代码时仍通过。

## 用例 2：禁止从旧预览分支或 Tag 串联

1. 以旧 `release/pre-vA.B.C` 或对应 Tag 为起点创建新的 `release/pre-vX.Y.Z`。
2. 更新版本元数据并运行候选校验。

预期结果：校验失败，并明确提示候选直接父提交必须精确等于最新 `origin/main`，应重新从 main 创建。

失败判定：只因 main 是历史祖先就允许候选通过。

## 用例 3：禁止候选承载产品代码

1. 在合规候选中额外修改 `Sources/`、`Apps/`、`Package.swift` 或其他非允许文件。
2. 运行候选校验。

预期结果：校验列出首个非发布改动，并要求先将产品代码通过 PR 合入 main。

失败判定：产品代码进入候选或只在发布后才被发现。

## 用例 4：Pre-release 发布后回流 main

1. 完成签名、公证和本地验证，发布 schema 2 的 GitHub Pre-release。
2. 等待发布脚本完成 GitHub/CDN 下载字节比较，并确认它调度 Release Guard。
3. 检查 Release Guard 创建标题为 `Record vX.Y.Z preview candidate in main` 的 PR，并启用 auto-merge。
4. 等待 Apple Silicon 与 Intel Ventura 必需检查通过。

预期结果：候选提交通过 merge commit 进入 main；GitHub Release 仍为 Pre-release；Tag 和所有签名、公证资产未变化，未运行正式晋升。

失败判定：下载字节未验证就创建回流 PR、PR 绕过必需检查、Release 被改为正式版、Tag 或资产被重建/替换。

## 用例 5：从回流后的 main 创建下一候选

1. 候选 PR 合入 main 后，更新本地 `origin/main`。
2. 产品开发分支从该 main 创建并通过 PR 合入 main。
3. 下一 `release/pre-vX.Y.Z` 再从新的最新 main 创建。

预期结果：新候选继承已回流的版本元数据和后续产品代码，且仍只有一个新的发布元数据提交。

失败判定：需要从旧候选分支继续开发，或新候选直接父提交不是最新 main。

## 用例 6：正式版复用已验证候选

1. 明确选择一个已经发布、验证且 Tag 提交已包含于 `origin/main` 的 Pre-release。
2. 触发正式晋升，不修改候选分支、Tag 或 Release 资产。
3. 比较晋升前后的资产名称、大小和 SHA-256。

预期结果：同一个 Tag 从 Pre-release 变为 Stable，所有候选资产摘要完全一致，只新增正式晋升证明；未重新签名、公证或打包。

失败判定：候选未进入 main 就晋升、选择了未发布候选、创建新 Tag、替换任一资产或从 main 重建。

## 用例 7：GitHub Release 正文分节与语言分界

1. 用候选版本号执行：
   `zsh scripts/compose-release-body.sh <版本> Resources/zh-Hans.lproj/ReleaseHistory.md Resources/en.lproj/ReleaseHistory.md`
2. 用 `grep -n '^#'` 列出正文里所有标题及行号。
3. 用 `grep -c '^---$'` 数分隔线，用 `grep -c '^# '` 数 H1。
4. 逐语言核对**不丢内容**：数出 `ReleaseHistory.md` 里该版本条目自己的 `## ` 分节数和 `- ` 列表项数，
   与正文对应半边的数量逐一比对，两个数字都必须相等。只看「有没有列表项」不够——
   条目中途被截断时前面的列表项照样在，两个调用方的 `- ` 门禁都会放行。
5. 用同一版本号跑 `zsh scripts/extract-release-notes.sh <版本> <发布文件> --bullets-only`，
   确认 Sparkle 那条路径的列表项数与上一步一致。
6. 在候选 Release 页面（或本地 Markdown 预览）确认两种语言的分界处可见。

预期结果：退出码 0。中文半和英文半各自的**第一个标题**就是该语言的规范分节标题；本次有注意事项时，
第一个标题必须是 `## ⚠️ 注意事项` / `## ⚠️ Heads-up`。正文里除这四个规范分节外没有任何其他标题，
`^---$` 恰好 1 行，`^# ` 为 0 行。中文全文整体在英文全文之前，两半都含 `- ` 列表项，
分节数与列表项数与发布文件里该条目完全一致，且都不含相邻版本的任何条目
（例如 `1.8.25` 不得带出 `1.8.25-fork.3`）。

失败判定：正文出现 `## 更新内容`、`## What's New` 或任何非规范分节的标题；注意事项不是所在语言半的
第一个标题；出现 H1（页面会显示两次标题）；分隔线缺失、出现多条，或两种语言直接连在一起；
任一语言缺条目却仍然退出 0；正文夹带下一个或上一个版本的条目；**该版本写在发布文件里的任何一个分节
或任何一条列表项没有出现在正文里，而退出码仍是 0**（例如条目在中途某个分节标题处被截断，
只剩注意事项一节，两个 `- ` 门禁却都通过）；`--bullets-only` 的列表项数与正文不一致。

补充检查（歧义标题必须报错而不是二选一）：把发布文件里某个分节标题临时改成
`## 🐛 问题修复（第 2 批）`，再跑第 1 步。抽取脚本必须**非 0 退出**并在 stderr 指出该标题和文件名，
`compose-release-body.sh` 必须一起失败且不输出任何正文；随后恢复该标题。
如果这一步退出 0 并给出一份「看起来正常」的正文，判定失败。

## 用例 8：Tag、版本、标题与版本历史必须指同一个发布

适用版本或分支：`1.8.25-fork.4` 之后的任何候选分支。

测试前准备：确认工作区干净，记录 `Resources/Info.plist` 的
`CFBundleShortVersionString` 与两份 `ReleaseHistory.md` 的最新条目。

1. 记录三个值：
   `/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist`、
   `zsh scripts/extract-release-notes.sh --newest-version Resources/zh-Hans.lproj/ReleaseHistory.md`、
   `zsh scripts/extract-release-notes.sh --newest-version Resources/en.lproj/ReleaseHistory.md`。
   预期：三者完全相同。不同就直接进入第 2 步确认发布会被拒绝。
2. 跑 `DRY_RUN=1 zsh scripts/publish-release.sh prerelease`。
   预期（三者一致时）：走到制品校验；不一致时**退出 1**，stderr 必须同时给出「找的版本 + 来源」
   「版本历史文件路径」「实际最新条目」三项。
3. 用环境变量试一次绕过：`DRY_RUN=1 RELEASE_TAG=v<某个更旧的版本> zsh scripts/publish-release.sh promote`。
   预期：同样退出 1，并指出该版本不是最新条目。
4. 不设关键词跑 `DRY_RUN=1 zsh scripts/publish-release.sh prerelease`（在版本一致的候选分支上）。
   预期：退出 1，stderr 含 `RELEASE_TITLE_KEYWORDS is required` 并引用
   `Release_Notes_Guidelines.md`；标准输出**没有** `RELEASE TITLE:` 行。
5. 读一遍用例 7 生成的正文，据其内容拟三个关键词，再跑
   `DRY_RUN=1 RELEASE_TITLE_KEYWORDS='<关键词一、关键词二、关键词三>' zsh scripts/publish-release.sh prerelease`。
   预期：标准输出出现且仅出现一次 `RELEASE TITLE: v<版本>: <三个关键词>`。
6. 发布后在候选 Release 页面确认：标题就是第 5 步那一行，页面正文没有第二个同样的标题。

预期结果：Tag、`Resources/Info.plist` 的版本、两份版本历史的最新条目和 Release 标题里的版本号
全部相同；标题形如 `v<版本>: 三个关键词`，关键词能对应正文实际写了什么。

失败判定：版本与最新条目不同却仍能继续发布；拒绝信息缺少版本、文件或实际最新条目任一项；
`RELEASE_TAG` 从环境变量传入时绕过检查；未设 `RELEASE_TITLE_KEYWORDS` 却发出了标题；
标题里没有关键词或写成 `Remote Mic <版本>`；标题的版本号与 Tag 不一致；页面出现两次标题。

## 用例 9：Tag、分支与版本号的形状（`-fork.N`）

适用版本或分支：`1.8.25-fork.4` 及之后的任何候选分支。

已确定的版本方案：保留 `-fork.N` 后缀。发布版本为 `1.8.25-fork.4`，Tag 为 `v1.8.25-fork.4`，
候选分支为 `release/pre-v1.8.25-fork.4`，Build 每次发布必须递增（本版 123，上一版 fork.3 是 122）。

1. 确认 `Resources/Info.plist` 的 `CFBundleShortVersionString` 与两份 `ReleaseHistory.md`
   的最新条目完全相同，且 `CFBundleVersion` 严格大于上一个 Tag 的 Build。
   预期：三者一致；Build 递增。Build 未递增时 `verify-preview-branch.sh` 必须拒绝，
   而且这不是可选项——Sparkle 用 `CFBundleVersion` 判断新旧，沿用旧 Build 的包不会被当作更新。
2. 逐一用下列 Tag 跑 `DRY_RUN=1 RELEASE_TAG=<tag> zsh scripts/publish-release.sh promote`。
   预期：`v1.8.8`、`v1.8.25-fork.4` 通过 Tag 形状检查（随后可能被别的门禁拒绝，那是另一回事）；
   `v1.8.25-fork`、`v1.8.25-fork.`、`v1.8.25-fork.x`、`v1.8.25-fork.4-fork.5`、
   `v1.8.25-fork.4.5.6`、`v1.8.25-rc.1`、`v1.8.25-fork.4-dirty`、`v1.8.25fork.4`
   一律退出 1，stderr 为 `RELEASE_TAG must be a version tag such as v1.8.8 or v1.8.25-fork.4`。
3. 候选分支名同形状：`release/pre-v1.8.25-fork.4` 必须通过 `verify-preview-branch.sh`，
   `release/pre-v1.8.25-fork`、`…-fork.x`、`…-fork.1-fork.2`、`…-rc.1` 必须在分支形状处就被拒。
   本地可用 `zsh scripts/test-preview-branch-lifecycle.sh` 在临时 bare remote 中跑完这一整组。
4. 确认同形状规则的七处实现一致：`publish-release.sh`、`verify-preview-branch.sh`、
   `verify-preview-candidate-ci.sh`、`reconcile-release-event.sh`、`fast-release.sh`、
   `notarize-release.sh:71`（它本就用 `([.-][0-9A-Za-z.-]+)?`，比其余六处宽松，连 `-rc.1` 也收），
   以及 `.github/workflows/mac-stable-promote.yml`（它把 Tag 直接交给 `publish-release.sh promote`，
   不放宽则 `-fork.N` 候选永远无法晋升正式版）。
   预期：任何一处收紧或放宽都会让真实发布在候选校验、签名打包、Release Guard 或正式晋升处半途失败。

失败判定：畸形 Tag 或畸形分支名被接受；`v1.8.25-fork.4` 被拒；Build 未递增却能继续；
六处形状规则出现分歧；`1.8.25` 的查找回归成 fork 条目。

尚未在本机执行（缺 Developer ID 证书）：真实签名、公证、appcast 生成、Sparkle 安装更新，
以及非 DRY_RUN 的 `publish-release.sh`。用例 8 第 2 步的 DRY_RUN 现在能通过版本身份门与标题门，
但会停在缺失的 `dist/Remote-Mic-<版本>.zip`（已签名 Sparkle 归档）处；第 6 步仍需真实候选 Release 页面。

## 稳定功能回归

- `mac-preview-candidate.yml` 的普通候选 Push 仍不读取 Apple 发布证书。
- `mac-release-package.yml` 继续只有 `contents: read`，签名密钥仅在受保护 Environment 中使用。
- main PR 仍要求 Apple Silicon 与 Intel Ventura 两项必需检查。
- 普通候选回流 PR 的 CI 不得触发 Stable Promotion；只有正式晋升流程显式调度的候选 CI 才可进入晋升 workflow，且没有 `stable-promotion-approved` 时必须明确跳过。
- 历史 schema 1 候选仍可按既有正式晋升流程验证，但不会因普通 Pre-release 事件自动回流 main。
- 历史版本说明仍只抽出自己那一段：本仓版本号互为前缀（`1.8.25` 与 `1.8.25-fork.*`），抽取不得把
  相邻条目并进来，也不得在条目内部的四个规范分节标题处提前截断。
- 版本匹配必须是**精确**的，不是前缀：查 `1.8.25` 只能得到 `## 1.8.25（预发布）`，不能得到
  `## 1.8.25-fork.4`；查 `1.8.2`、`1.8.1`、`1.6.1` 同理只能得到各自那一条。版本号后只允许一个
  括号标签（中文 `（本分支）`/`（预发布）`，英文 ` (this fork)`/` (Pre-release)`），
  没有标签也必须能查到。回归时中英两份文件的全部 52 个版本都要在默认和 `--bullets-only`
  两种模式下按各自名字抽对。
- `publish-release.sh` 与 `notarize-release.sh` 都必须拒绝「被发布的版本不是版本历史最新条目」，
  且 `notarize-release.sh` 的拒绝要发生在 `build-app.sh` 之前；`package-macos-release-variants.sh`
  在顺序与并行两种模式下都必须把这个失败透传出来，而不是继续生成 appcast。
- 两个方向的丢内容都要回归，不能只看合并：相邻版本的条目不得并进来；这一版自己写下的分节和列表项
  也不得从条目中途消失（`## 🐛 问题修复（第 2 批）` 这类标题就曾让后半段整节静默丢掉，退出码仍是 0）。
- 以规范分节表情开头但不等于八个规范分节标题的标题（`## 🎉 9.9.8 …`、`## 🎉 版本九点九点八`、
  `## ⚠️Heads-up`、`## ⚠ 注意事项` 等）必须让抽取非 0 退出并指出标题与文件，既不合并也不静默截断；
  Sparkle 的纯文本更新说明与 GitHub 正文共用同一个抽取脚本，两条路径必须一起失败。
- 版本号带 `-fork.N` 后缀后，制品名跟着变长（`Remote-Mic-1.8.25-fork.4.dmg`、
  `MiRemoteV2ch-Driver-1.8.25-fork.4.dmg`、`Remote-Mic-<版本>.{zh,en}.txt`、`…dmg.sha256`、
  DMG 卷名）。`build-app.sh`、`verify-app.sh`、`build-dmg.sh`、`verify-dmg.sh`、
  `build-driver-dmg.sh` 必须全部退出 0，`verify-dmg.sh` 打印的版本与 Build 必须与
  `Info.plist` 一致。
- 驱动安装 pkg 的 payload 仍必须**没有任何** `Applications` 条目（`lsbom -s` 实测 0 条）：
  这是 fork.2 那次「安装包删掉用户已装 App」事故的反向门禁，版本号形状变化不得放松它。
- 「关于」页的当前版本号现在是 13 个字符、28pt semibold。渲染测试里 `Bundle.main` 读不到本仓
  `Info.plist`（显示为「未知/Unknown」），因此这一项**没有自动化覆盖**，需要在真实窗口按当前生产
  `minSize` 确认不换行、不裁切、不改变窗口几何。

## 日志收集

- 候选来源：保存 `verify-preview-branch.sh` 的完整输出、候选 SHA、`BASE_MAIN_COMMIT` 和 `git log -1 --format='%H %P'`。
- 发布资产：保存 `candidate-provenance.json`、Release Guard run URL、回流 PR URL、两项必需检查结果。
- 正式晋升：保存晋升前后 Release 状态、`stable-promotion.json` 和资产 SHA-256 对比。
- 失败时不得粘贴 Apple 证书、私钥、API key、Match 密码或 Environment secret；只记录脱敏错误和 workflow step。

## 验证边界

- 自动化可验证分支父子关系、允许文件范围、provenance、PR/CI 门禁和资产摘要。
- 用例 7 的正文结构由 `Tests/RemoteMicTests/ReleaseNotesExtractionTests.swift` 覆盖，直接驱动真实
  `compose-release-body.sh`、`extract-release-notes.sh` 和两份真实 `ReleaseHistory.md`；这只证明
  Markdown 文本结构正确，**没有验证 GitHub 页面实际渲染出来的样子**，需要在候选 Release 页面上肉眼确认一次。
- 用例 8 的门禁由同一文件里的 `Release publish identity gates` 套件覆盖：它把 `scripts/` 与
  `Resources/` 复制到一次性 ROOT，在其中运行真实的 `publish-release.sh` 和 `notarize-release.sh`，
  每个守卫都配一条「把守卫从副本里删掉后必须失败」的负向对照。
- **DRY_RUN 只能走到制品缺失处**：仓库 `dist/` 没有已签名公证的 Sparkle zip、appcast 和 Intel
  变体。带 `-fork.4` 版本号的 DRY_RUN 现在会通过版本身份门与标题门（打印
  `RELEASE TITLE: v1.8.25-fork.4: …`），走过卸载 pkg、`Remote-Mic-1.8.25-fork.4.dmg` 与其
  `.sha256`，停在缺失的 `Remote-Mic-1.8.25-fork.4.zip`；**真实签名、公证、appcast 生成和
  Sparkle 安装更新都未执行。**
- 用例 9 的 Tag 形状由 `ReleaseNotesExtractionTests.swift` 的
  `aForkStyleTagIsAcceptedAndNothingLooserIs` 覆盖（含 8 个畸形版本），分支形状由
  `scripts/test-preview-branch-lifecycle.sh` 在临时 bare remote 中真实执行覆盖；
  Tag 规则有一条「把规则改回三段式后必须失败」的负向对照；`test-preview-branch-lifecycle.sh`
  只有正向用例与 4 个畸形分支名拒绝用例，**没有**规则回退对照，分支形状回退不会被自动发现。
  `verify-preview-candidate-ci.sh` 与 `reconcile-release-event.sh` 的同形状规则只做过静态审查，
  它们需要 `gh` 与远端状态，尚未真实执行。
- 残余风险：完全不带规范分节表情的标题（例如 `## 版本说明`）仍会被当成下一个版本、直接终止条目，
  没有任何提示。以分节表情开头的近似标题（含 `## 🎉 版本九点九点八`、全角数字写法）现在会非 0 退出，
  不再静默合并；但表情之外的写法只能靠用例 7 第 4 步的分节/列表项计数发现。
- 被接受的八个分节标题是**逐字节固定**的（`⚠️` 含 U+FE0F）。改词、改大小写、换表情或新增第三种语言，
  必须同时改 `scripts/extract-release-notes.sh`、`ReleaseNotesExtractionTests.swift` 和两份
  `ReleaseHistory.md`；只改其中一处会让发布在抽取阶段直接失败——这是刻意的，比静默少发几条说明好。
- 本地执行 `./scripts/test-preview-branch-lifecycle.sh` 可在临时 bare remote 中验证“从最新 main 创建单候选提交通过、从旧候选串联失败”，不会修改真实远端。
- 代理可只读检查 GitHub Release、workflow、PR 和提交关系；没有用户明确发布授权时不得创建分支、Tag、Release 或执行晋升。
- Environment 审批、真实签名/公证、Intel Ventura 安装和可见 App 行为仍需各自真实环境验收；这些结果不能由静态脚本测试替代。
