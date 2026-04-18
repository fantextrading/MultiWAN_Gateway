@echo off
REM set_route.cmd — Configura routing Windows verso VM gateway
REM Eseguire come Amministratore
REM
REM Abbassa la metrica della route verso la VM (192.168.2.21) a 5,
REM in modo che vinca sulle route dirette fibra (metric 20) e 5G (metric 25).
REM Il traffico Windows passa: Windows -> VM -> ECMP fibra+5G -> internet

echo Configurazione route verso VM gateway (192.168.2.21)...

REM La route esiste gia' (metric 25), basta cambiarla
route change 0.0.0.0 mask 0.0.0.0 192.168.2.21 metric 5
if %errorlevel% neq 0 (
    echo Tentativo con route add...
    route add 0.0.0.0 mask 0.0.0.0 192.168.2.21 metric 5
)

echo.
echo Route attive:
route print 0.0.0.0

echo.
echo Test IP pubblico (deve essere 93.49.x.x oppure 151.35.x.x via ECMP,
echo oppure 192.3.15.172 se modalita' VPN attiva):
curl -s --max-time 10 http://ipinfo.io/ip

echo.
echo Per rendere permanente (sopravvive a reboot):
echo   route -p change 0.0.0.0 mask 0.0.0.0 192.168.2.21 metric 5
