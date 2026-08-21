# Remote Mic 首次安装说明

## 使用要求

- Apple Silicon Mac；
- macOS 14 或更高版本；
- 小米蓝牙遥控器 2 Pro。

打开 Remote-Mic-<version>.dmg 后，把 Remote Mic.app 拖到“应用程序”，首次打开需右键点击图标并选择“打开”。音频驱动由单独的 MiRemoteV2ch-Driver-<version>.dmg 提供，内含安装与卸载两个 pkg；只有需要把遥控器自带麦克风的声音送进其他 App 时才需要安装。驱动安装器会检查现有 MiRemoteV 2ch：健康且兼容时原样保留，缺失或不可用时才安装或更新，随后重启系统音频服务。它不会安装、改动或启动 Remote Mic.app。

只需要 App、已经使用 BlackHole 2ch 等其他回环音频设备的高级用户，可从同一 Release 下载 App-only ZIP。

首次启动后按提示允许蓝牙权限。如需自定义普通按键，还要在“权限”页面依次允许输入监控和辅助功能。
