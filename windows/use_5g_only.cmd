@echo off
REM use_5g_only.cmd — Bypass VM gateway, use 5G direct (Windows native)
REM Richiede CMD amministratore.

net session >nul 2>&1
if errorlevel 1 (
    echo [ERRORE] Eseguire come amministratore.
    pause
    exit /b 1
)

echo === Switch a 5G-only (Windows nativo) ===

echo.
echo [1/3] Rimuovo route permanente verso VM (192.168.2.21)...
route -p delete 0.0.0.0 mask 0.0.0.0 192.168.2.21 >nul 2>&1
route    delete 0.0.0.0 mask 0.0.0.0 192.168.2.21 >nul 2>&1

echo [2/3] Imposto 5G come default preferito (metric 10)...
route change 0.0.0.0 mask 0.0.0.0 192.168.3.1 metric 10 >nul 2>&1
if errorlevel 1 route add 0.0.0.0 mask 0.0.0.0 192.168.3.1 metric 10

echo [3/3] Disattivo proxy HTTP di sistema...
powershell -NoProfile -Command "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0"

echo.
echo === Stato attuale ===
route print 0.0.0.0 | findstr /R "0\.0\.0\.0"
echo.
echo IP pubblico:
curl -s -m 5 https://ifconfig.me
echo.
echo.
echo Fatto. Il traffico ora esce direttamente dal 5G.
echo Per tornare al gateway VM: use_vm_gateway.cmd
pause
