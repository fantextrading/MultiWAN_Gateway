@echo off
REM set-proxy.bat — Configure system proxy to use the split-download proxy
REM Run as Administrator
REM
REM This enables the split-download proxy for HTTP traffic and HTTPS tunneling.
REM Apps that respect system proxy settings will use it automatically.

set VM_GATEWAY=192.168.2.21
set PROXY_PORT=8080
set PROXY=%VM_GATEWAY%:%PROXY_PORT%

echo === Multi-WAN Gateway - Proxy Setup ===
echo.

if "%1"=="off" goto disable

echo Enabling system proxy: %PROXY%
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /t REG_SZ /d "%PROXY%" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /t REG_SZ /d "localhost;127.*;192.168.*;<local>" /f

echo.
echo Proxy enabled. Restart browsers/apps to apply.
echo To disable: %~nx0 off
goto end

:disable
echo Disabling system proxy...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f

echo.
echo Proxy disabled.

:end
echo.
