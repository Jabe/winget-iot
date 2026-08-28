@echo off
setlocal
:: Windows 11 IoT -- winget without Store. Relaunches this script as Administrator.
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Please run as Administrator.
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WinGet-IoT.ps1" %*
echo.
pause
