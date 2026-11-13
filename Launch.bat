@echo off
chcp 936 >nul 2>nul
rem 备用启动方式：如果系统禁用了 VBS（组策略 / 安全软件），可双击本文件启动核桃便签。
setlocal
cd /d "%~dp0"

if not exist "%~dp0HetaoNotes.ps1" goto :nofile
if not exist "%~dp0ui.xaml" goto :nofile

rem 需要 Windows PowerShell 5.1（Win10 / Win11 自带）
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "exit [int]([version]$PSVersionTable.PSVersion -lt [version]'5.1')"
if errorlevel 1 goto :oldps

start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HetaoNotes.ps1"
exit /b 0

:nofile
echo.
echo   启动失败：找不到 HetaoNotes.ps1 或 ui.xaml。
echo   这两个文件必须和本文件放在同一个文件夹里。
echo   请先把压缩包完整解压，再双击 Launch.vbs。
echo.
pause
exit /b 1

:oldps
echo.
echo   启动失败：这台电脑的 Windows PowerShell 版本低于 5.1。
echo   Windows 10 / Windows 11 自带 5.1，可直接运行。
echo   Windows 7 / 8.1 请先安装 Windows Management Framework 5.1 后重试。
echo.
pause
exit /b 1
