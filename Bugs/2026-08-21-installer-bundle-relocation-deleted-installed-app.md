# 安装包因 bundle 重定位删除已安装的 App 并安装失败

- 时间：2026-08-21
- 状态：已修复，自动化通过；真机安装验收未完成
- 影响范围：`v1.8.25-fork.2` 的 `Remote-Mic-1.8.25.dmg`，以及此前所有采用同一 pkg 结构的安装包
- 功能点：`Install Remote Mic.pkg` 组件包的 App payload 与 bundle 重定位
- 简单描述：安装器把 App 装到了 Launch Services 记录的旧路径而不是 `/Applications`，删除了用户正在使用的 App，随后 `postinstall` 因目标路径不存在而失败，安装报错终止。用户偏好也被随后启动的新版按全新安装重写。

## 复现

用户机器上存在一个非 `/Applications` 位置、Bundle ID 为 `com.hd838a.RemoteMic` 的 App（本例为源码构建产物 `<repo>/dist/Remote Mic.app`），然后：

1. 挂载 `Remote-Mic-1.8.25.dmg`；
2. 双击 `Install Remote Mic.pkg` 并完成授权。

错误行为：安装界面显示「安装失败。安装器遇到了一个错误」。`/Applications/Remote Mic.app` 被删除，App 进程终止；新版被写入 `dist/Remote Mic.app` 且归属变为 `root:wheel`。

正常行为边界：音频驱动 `MiRemoteV2ch.driver` 未受影响；DMG 与 pkg 自身的签名、校验、`verify-dmg.sh`、`verify-app.sh` 全部通过——**这些检查都无法发现该问题**。

## 日志结论

`/var/log/install.log`：

```text
11:32:43 installd: PackageKit: Applications/Remote Mic.app relocated to
                   Users/xxx/Downloads/Projects/AICode/remote-mic-app/dist/Remote Mic.app
11:32:43 package_script_service: Executing script "preinstall"
11:32:44 package_script_service: ./preinstall: An existing MiRemoteV 2ch was found ...
11:32:45 installd: PackageKit: Parent bundle com.hd838a.RemoteMic will be atomically shoved.
11:32:45 package_script_service: Executing script "postinstall"
11:32:46 installd: PackageKit: Install Failed: Error Domain=PKInstallErrorDomain Code=112
                   UserInfo={NSFilePath=./postinstall, ...}
```

`postinstall` 未输出任何一行日志即失败，而 `preinstall` 有输出，说明它死在开头的静默 `test` 上。

关键在 `relocated to` 那一行：安装目标被改写。这不是脚本行为，而是 macOS PackageKit 在 payload 声明可重定位的 app bundle 时的既有机制。

## 根因

`scripts/build-doubao-driver-pkg.sh` 用 `pkgbuild --root` 构建组件包，payload 同时包含 `Applications/Remote Mic.app` 与暂存的驱动，且**未传 `--component-plist`**。对 app bundle，`BundleIsRelocatable` 默认为真，于是 PackageKit 查询 Launch Services 中该 Bundle ID 的注册位置，并把安装目标重定向到那里。

重定向后：

1. 新版 App 被写入 `dist/Remote Mic.app`；
2. `/Applications/Remote Mic.app` 作为「同一 bundle 的旧副本」被移除；
3. `postinstall` 第 82 行 `test -d "$APP_DESTINATION"`（硬编码 `/Applications/Remote Mic.app`）失败，`set -e` 静默退出，安装报 Code=112。

放大伤害的次生原因：偏好键丢失。App 被删除后，用户重新启动新版时按全新安装写入默认 `remoteDeviceProfiles`，覆盖了 `buttonBindings`、`customApplicationProfiles`、`buttonApplicationProfileIDs` 等键。

该缺陷不限于开发机：任何把 App 放在非 `/Applications`（从源码构建、在下载目录运行过、手动移动过）的用户都会触发。

## 修复

不采用「加 `BundleIsRelocatable=false` 继续用一个 pkg 装 App」的方案，而是按分发形态拆开，从根上让 App 不再经过 pkg：

- `scripts/build-dmg.sh` 改为构建拖拽式 App DMG：只含 `Remote Mic.app` 与指向 `/Applications` 的符号链接，**没有 pkg、没有 BOM、没有安装脚本**，因此不存在重定位与 postinstall 失败的可能。
- 新增 `scripts/build-driver-dmg.sh`：驱动 DMG，内含 `Install Remote Mic.pkg` 与 `Uninstall Remote Mic.pkg`。
- `scripts/build-doubao-driver-pkg.sh` 移除 App payload 与对 `verify-app.sh` 的依赖，payload 只剩驱动。
- `packaging/doubao-driver/install/preinstall`、`postinstall` 删除全部 App 逻辑，包括 `APP_DESTINATION`、Sparkle 可执行文件遍历、`chown`/`codesign`、旧版 `无线麦.app` 迁移与删除、安装后自动启动 App。驱动安装器不再以任何方式触碰 App。
- `scripts/verify-doubao-driver-pkg.sh` 增加反向门禁：payload 出现任何 `./Applications/` 路径、或脚本出现 `APP_DESTINATION` 与 `/Applications/`，直接判失败。
- `scripts/verify-dmg.sh` 改为校验拖拽结构：根目录恰好两项、`Applications` 是指向 `/Applications` 的符号链接、App 的签名/架构/版本/Bundle ID/`SUFeedURL` 均正确。

驱动包体积由 6.8 MB 降至 52 KB，直观反映 App payload 已移除。

## 验证

- `swift test`：247 项、21 个 suite 通过。`appDmgIsDragInstallAndDriverPackageNeverCarriesTheApp` 断言拖拽结构与「驱动包不含 App」双向约束；`intelVenturaReleaseLineStaysIsolatedFromAppleSilicon` 的 App 相关断言改为更强的「preinstall 不出现 APP_DESTINATION」。
- `./scripts/test.sh`：42 项通过。
- `./scripts/build-dmg.sh` + `./scripts/verify-dmg.sh`：通过；挂载确认根目录为 `Remote Mic.app` 与 `Applications` 符号链接。
- `./scripts/build-driver-dmg.sh`：通过；挂载确认含安装与卸载两个 pkg。
- `lsbom` 实测驱动组件包 payload 中 `Applications` 路径条目数为 **0**。
- `./scripts/check-repository-boundaries.sh`、`./scripts/verify-release-dependency-pins.sh`：通过。

## 现场恢复

用户机器已恢复：`dist/Remote Mic.app`（1.8.25 (121)，签名校验通过）复制到 `/Applications`，归属 `xxx:admin`；按键配置按事故前记录的值写回 `~/Library/Preferences/com.hd838a.RemoteMic.plist`，包括顶层键与 `remoteDeviceProfiles[].mappings`（后者会覆盖顶层键，只写顶层会被清空）。事故前的偏好已备份到桌面。

`v1.8.25-fork.2` 的 DMG 资产已从 Release 删除，并在说明顶部加了撤回警告。

## 自动化与真机边界

自动化只覆盖构建产物结构与脚本内容。**以下均未验证**：

- 在存在非 `/Applications` 同 Bundle ID App 的机器上，拖拽安装是否确实不再触发重定位；
- 驱动 DMG 的安装与卸载 pkg 在真机上的实际效果，以及卸载后 `coreaudiod` 重启是否正常；
- Gatekeeper 对拖拽式 ad-hoc App 的首次打开流程。

必须按 [`Testing/SplitInstallerArtifacts.md`](../Testing/SplitInstallerArtifacts.md) 完成真机验收后才能认为本缺陷关闭。
