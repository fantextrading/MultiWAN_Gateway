# set_proxy.ps1 — Imposta/rimuove il proxy HTTP di sistema su Windows
# Uso: .\set_proxy.ps1 [on|off]
# Default: on

param([string]$Action = "on")

$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$proxyHost = '192.168.2.21'
$proxyPort = '8080'

if ($Action -eq "off") {
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0
    Write-Host "Proxy DISATTIVATO — traffico diretto su ECMP (fibra/5G)"
} else {
    Set-ItemProperty -Path $reg -Name ProxyEnable   -Value 1
    Set-ItemProperty -Path $reg -Name ProxyServer   -Value "${proxyHost}:${proxyPort}"
    # Bypass: reti locali e indirizzi interni
    Set-ItemProperty -Path $reg -Name ProxyOverride -Value '192.168.2.*;192.168.3.*;10.*;172.*;localhost;<local>'
    Write-Host "Proxy ATTIVATO: ${proxyHost}:${proxyPort}"
    Write-Host "Bypass: reti locali (192.168.x, 10.x, 172.x)"
}

$s = Get-ItemProperty -Path $reg
Write-Host "Stato: ProxyEnable=$($s.ProxyEnable)  Server=$($s.ProxyServer)"
