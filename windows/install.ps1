<#
install.ps1 — Windows 版 显示器切换 安装脚本

把程序复制到 %LocalAppData%\显示器切换\app，设为开机自启并启动。
- 安装包里已有 TraySwitcher.exe 时直接用；只有源码时用 Windows 自带的 csc 编译。
- 首次启动会自动识别显示器接口，不需要手填编号。
- 旧版 TraySwitcher.ini 不再使用；已有的 config.json 会保留。

用法：双击 install.bat，或在 PowerShell 里运行  .\install.ps1
#>
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dst = Join-Path $env:LOCALAPPDATA '显示器切换\app'
New-Item -ItemType Directory -Force $dst | Out-Null

Get-Process TraySwitcher -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

$exe = Join-Path $src 'TraySwitcher.exe'
if (-not (Test-Path $exe)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { throw '找不到 TraySwitcher.exe，也没有 .NET Framework 编译器。请下载发布页里的 Windows 安装包。' }
    $icon = Join-Path $src 'DisplaySwitch.ico'
    & $csc /nologo /codepage:65001 /target:winexe /r:System.Windows.Forms.dll /r:System.Drawing.dll "/win32icon:$icon" "/out:$exe" (Join-Path $src 'TraySwitcher.cs')
    if ($LASTEXITCODE -ne 0) { throw '编译失败' }
}

$target = Join-Path $dst 'TraySwitcher.exe'
if (Test-Path $target) { Copy-Item $target "$target.previous" -Force }
Copy-Item $exe $target -Force
if (Test-Path (Join-Path $src 'DisplaySwitch.ico')) { Copy-Item (Join-Path $src 'DisplaySwitch.ico') $dst -Force }

# 开机自启（当前用户）；清掉旧版放在「启动」文件夹的快捷方式
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MonitorSwitch' -Value "`"$target`""
$oldLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'TraySwitcher.lnk'
if (Test-Path $oldLnk) { Remove-Item $oldLnk -Force }

Start-Process $target
Write-Host "[OK] 已安装到 $dst 并启动，已设为开机自启。"
Write-Host '     点右下角托盘的双屏图标打开菜单；第一次会提示识别显示器接口。'
