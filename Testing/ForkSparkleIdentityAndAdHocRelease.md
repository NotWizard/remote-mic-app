# Fork Sparkle 身份与 ad-hoc 发布模式测试手册

## 适用范围

- 适用版本：`1.8.25-fork.4` 及之后的本 fork 版本（`NotWizard/remote-mic-app`）。
- 适用分支：包含 `scripts/release-signing-mode.sh` 的 `main`、开发分支及其后续 `release/pre-v*` 候选。
- Apple Silicon：`arm64`、macOS 14 及以上。Intel：`x86_64`、macOS 13 及以上。
- 本手册验证三件事：App 携带本 fork 自己的 Sparkle 公钥并自动检查更新；`RELEASE_SIGNING_MODE=adhoc` 只豁免它无法证明的项；`fork.1`–`fork.3` 到 `fork.4` 的一次性手动安装中断确实如说明所述。
- 本手册**不授权**创建 Tag、Release、签名、公证或推送任何远端引用。

## 测试前准备

1. 使用干净的独立 worktree，并固定到待测提交；`git status --porcelain` 必须为空。
2. 准备三台（或三个用户账户 / 三份虚拟机快照）环境：
   - A：从未安装过本 fork 的干净环境；
   - B：已安装 `1.8.25-fork.3` 的环境（用于验证一次性中断）；
   - C：已安装 `1.8.25-fork.4` 的环境（用于验证之后的自动更新）。
3. 安装 `jq`、`rg`、`gh`；准备 Sparkle 的 `sign_update`、`generate_keys`、`generate_appcast`。
4. 不输出、不粘贴、不写入任何 Sparkle 私钥、Apple 私钥、P8、Keychain 密码或部署密钥。截图前先关闭钥匙串窗口。
5. 记录当前 `Resources/Info.plist` 的 `CFBundleShortVersionString`、`CFBundleVersion`、`SUFeedURL`、`SUPublicEDKey`、`SUEnableAutomaticChecks` 五个值，后续每个用例都对照它们。

## 用例 1：App 携带的更新身份全部指向本 fork（自动化）

1. `plutil -extract SUPublicEDKey raw -o - Resources/Info.plist`
2. `plutil -extract SUEnableAutomaticChecks raw -o - Resources/Info.plist`
3. `plutil -extract SUFeedURL raw -o - Resources/Info.plist`
4. `rg -n 'api.github.com/repos' Sources/RemoteMic/RemoteMicApp.swift`
5. `rg -n 'github.com/' Sources/RemoteMic/AppLinks.swift`

预期结果：公钥为 `+EyNzAtTgwbJ4/04/ujn/JrpA0NKLFQSOd9w3Pg80M8=`；自动检查为 `true`；feed、Releases API 与 UI 链接三处都是 `NotWizard/remote-mic-app`。

失败判定：出现上游公钥 `8dWQovCnGPucjMcQuCHfrAv4PtjuDjJSbHNmItqYiyc=`；自动检查为 `false`；三处地址中任何一处仍指向 `HD838A`。

## 用例 2：ad-hoc 模式的门禁与负对照（自动化）

1. `zsh scripts/test-adhoc-release-mode.sh`
2. `swift test`
3. `zsh scripts/test.sh`
4. `zsh scripts/check-repository-boundaries.sh`

预期结果：用例 1 打印 `ADHOC RELEASE MODE TEST PASS`，且其中每一条 `PASS (refused)` 都出现——未签名包、签名后被改动的包、与 App 公钥不一致的签名密钥、仍声明 Apple Developer Team 的 ad-hoc 运行全部被拒绝。`swift test` 不少于 396 项 / 34 个套件；`scripts/test.sh` 为 `passed=42 failed=0`；边界检查打印 `REPOSITORY BOUNDARY PASS`。

失败判定：任何 `expect_refusal` 变成被接受；测试项数下降；任一门禁非零退出。

## 用例 3：ad-hoc 构建仍然通过它能通过的全部校验（代理可执行）

1. `./scripts/build-app.sh`
2. `RELEASE_SIGNING_MODE=adhoc ./scripts/verify-app.sh "dist/Remote Mic.app"`
3. `codesign -dvvv "dist/Remote Mic.app" 2>&1 | rg '^Signature=|^TeamIdentifier=|^Identifier='`

步骤 1 不可跳过：本次改动之前构建的 `dist/Remote Mic.app` 里仍是旧公钥且自动检查为 `false`，`verify-app.sh` 会正确地拒绝它。对旧产物报错是新增断言在起作用，不是回归。

预期结果：verify 打印 `AD-HOC SIGNATURE PASS` 覆盖 App 本体与全部 Sparkle 组件，随后打印 `APP VERIFY PASS` 和 `AD-HOC RELEASE MODE` 的逐条 `NOT PROVEN` 清单；`codesign` 显示 `Signature=adhoc`、`TeamIdentifier=not set`、`Identifier=com.hd838a.RemoteMic`。

失败判定：verify 在 ad-hoc 模式下静默跳过而不打印 `NOT PROVEN` 清单；ad-hoc 断言未覆盖 Sparkle 组件；或对一个签名被破坏的包仍然通过。

## 用例 4：默认模式没有被静默放宽（代理可执行）

1. 不设置 `RELEASE_SIGNING_MODE`，运行 `./scripts/verify-app.sh "dist/Remote Mic.app"`。
2. `RELEASE_SIGNING_MODE=adhoc EXPECTED_DEVELOPER_TEAM_ID=L3QHLDRPAY DRY_RUN=1 ./scripts/publish-release.sh prerelease`

预期结果：步骤 1 报告 `RELEASE SIGNING MODE: developer-id`，并且因为没有传 `REQUIRE_DEVELOPER_ID_SIGNING=1` 而**不**执行 Developer ID 断言，也**不**执行 ad-hoc 断言（与改动前行为一致）。步骤 2 被拒绝，理由是 ad-hoc 模式不该声明 Apple Developer Team。

失败判定：默认模式下出现任何 ad-hoc 豁免；步骤 2 被接受。

## 用例 5：`fork.3 → fork.4` 的一次性手动安装中断（必须真机）

1. 在环境 B（已装 `1.8.25-fork.3`）打开 App，等待或手动触发一次更新检查。
2. 记录是否出现更新提示、是否下载、是否安装成功、是否有任何错误弹窗。
3. 查看 `~/Library/Logs/DiagnosticReports/` 与 App 运行日志中 Sparkle 相关条目。
4. 在环境 B 手动下载 `fork.4` 的 DMG，拖拽覆盖安装，首次打开使用右键 →「打开」。
5. 打开 App，确认版本为 `1.8.25-fork.4`，并确认蓝牙、输入监控、辅助功能权限是否需要重新授权。

预期结果：步骤 1–2 中 `fork.4` **不会**被安装——旧版本用旧公钥验签失败。这是预期行为，必须与中英文版本历史里的「必须手动下载安装一次」一致。步骤 4–5 手动安装成功，版本正确，App 正常启动。

失败判定：`fork.3` 竟然成功自动升级到 `fork.4`（说明公钥没有真正更换）；或手动安装后版本号、启动、权限任一项异常；或版本历史的说法与实际现象不符。

## 用例 6：`fork.4` 之后自动更新真正可用（必须真机，当前未完成）

1. 在环境 C（已装 `1.8.25-fork.4`）等待计划检查（默认 24 小时）或手动触发。
2. 观察是否发现下一个 fork 版本、更新说明语言是否跟随 App 语言、是否需要用户确认后才安装。
3. 安装后确认版本号、启动、再次启动、无新增崩溃报告。

预期结果：`fork.4` 起自动发现并提示更新；因为 `SUAutomaticallyUpdate` 与 `SUAllowsAutomaticUpdates` 仍为 `false`，必须由用户确认后才安装，不会静默替换。

失败判定：`fork.4` 收不到更新提示；或未经确认就自动安装；或更新后版本号不变、启动失败、出现新崩溃。

**当前状态：未执行。** 需要至少两个已发布的 fork 版本（`fork.4` 与其后继）才能验证，本轮尚不存在后继版本。

## 稳定功能回归项

在环境 A 的干净安装上逐项确认，全部必须与 `1.8.25-fork.3` 行为一致：

1. RC003 遥控器配对、连接、断开重连。
2. 普通按键自定义映射与应用绑定。
3. 语音键：`STREAM_START → AUDIO → STREAM_STOP` 一次成功，不需要第二次尝试。
4. 遥控器麦克风收音模式与外接麦克风模式切换。
5. 设置页在当前生产 `minSize`（`1020 × 772`）下逐个侧边栏入口无裁切、窗口几何不变。
6. 关于页版本号、版本历史、反馈入口、GitHub 链接可点开且指向本 fork。

## 日志收集方式

1. App 运行日志：设置 →「关于」→ 导出日志，或直接取 `~/Library/Logs/RemoteMic/`。
2. Sparkle 相关：`log show --last 1h --predicate 'subsystem CONTAINS "Sparkle"' --info`。
3. 崩溃：`~/Library/Logs/DiagnosticReports/` 中 `RemoteMic-*`。
4. 发布脚本：保留完整 stdout/stderr，尤其是 `RELEASE SIGNING MODE`、`NOT PROVEN`、`AD-HOC SIGNATURE PASS`、`SPARKLE SIGNING KEY PASS` 四类行。
5. 收集日志前先确认其中不含私钥、密码或邀请码。

## 验证边界

- **自动化只能证明**：plist 取值、脚本断言存在且会拒绝坏输入、ad-hoc 模式的门禁与负对照、Swift 与自检项数。它不能证明真实 Sparkle 安装更新可用。
- **代理实测只能证明**：本机 ad-hoc 构建通过 `verify-app.sh`、`codesign` 报告的签名形态、脚本的拒绝路径。它不能替代 Developer ID 签名、公证、Gatekeeper 首次打开体验，也不能替代真实用户从旧版本升级。
- **必须用户实测**：用例 5、用例 6，以及稳定功能回归项 1–4。这些依赖真实 RC003 硬件、真实旧版本安装和真实时间推进。
- 本 fork 没有 `download.sayall.app` CDN，也没有上游的私有凭据仓库，因此 `publish-release.sh` 的公开 CDN 比对与 `fast-release.sh` 在本仓库无法完成；相关用例只能在 `DRY_RUN=1` 下验证到脚本拒绝逻辑一层。
