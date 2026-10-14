# MonitorOnOff

原生 macOS 菜单栏工具，用于独立开启或关闭多个外接显示器的输出。

[下载最新版](https://github.com/JenW1nt0p/MonitorOnOff/releases/latest) · [English](README.md)

## 功能

- 在菜单栏分别控制多个外接显示器。
- 软件关闭后仍保留该屏幕的恢复入口，使用 UUID 跟踪设备。
- 保护内建屏，并要求至少保留一个开启的输出。
- 退出时恢复本工具关闭的输出；恢复失败时可保留记录，下次启动重试。
- 显示器连接变化时自动刷新。
- 首次启动默认启用登录自启动，可在菜单或系统设置中关闭。
- 跟随 macOS 首选语言，支持简体中文、繁体中文、韩文、日文和英文；不支持的语言回退到英文。

软件关闭输出不等同于显示器硬件关机。是否进入待机取决于系统、驱动、显示器和连接方式。

## 安装

从 Releases 下载通用版 DMG，将 `MonitorOnOff.app` 拖到“应用程序”，或复制到 `~/Applications`。推出磁盘映像，再打开已安装的应用。不要从挂载的 DMG 启用自启动，否则推出映像后可能无法启动。

点击菜单栏的显示器图标，选择对应显示器，再选择“关闭输出”或“开启输出”。修改系统或单独应用语言后，重新启动工具即可生效。硬件名称和型号保留系统提供的名称。

目标系统为 macOS 13.0 及以后，包含 Apple Silicon 和 Intel 架构。已在 Apple Silicon 上验证运行，Intel 与旧版 macOS 尚未实机验证。

发布包使用临时签名，**尚未使用 Developer ID 签名或 Apple 公证**。macOS 可能阻止运行下载的应用或显示未识别开发者提示。请确认来源并查看源码，也可以自行本地构建。

## 构建与检查

安装 Xcode Command Line Tools 或 Xcode 后运行：

```sh
./build.sh
./test.sh
python3 Tests/localization.py dist/MonitorOnOff.app
./package-dmg.sh
```

应用与 DMG 默认生成到 `dist/`。逻辑检查使用模拟显示器，不改变真实输出或登录项。本地化检查覆盖五种语言的 225 条文案及 14 种首选语言匹配情况。原生菜单测试和维护命令见英文说明。

## 技术说明

应用动态探测非公开的 CoreGraphics 接口 `CGSConfigureDisplayEnabled`，通过当前登录会话的显示配置事务开关输出。接口可能随 macOS 版本变化。软件关闭和恢复是否有效取决于硬件及驱动；当前尚未完成真实外接显示器切换、热插拔与恢复的实机验证。

恢复记录存储在 `~/Library/Application Support/DisplayOutputSwitch/recovery.json`，仅包含本工具处理过的显示器信息，不会上传。强制结束进程无法执行正常恢复流程；已拔线的显示器需要接回后再恢复。自启动采用公开的 `SMAppService.mainApp` 接口，并尊重用户在系统设置中的关闭选择。

## 许可证

采用 [MIT 许可证](LICENSE) 开源。应用包和 DMG 中也包含许可证文件。
