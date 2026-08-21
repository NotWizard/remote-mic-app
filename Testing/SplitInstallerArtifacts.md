# 安装制品拆分测试手册

## 适用范围

- 版本：`1.8.25-fork.3` 及之后
- 分支：`NotWizard/remote-mic-app` `main`
- 对应缺陷：[`Bugs/2026-08-21-installer-bundle-relocation-deleted-installed-app.md`](../Bugs/2026-08-21-installer-bundle-relocation-deleted-installed-app.md)

验证目标：App 改为拖拽安装后不再触发 bundle 重定位、不再删除已安装的 App；驱动由独立 DMG 的安装与卸载 pkg 管理，且永不触碰 App。

## 制品

| 制品 | 内容 | 何时需要 |
| --- | --- | --- |
| `Remote-Mic-<版本>.dmg` | `Remote Mic.app` + `Applications` 符号链接 | 每次安装或升级 App |
| `MiRemoteV2ch-Driver-<版本>.dmg` | `Install Remote Mic.pkg`、`Uninstall Remote Mic.pkg` | 只在需要把遥控器自带麦克风的声音送进其他 App、且没有 BlackHole 等回环设备时 |

## 测试前准备

1. 记录当前状态：`/Applications/Remote Mic.app` 是否存在及其版本、`/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver` 是否存在。
2. 备份偏好：`cp ~/Library/Preferences/com.hd838a.RemoteMic.plist ~/Desktop/prefs-backup.plist`。
3. 记录当前按键映射截图或导出配置，用于事后比对。
4. 清空 `install.log` 起点：`date` 记下时间，事后用该时间过滤。

## 用例

### SI-01 拖拽安装并覆盖已有版本（核心用例）

1. 确保 `/Applications/Remote Mic.app` 已存在且可运行。
2. 挂载 `Remote-Mic-<版本>.dmg`，确认根目录**只有**两项：`Remote Mic.app` 与指向「应用程序」的符号链接。
3. 把 `Remote Mic.app` 拖到「应用程序」，选择替换。
4. 首次打开需右键点击图标选择「打开」。

预期结果：

- 替换成功，`/Applications/Remote Mic.app` 为新版本，归属为当前用户而非 `root:wheel`；
- **按键映射、自定义 App 动作、已录快捷键全部保留**；
- `/var/log/install.log` 在此期间**没有** `relocated to` 记录，也没有 `PKInstallErrorDomain`；
- 音频驱动状态不变。

失败判定：出现任何 `relocated to`、配置丢失、`/Applications/Remote Mic.app` 消失、或需要重新授权系统权限。

### SI-02 存在非标准位置同 Bundle ID App 时的拖拽安装（回归本次事故）

1. 先构造事故前置条件：`./scripts/build-app.sh` 生成 `dist/Remote Mic.app`，并打开它一次使 Launch Services 记录该路径。
2. 退出该 App。
3. 按 SI-01 步骤拖拽安装。

预期结果：`/Applications/Remote Mic.app` 被正常替换；`dist/Remote Mic.app` **保持原样、不被写入或删除**；`install.log` 无 `relocated to`。

失败判定：`dist/` 下的副本被改动，或 `/Applications` 里的 App 被删除。**这是本次事故的直接回归用例，必须通过。**

### SI-03 驱动安装

1. 挂载 `MiRemoteV2ch-Driver-<版本>.dmg`，确认含安装与卸载两个 pkg。
2. 双击 `Install Remote Mic.pkg` 完成安装。

预期结果：

- 安装成功，无报错；
- 安装器输出提示驱动已安装或已保留，并说明 App 由单独 DMG 拖拽安装；
- `/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver` 存在且 `codesign --verify --deep --strict` 通过；
- **`/Applications/Remote Mic.app` 完全未被改动**（比对安装前后的修改时间与归属）；
- Remote Mic 的「连接与语音」页刷新后能看到并选中 `MiRemoteV 2ch`。

失败判定：App 的修改时间或归属发生变化、App 被自动启动或退出、`install.log` 出现 `relocated to`。

### SI-04 驱动重复安装应保留

1. 在 SI-03 之后再次运行 `Install Remote Mic.pkg`。

预期结果：提示「已保留现有的 MiRemoteV 2ch，无需重复安装」，驱动文件修改时间不变，`coreaudiod` 不被重启。

### SI-05 驱动卸载

1. 双击 `Uninstall Remote Mic.pkg`。

预期结果：`/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver` 被移除，`coreaudiod` 重启，系统音频设备列表中 `MiRemoteV 2ch` 消失；`/Applications/Remote Mic.app` 与已安装的 BlackHole 均不受影响。

失败判定：BlackHole 被删除、App 被改动、或音频输出中断无法恢复。

### SI-06 架构门禁

1. 在 Intel Mac 上运行 Apple Silicon 版驱动 pkg（或反之）。

预期结果：安装被拒，提示下载另一架构的版本，系统未发生任何改动。

## 稳定功能回归

- 语音键按住说话、松开结束；
- 语音触发键为 Fn 时豆包输入法路径正常；
- 右 Command/Option/Shift 触发键无修饰键卡住；
- 自定义快捷键左右侧保真；
- 遥控器隔夜休眠后重连，按键映射自行恢复（见 [`HIDMappingReadinessRetry.md`](HIDMappingReadinessRetry.md)）；
- 「统计」页计数正常。

## 日志收集

```zsh
# 安装相关
grep -E 'relocated to|PKInstallErrorDomain|Remote Mic|MiRemoteV' /var/log/install.log | tail -40
# App 运行时
tail -40 ~/Library/Logs/RemoteMic/runtime.log
# 状态核对
ls -ld "/Applications/Remote Mic.app" /Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver
```

## 验证边界

- **自动化已覆盖**：两个 DMG 的构建与结构校验、驱动组件包 payload 中 `Applications` 路径条目数为 0、驱动脚本不含 `APP_DESTINATION` 与 `/Applications/`、拖拽结构的符号链接目标、App 的签名与版本一致性。247 项 Swift 测试与 42 项项目自检通过。
- **自动化无法覆盖**：真实 PackageKit 重定位行为、Launch Services 注册状态的影响、Gatekeeper 首次打开、`coreaudiod` 重启后的实际音频可用性。
- **代理实测已完成**：构建、结构校验、`lsbom` payload 核对、单元测试。
- **代理实测未完成**：**任何真机安装或卸载**。代理不会在用户机器上执行安装 pkg。
- **用户实测必需**：SI-01 至 SI-06 全部用例。**SI-02 是本次事故的回归用例，未通过前本修复只能表述为「自动化通过、待真机验收」。**
