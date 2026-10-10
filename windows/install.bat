@echo off
rem ============================================================
rem  Monitor input switcher - DOUBLE-CLICK installer (Windows)
rem
rem  1. Builds TraySwitcher.exe with the compiler built into
rem     Windows (tray icon: left-click = switch, auto-start)
rem  2. Creates a desktop shortcut with hotkey Ctrl+Alt+M
rem
rem  It will ask for the input code used by the OTHER computer.
rem ============================================================
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
