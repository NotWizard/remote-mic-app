# 自定义快捷键丢失修饰键左右侧（右⌘+逗号不生效）

- 时间：2026-08-13
- 状态：已修复（自动化通过；待真机验收）
- 影响范围：使用自定义快捷键且依赖左/右侧修饰键的按键映射（本次为电源键 = 右 Command + 逗号）
- 功能点：自定义快捷键录制、持久化与注入
- 简单描述：录制时丢弃修饰键的左右侧信息，注入时也只在主键上打通用 flag、不按下真实修饰键，导致要求“右侧 Command”的第三方软件不响应。
- 原始记录：`~/Library/Logs/RemoteMic/runtime.log`；`defaults` 实读配置；本文

## 复现与现象

用户把电源键设为自定义快捷键“右 Command + 逗号”，用于触发自研语音软件（该软件区分左右侧）：

1. 快捷键“没有生效”——语音软件不响应。
2. 在不同 App 前台按电源键时，会“触发别的逻辑”。

无真机环境无法复现（我没有 RC003 与该软件），以下为只读诊断。

## 证据

- 持久化配置（`defaults export com.hd838a.RemoteMic` 实读）：
  `power → { keyCode: 43(","), modifierFlagsRawValue: 1048576 }`。
  `1048576 = 0x100000` 是**侧别无关的通用 Command**，**没有**右侧设备位（右⌘ = `0x10`）。
- 日志：`HID BUTTON button=power trigger=singleClick action=customShortcut` —— 按键识别与动作派发正常，问题不在 HID、按键映射或权限。
- 结论：用户的设置本身没问题，是 App 把“右侧”这一信息丢了。

## 根因

1. 录制即丢侧别：`CustomKeyboardShortcut.init` 对 `modifierFlags` 做 `.intersection(supportedModifiers)`，而该集合只含 `.control/.option/.shift/.command/.function` 等**侧别无关**掩码，右⌘ 的设备相关位（IOKit `IOLLEvent.h`，右⌘=`0x10`）在保存时被剔除。
2. 注入无法表达侧别：`KeyboardInjector` 的 `customShortcut` 分支只做 `postKey(主键, 通用flag)`，**从不按下真实修饰键**，既没有设备位也没有 `flagsChanged`。要求“右侧”或依赖真实修饰键按下的软件因此不响应。
3. UI `displayName` 只显示 `⌘`，把这次降级隐藏了。

## 修复

- `CustomKeyboardShortcut`：新增左右设备位掩码；`retainedModifiers` 同时保留设备位（录制不再丢侧别）；`cgEventFlags` 附带已记录的设备位；新增 `sideSpecificModifierKeyCodes`（右⌘=54、右⌥=61、右⇧=60、右⌃=62；左侧为 55/58/56/59），顺序固定 Control→Option→Shift→Command；`displayName` 显示“左/右”。
- `KeyboardInjector.postShortcut`：有侧别时**按下真实侧别修饰键 → 主键 → 逆序释放**，用 `defer` 保证失败也释放（避免重演“卡修饰键”）；无侧别（旧配置）走**原有 flags-only 路径**，行为不变。两处调用点（`customShortcut`、自定义 App 的 keyboardShortcut 聚焦）统一走该函数。
- 本地化新增 `keyboard.modifier.left/right`（中英同步）。

## 已知边界：⌘+, 本身的性质

`⌘+,` 是 macOS 全局约定的「设置/偏好设置」快捷键，且 **Cocoa 匹配快捷键不区分左右 ⌘**。因此：

- 若用户软件用 CGEventTap/全局热键**消费**了该事件，前台 App 不再收到 → 现象 2 一并消失。
- 若它**不消费**，前台 App 仍可能打开“设置”。此时应改用无人占用的组合（如 `⌃⌥⌘+某键` 或 F13–F20）。

这一点无法靠本 App 代码消除，已写入测试手册验收步骤。

## 用户须知

- **必须重新录制**电源键快捷键：旧配置里没有侧别信息，升级后仍是通用 ⌘。
- 行为变化：**新录制**的快捷键会按下真实修饰键（更保真）；旧配置保持原路径。
- 顺带发现：`menu` 键存有历史 `fn+,`（`8388608`），但当前绑定为“打开自定义 APP”，该快捷键未生效，未在本次改动。

## 验证与边界

- 自动化：`xcrun swift test`（226）与 `./scripts/test.sh` 通过。新增：右⌘ 设备位保留 + 键码 54 + flags 含 `0x10`；注入顺序 `down:60 → down:54 → key:43 → up:54 → up:60`；修饰键按下失败仍释放已按下项；旧配置（无设备位）仍走 flags-only。既有 `customShortcutNormalizesDisplaysAndConvertsModifiers` / `customShortcutPostsRecordedKeyAndRequiresAccessibility` 继续通过，证明零回归。
- 真机（未完成，需用户）：重新录制为“右⌘,”并确认显示带“右”；在语音软件中按电源键确认被触发；在别的 App 前台按电源键观察是否仍打开设置；连按 10 次确认无卡修饰键。
- 边界：单测只证明进程内的记录与注入顺序；**右侧 Command 能否被该软件识别、现象 2 是否消失，必须真机验收**。
