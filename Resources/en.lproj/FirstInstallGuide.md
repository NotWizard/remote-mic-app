# Remote Mic First-Install Guide

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Xiaomi Bluetooth Remote 2 Pro

After opening Remote-Mic-<version>.dmg, drag Remote Mic.app into Applications; the first launch needs right-click then Open. The audio driver ships separately in MiRemoteV2ch-Driver-<version>.dmg, which contains both an install and an uninstall package, and is only needed to route the remote's built-in microphone into other apps. The driver installer checks the existing MiRemoteV 2ch: a healthy compatible driver is kept in place, a missing or unusable driver is installed or updated, and the system audio service is then restarted. It never installs, modifies, or launches Remote Mic.app.

Advanced users who need only the app and already use another loopback device such as BlackHole 2ch can download the app-only ZIP from the same Release.

Allow Bluetooth access when Remote Mic first launches. To customize normal buttons, also grant Input Monitoring and Accessibility in the **Permissions** page.
