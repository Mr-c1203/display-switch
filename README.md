# 显示器切换 (Display Switch)

多台电脑共用一台显示器时，一键切换输入源（KVM 用法）。Mac 端菜单栏应用，Windows 端托盘应用。

**第一次使用请看 [图文入门教程](docs/使用教程.md)。**

## 功能（v2）

| | Mac | Windows |
|---|---|---|
| 菜单栏/托盘切换 | ✓ | ✓ |
| 多机清单（最多 4 台） | ✓ | ✓ |
| 切换读回验证 | ✓ | ✓ |
| 自动探测输入口 | ✓ | ✓ |
| 学习当前输入 | ✓ | ✓ |
| 手动添加/改名/删除 | ✓ | ✓ |
| 热键循环切换 | ✓ (⌃⌥\`) | ✓ (Ctrl+Alt+\`) |
| 多显示器 | ✓ | 单显示器（第一台 DDC 显示器） |
| DDC 通道 | 内嵌（无外部依赖） | dxva2（系统自带） |

## 使用前

- 显示器 OSD 里开启 DDC/CI。
- KVM 用法：显示器 HDMI/DP 输入配一根 USB 上行线，USB-C 输入一根线全包。
- 操作系统或扩展坞可能阻断 DDC/CI，这时不能仅靠软件切换。

## Mac

解压后将 `显示器切换.app` 放入 `/Applications`。机器清单存在 `~/Library/Application Support/显示器切换/config.json`（改配置不用重签名）。

- **左键**菜单栏图标：切到清单里的下一台（两台即来回切）
- **右键**：选机器 / 管理输入口 / 其他
- **自动探测**：写候选编号、读回，屏幕会闪约 90 秒，自动列出口
- **学习当前输入**：探测不到的口（没信号源的口会被弹回）用显示器按钮切过去，再点「学习当前输入」读码命名

本地构建：`./build.sh`（自包含 m1ddc 传输层，MIT，见 `mac-app/M1DDC-LICENSE.txt`）。

## Windows

运行 `install.ps1`（或用自带 csc 编译 `TraySwitcher.cs`）。机器清单存在 `%LocalAppData%\显示器切换\config.json`。托盘左键快速切换，右键菜单管理。

## 隐私与发布范围

仓库与公开安装包不包含任何设备专用输入源配置、账号或业务文件。

## 许可

MIT。第三方组件许可见 [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt) 和 `mac-app/M1DDC-LICENSE.txt`。
