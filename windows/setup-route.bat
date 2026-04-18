@echo off
REM setup-route.bat — Configure Windows to route traffic through the VM gateway
REM Run as Administrator
REM
REM CUSTOMIZE: Change VM_GATEWAY to your VM's IP on the LAN facing Windows.

set VM_GATEWAY=192.168.2.21
set METRIC=5

echo === Multi-WAN Gateway - Windows Route Setup ===
echo.
echo Gateway VM: %VM_GATEWAY%
echo Metric: %METRIC%
echo.

REM Add/change default route to point to VM
route change 0.0.0.0 mask 0.0.0.0 %VM_GATEWAY% metric %METRIC%
if %errorlevel% neq 0 (
    echo Route change failed, trying add...
    route add 0.0.0.0 mask 0.0.0.0 %VM_GATEWAY% metric %METRIC%
)

echo.
echo Current default routes:
route print 0.0.0.0

echo.
echo === Done ===
echo.
echo To make permanent: route -p change 0.0.0.0 mask 0.0.0.0 %VM_GATEWAY% metric %METRIC%
echo To set proxy for apps: set HTTP_PROXY=http://%VM_GATEWAY%:8080
echo                        set HTTPS_PROXY=http://%VM_GATEWAY%:8080
