# 驱动安装与卸载脚本在重启音频服务时中止，成功的操作被报为失败

- 编号：A2
- 时间：2026-08-21
- 状态：已修复，自动化通过；真机安装未验收
- 影响范围：`Install Remote Mic.pkg`、`Uninstall Remote Mic.pkg`，以及两个独立驱动脚本
- 功能点：安装/卸载后重启系统音频服务
- 简单描述：脚本在驱动已经复制或删除完成之后调用 `killall coreaudiod`，该命令在没有匹配进程时返回非零，`set -euo pipefail` 因此中止脚本，Apple 安装器显示笼统的失败提示，用户会以为操作没成功。

## 复现

前置条件：`coreaudiod` 未在运行（可通过在受控环境中让 `killall` 返回非零来等价模拟）。

1. 运行 `Install Remote Mic.pkg` 或 `scripts/install-doubao-driver.sh`。
2. 观察脚本退出码与安装器界面。

错误行为：驱动已写入 `/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver`，但脚本以非零退出，安装器提示失败。
正常行为边界：`coreaudiod` 正在运行时（macOS 上几乎总是如此）`killall` 返回零，流程正常，因此这是潜伏缺陷而非常发故障。

## 日志结论

本缺陷由代码审计发现，非现场报障，因此没有对应的用户日志。相关前例是 [`2026-08-21-installer-bundle-relocation-deleted-installed-app.md`](2026-08-21-installer-bundle-relocation-deleted-installed-app.md)：同样是"实际工作已完成、脚本随后失败、用户看到笼统错误"的形态，说明这一类缺陷在本项目有前科，值得单独设门禁。

## 根因

`killall` 的退出码语义是「是否至少杀掉一个进程」，没有匹配进程时返回非零。脚本把它当作必须成功的步骤，放在 `set -e` 之下且位于全部变更动作之后。

而这一步的真实语义是**尽力而为的刷新**：重启音频服务只是让系统尽快重新枚举驱动；服务没在运行时无需重启，驱动会在它下次启动时被加载。把这种"无需执行"的情况当成致命错误，是对命令语义的误用。

## 修复

四处统一改为三分支写法，两处 pkg 脚本通过 `installer_message` 输出中英双语：

- `scripts/install-doubao-driver.sh`
- `scripts/uninstall-doubao-driver.sh`
- `packaging/doubao-driver/install/postinstall`
- `packaging/doubao-driver/uninstall/postinstall`

由 `pgrep -qx coreaudiod` 判定服务是否在运行来决定措辞，`killall` 真实失败单独成一个分支并如实告知用户需要重启 Mac，且**不抑制 stderr**，使失败原因能进入安装器日志。三种情况都不中止脚本：驱动已经就位，最坏情况只是系统稍后才加载它。

**未采用 `killall coreaudiod || true`**：那会把权限不足等真实失败一并吞掉。

### 返工记录：第一版方案被独立复核否决

第一版写作 `if killall coreaudiod 2>/dev/null; then ... else "服务未在运行" fi`，并在本文档中声称「其余非零退出仍会在输出中体现」。复核实测证伪了这个结论：`2>/dev/null` 抑制了 stderr，权限型失败同样落入 `else` 分支并输出「服务未在运行」，退出码仍为 0。也就是说该写法**与 `|| true` 完全等价，还额外输出了一句与事实不符的说明**，所谓"不用 `|| true` 的理由"并未实现。现已按上述三分支方案返工。

### 复核发现的第二个阻塞项：pkg 构建链被打断

`scripts/verify-doubao-driver-pkg.sh` 的两条断言仍在逐字匹配旧的裸调用行，脚本改为条件形式后必然失配。该文件自身以 `set -euo pipefail` 运行，`grep` 失配即中止，而它被 `build-doubao-driver-pkg.sh`、`build-driver-dmg.sh`、`notarize-release.sh`、`publish-release.sh` 调用——**驱动 pkg 因此无法构建**。

讽刺之处在于这正是本缺陷的同一形态：命令未匹配返回非零，叠加 `set -e` 造成中止。它没有被及时发现，是因为 `swift test` 与 `scripts/test.sh` 都不覆盖这个脚本。现已改为断言新的 `pgrep` 判定与条件分支形式，并增加反向门禁禁止裸调用——断言重启步骤仍存在这一点必须保留，它是保证 pkg 内不丢失该步骤的唯一门禁。

## 验证

返工后的最终结果：

- `swift test`：255 项通过（其中 A2 相关的 `audioServiceRestartNeverAbortsInstallerScripts` 已从文案耦合的文本断言升级为**真实行为测试**：用 PATH 注入必然失败的 `killall` 与 `pgrep`，在临时 `TARGET_VOLUME` 下实际运行卸载脚本，断言退出码为 0 且驱动确实被删除。另保留一条整行正则门禁，禁止四个脚本出现裸的 `killall`/`pkill` 语句，比原先的前缀匹配更难绕过，且不依赖任何文案）
- `./scripts/test.sh`：42 项通过
- `zsh -n`：四个安装脚本与 `verify-doubao-driver-pkg.sh` 语法通过
- `./scripts/build-driver-dmg.sh`：通过，确认被打断的构建链已恢复
- 驱动组件包 payload 经 `lsbom` 确认 `Applications` 路径条目为 0

复核者另做了真机级 A/B：以临时 `TARGET_VOLUME` 运行真实卸载 postinstall，修复前退出码 1 且驱动已删除（缺陷完整复现，末尾提示从未打印），修复后退出码 0 且提示齐全。

## 自动化与真机边界

自动化只覆盖脚本内容与语法。**未验证**：真机运行安装 pkg 与卸载 pkg 的完整流程、`coreaudiod` 实际未运行时的端到端表现、以及安装器界面的最终提示文案。这些需按 [`Testing/SplitInstallerArtifacts.md`](../Testing/SplitInstallerArtifacts.md) 的 SI-03 至 SI-05 完成真机验收。
