@echo off
setlocal
:: Windows 11 IoT — winget ohne Store. Startet das PowerShell-Script als Admin.
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Bitte als Administrator ausfuehren.
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WinGet-IoT.ps1" %*
echo.
pause
