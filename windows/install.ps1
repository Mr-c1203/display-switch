<#
install.ps1 - one-time setup on the Windows machine.

What it does:
  1. Builds TraySwitcher.exe with the C# compiler that ships with Windows,
     writes the machine list to TraySwitcher.ini, adds it to Startup
     (auto-start), and launches it now (tray icon: right-click = machine menu
     with checkmark, left-click = toggle to the other machine).
  2. Creates a desktop shortcut bound to Ctrl+Alt+M that switches to the
     other machine's input.

Usage:
  Set-ExecutionPolicy -Scope Process Bypass -Force
  .\install.ps1 -TargetCode 21     # the OTHER machine's input code (e.g. the Mac: 21)
  .\install.ps1 -TargetCode 21 -ThisCode 17   # also label this machine (17 = this PC's input)
#>
param([int]$TargetCode = 0, [int]$ThisCode = 0)

$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $TargetCode) {
    $TargetCode = Read-Host 'Enter the input-source code of the OTHER machine (decimal; e.g. the Mac occupies 21)'
}
if (-not $ThisCode) {
    $s = Read-Host 'Enter THIS machine input code (optional, press Enter to skip)'
    if ($s -match '^\s*(\d+)\s*$') { $ThisCode = [int]$Matches[1] }
}
if ($TargetCode -le 0) { throw '必须提供另一台机器的有效输入源编号。' }
if ($ThisCode -gt 0 -and $ThisCode -eq $TargetCode) { throw '两台机器的输入源编号不能相同。' }

# 1) build the tray tool
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (Test-Path $csc) {
    $iconPath = Join-Path $dir 'DisplaySwitch.ico'
    if (-not (Test-Path $iconPath)) { throw '缺少双屏图标 DisplaySwitch.ico；请使用完整安装包。' }
    if (Test-Path "$dir\TraySwitcher.exe") {
        Copy-Item "$dir\TraySwitcher.exe" "$dir\TraySwitcher.exe.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    }
    if (Test-Path "$dir\TraySwitcher.ini") {
        Copy-Item "$dir\TraySwitcher.ini" "$dir\TraySwitcher.ini.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    }
    # Stop only a previous copy launched from this installer directory.
    Get-CimInstance Win32_Process -Filter "Name='TraySwitcher.exe'" |
        Where-Object { $_.ExecutablePath -eq (Join-Path $dir 'TraySwitcher.exe') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction Stop }
    & $csc /nologo /codepage:65001 /target:winexe /out:"$dir\TraySwitcher.exe" `
        /r:System.Windows.Forms.dll /r:System.Drawing.dll /win32icon:"$iconPath" "$dir\TraySwitcher.cs"
    if ($LASTEXITCODE -ne 0) { throw 'Windows 托盘程序编译失败；旧版备份已保留。' }
    if (Test-Path "$dir\TraySwitcher.exe") {
        if ($ThisCode -gt 0) {
            Set-Content -Path "$dir\TraySwitcher.ini" -Value "$TargetCode, other machine`n$ThisCode, this PC" -Encoding ASCII
        } else {
            Set-Content -Path "$dir\TraySwitcher.ini" -Value "$TargetCode" -Encoding ASCII
        }
        $ws = New-Object -ComObject WScript.Shell
        $startupLnk = $ws.CreateShortcut((Join-Path [Environment]::GetFolderPath('Startup') 'TraySwitcher.lnk'))
        $startupLnk.TargetPath = "$dir\TraySwitcher.exe"
        $startupLnk.WorkingDirectory = $dir
        $startupLnk.Save()
        Start-Process "$dir\TraySwitcher.exe"
        Write-Host "[OK] 双屏图标版 TraySwitcher.exe 已编译并启动，已添加到开机启动。"
        Write-Host "     Tray icon: left-click = toggle, right-click = machine menu (checkmark = on screen)."
        Write-Host "     Edit TraySwitcher.ini to rename the labels shown in the menu."
    }
} else { throw '未找到 Windows .NET Framework C# 编译器，无法安装托盘版。' }

# 2) desktop shortcut + Ctrl+Alt+M
$ws = New-Object -ComObject WScript.Shell
$deskLnk = $ws.CreateShortcut((Join-Path [Environment]::GetFolderPath('Desktop') 'Switch monitor to laptop.lnk'))
$deskLnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$deskLnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\Switch-MonitorInput.ps1`" -Target $TargetCode"
$deskLnk.WorkingDirectory = $dir
$deskLnk.Hotkey = 'CTRL+ALT+M'
$deskLnk.WindowStyle = 7
$deskLnk.Save()
Write-Host "[OK] Desktop shortcut created, hotkey Ctrl+Alt+M -> input code $TargetCode"
Write-Host 'If nothing happens, enable DDC/CI in the monitor OSD menu, and re-run -ShowCurrent to verify.'
