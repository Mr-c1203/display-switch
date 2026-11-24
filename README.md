# 显示器切换 (Display Switch)

多台电脑共用一台显示器时，一键切换输入源（KVM 用法）。Mac 端菜单栏应用，Windows 端托盘应用。

**第一次使用请看 [图文入门教程](docs/使用教程.md)。** 下载：[最新发布](https://github.com/Mr-c1203/display-switch/releases/latest)。

## 功能（2.1）

| | Mac | Windows |
|---|---|---|
| 点图标弹菜单，从菜单选接口切换 | ✓ | ✓ |
| 自定义快捷键：循环切换 + 每个接口直达 | ✓ | ✓ |
| 新显示器自动识别全部接口（USB-C / HDMI / DP，没接电脑的口也能识别） | ✓ | ✓ |
| 切换后守住输入，防止显示器自动跳回 | ✓ | ✓ |
| 目标口没信号时提示原因 | ✓ | ✓ |
| 给接口填电脑名字 | ✓ | ✓ |
| 关于 → 检查更新，一键升级到最新版 | ✓ | ✓ |
| 多显示器 | ✓ | ✓ |
| DDC 通道 | 内嵌（无外部依赖） | dxva2（系统自带） |

## 使用前

- 显示器 OSD 里开启 **DDC/CI**。
- KVM 用法：显示器的 HDMI/DP 输入要另配一根 USB 上行线，键鼠才会跟着切；USB-C 输入一根线全包。
- 经过扩展坞/转接头时可能不透传 DDC/CI，这时软件无法切换。

## 怎么用

1. 打开应用，第一次检测到显示器会问是否识别接口，点「现在识别」（约 1–3 分钟，屏幕会闪几次，结束后切回本机）。
2. 点菜单栏/托盘图标，菜单里列出所有接口，选哪个就切到哪个。
3. 「管理这台显示器 → 给接口填电脑名字」写上每个口接的是哪台电脑。
4. 「快捷键」里设置循环切换快捷键（默认 Mac ⌃⌥\`、Windows Ctrl+Alt+\`），或给某个接口设直达快捷键。
5. 换了显示器或新接了电脑：「管理这台显示器 → 重新识别接口」。

识别不到的口（少数显示器不响应）：用显示器按钮切到那个口，再点「学习当前输入」；或「手动添加编号」。

## 升级

菜单 →「关于显示器切换 / 检查更新」。有新版本时点「升级」，会自动下载、替换并重启。每台电脑各自点一下即可。

## 构建与发布

- Mac：`./build.sh`，产物 `release/显示器切换.app` 和 `release/DisplaySwitch-macOS-<版本>.zip`。版本号在 `VERSION` 文件。
- Windows：GitHub Actions 自动编译；推送 `v*` 标签时自动打包 `DisplaySwitch-Windows-<版本>.zip` 并附到发布。
- 发新版：改 `VERSION` 和 `windows/TraySwitcher.cs` 里的 `AppInfo.Version` → 构建 Mac 包 → 打标签推送 → 在发布里上传 Mac 包。各电脑「检查更新」即可升级。

配置位置：Mac `~/Library/Application Support/显示器切换/config.json`；Windows `%LocalAppData%\显示器切换\config.json`。

## 许可

MIT。第三方组件许可见 [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt) 和 `mac-app/M1DDC-LICENSE.txt`。
