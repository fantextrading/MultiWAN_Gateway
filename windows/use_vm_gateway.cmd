@echo off
REM use_vm_gateway.cmd — Ripristina gateway VM con ECMP + split proxy
REM Richiede CMD amministratore.

net session >nul 2>&1
if errorlevel 1 (
    echo [ERRORE] Eseguire come amministratore.
    pause
    exit /b 1
)

echo === Switch a VM gateway (ECMP fibra + 5G + split proxy) ===

echo.
echo [1/3] Ripristino metrica 5G a default (automatica)...
route change 0.0.0.0 mask 0.0.0.0 192.168.3.1 metric 25 >nul 2>&1

echo [2/3] Imposto route permanente verso VM (metric 5)...
route -p change 0.0.0.0 mask 0.0.0.0 192.168.2.21 metric 5 >nul 2>&1
if errorlevel 1 route -p add 0.0.0.0 mask 0.0.0.0 192.168.2.21 metric 5

echo [3/3] Attivo proxy HTTP 192.168.2.21:8080...
powershell -NoProfile -Command "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 1; Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value '192.168.2.21:8080'"

echo.
echo === Stato attuale ===
route print 0.0.0.0 | findstr /R "0\.0\.0\.0"
echo.
echo Test connettivita' VM:
ping -n 2 -w 1000 192.168.2.21 | findstr /R "Risposta Reply"
echo.
echo Fatto. Traffico instradato via VM (ECMP + split proxy per HTTP).
echo Per tornare al 5G diretto: use_5g_only.cmd
pause
