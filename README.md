# 显示器切换

同一台支持 DDC/CI 的外接显示器，在 Mac 与 Windows 电脑之间切换输入源。Mac 端是菜单栏应用，Windows 端是托盘应用；两个系统各自安装。两端使用相同的双显示器图标。

**第一次使用请看 [图文入门教程](docs/使用教程.md)。** 图中的菜单为依据当前程序制作的操作示意图；实际外观会随系统版本和显示器配置变化。

## 使用前

- 在显示器菜单中开启 DDC/CI，确认两台电脑实际连接的输入接口，并核对该显示器对应的 VCP 0x60 输入源编号。不要把示例编号当成自己的配置。
- Mac 端需要 macOS 13+、Xcode Command Line Tools，以及 [m1ddc](https://github.com/waydabber/m1ddc)；预编译 Mac 包已内置 m1ddc。Windows 端需要 .NET Framework C# 编译器，安装脚本会检测。
- 操作系统或扩展坞可能阻断 DDC/CI；这时不能仅靠软件完成输入切换。

## Mac

下载 Release 中的 Mac 压缩包，解压后将 `显示器切换.app` 放入 `/Applications`。首次配置时编辑应用内 `Contents/Resources/config.txt`，每行格式为 `编号,名称`；例如 `21, Mac USB-C`。编辑后需要重新签名：

```sh
codesign --force --deep --sign - /Applications/显示器切换.app
```

打开应用后，顶部菜单栏双屏图标左键快速切换，右键打开输入源菜单。升级本项目早期的 `MonitorSwitch.app` 时，可在本项目目录运行 `python3 install-mac.py /Applications/MonitorSwitch.app`；脚本先备份旧版并保留原设备配置，然后替换与验证。请不要同时启动两个副本。

本地构建：`M1DDC_BIN=/path/to/m1ddc ./build-release.sh`。构建包默认只含注释示例配置；需为每台电脑单独配置。

## Windows

下载 Release 中的 Windows 压缩包，在 Windows 解压并从 PowerShell 运行 `./install.ps1 -TargetCode <另一台电脑输入源编号> -ThisCode <当前电脑输入源编号>`。安装脚本编译托盘程序、设置开机启动，并创建桌面快捷键；重新安装前会备份旧程序与配置。托盘左键快速切到另一台电脑，右键可选目标输入源。`Ctrl+Alt+M` 是快捷切换键。

安装只管理当前解压目录中的同名托盘程序；其他位置的旧副本请先确认后自行关闭，避免重复驻留。

## 隐私与发布范围

仓库与公开安装包不包含任何设备专用输入源配置、账号或业务文件。`m1ddc` 的许可文本见 [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt)。
