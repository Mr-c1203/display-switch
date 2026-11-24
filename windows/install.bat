@echo off
rem 显示器切换 - 双击安装（Windows）
rem 复制程序到 %LocalAppData%\显示器切换\app，设为开机自启并启动。
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
