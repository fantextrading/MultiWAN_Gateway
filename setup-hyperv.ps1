#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Setup automatico VM Debian gateway per aggregazione Multi-WAN su Hyper-V.

.DESCRIPTION
    Crea una VM Debian con due interfacce di rete (una per WAN), scarica
    l'ISO Debian netinst, configura gli switch virtuali Hyper-V e prepara
    il routing Windows verso la VM.

.USAGE
    1. Collegare le due connessioni WAN al PC (es. Ethernet fibra + USB 5G)
    2. Eseguire come amministratore:
       .\setup-hyperv.ps1
    3. Installare Debian sulla VM (guided, minimal)
    4. Dopo installazione Debian, eseguire nella VM:
       bash /mnt/setup/setup.sh

.NOTES
    Testato su Windows 11 Pro con Hyper-V abilitato.
#>

param(
    [string]$VMName = "MultiWAN-Gateway",
    [int]$MemoryMB = 2048,
    [int]$DiskGB = 20,
    [string]$VMPath = "$env:USERPROFILE\Hyper-V\MultiWAN",
    [string]$DebianISO = ""
)

$ErrorActionPreference = "Stop"

Write-Host "=== MultiWAN Gateway - Hyper-V Setup ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Verifica Hyper-V ---
Write-Host "[1/7] Verifica Hyper-V..." -ForegroundColor Yellow
$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hv.State -ne "Enabled") {
    Write-Host "Hyper-V non abilitato. Abilitarlo con:" -ForegroundColor Red
    Write-Host "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart"
    Write-Host "  Poi riavviare il PC."
    exit 1
}
Write-Host "  Hyper-V OK" -ForegroundColor Green

# --- 2. Identifica adattatori di rete ---
Write-Host ""
Write-Host "[2/7] Adattatori di rete disponibili:" -ForegroundColor Yellow
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notlike '*Hyper-V*' -and $_.Name -notlike '*vEthernet*' -and $_.Name -notlike '*Loopback*' }
$i = 0
$adapterList = @()
foreach ($a in $adapters) {
    $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    Write-Host "  [$i] $($a.Name) - $($a.InterfaceDescription) - IP: $ip"
    $adapterList += $a
    $i++
}

if ($adapterList.Count -lt 2) {
    Write-Host ""
    Write-Host "ERRORE: Servono almeno 2 adattatori di rete attivi." -ForegroundColor Red
    Write-Host "Collegare la seconda connessione WAN (es. USB 5G, WiFi bridge)."
    exit 1
}

Write-Host ""
$wan1idx = Read-Host "Seleziona adattatore WAN 1 (es. fibra) [0-$($adapterList.Count-1)]"
$wan2idx = Read-Host "Seleziona adattatore WAN 2 (es. 5G)    [0-$($adapterList.Count-1)]"
$WAN1 = $adapterList[[int]$wan1idx]
$WAN2 = $adapterList[[int]$wan2idx]
Write-Host "  WAN1: $($WAN1.Name)" -ForegroundColor Green
Write-Host "  WAN2: $($WAN2.Name)" -ForegroundColor Green

# --- 3. Crea switch virtuali Hyper-V ---
Write-Host ""
Write-Host "[3/7] Configurazione switch virtuali Hyper-V..." -ForegroundColor Yellow

$sw1Name = "MultiWAN-SW1"
$sw2Name = "MultiWAN-SW2"

$existingSw1 = Get-VMSwitch -Name $sw1Name -ErrorAction SilentlyContinue
if (-not $existingSw1) {
    New-VMSwitch -Name $sw1Name -NetAdapterName $WAN1.Name -AllowManagementOS $true | Out-Null
    Write-Host "  Creato switch $sw1Name -> $($WAN1.Name)" -ForegroundColor Green
} else {
    Write-Host "  Switch $sw1Name gia' esistente" -ForegroundColor Green
}

$existingSw2 = Get-VMSwitch -Name $sw2Name -ErrorAction SilentlyContinue
if (-not $existingSw2) {
    New-VMSwitch -Name $sw2Name -NetAdapterName $WAN2.Name -AllowManagementOS $true | Out-Null
    Write-Host "  Creato switch $sw2Name -> $($WAN2.Name)" -ForegroundColor Green
} else {
    Write-Host "  Switch $sw2Name gia' esistente" -ForegroundColor Green
}

# --- 4. Scarica ISO Debian (se non fornita) ---
Write-Host ""
Write-Host "[4/7] ISO Debian..." -ForegroundColor Yellow

if (-not $DebianISO -or -not (Test-Path $DebianISO)) {
    $isoUrl = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso"
    $isoPath = "$VMPath\debian-netinst.iso"

    if (Test-Path $isoPath) {
        Write-Host "  ISO gia' presente: $isoPath" -ForegroundColor Green
        $DebianISO = $isoPath
    } else {
        Write-Host "  Download ISO Debian netinst..."
        Write-Host "  URL: $isoUrl"
        New-Item -ItemType Directory -Force -Path $VMPath | Out-Null

        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing
            $DebianISO = $isoPath
            Write-Host "  ISO scaricata: $isoPath" -ForegroundColor Green
        } catch {
            Write-Host "  Download fallito. Scarica manualmente l'ISO Debian netinst e passa il path:" -ForegroundColor Red
            Write-Host "  .\setup-hyperv.ps1 -DebianISO 'C:\path\to\debian.iso'"
            exit 1
        }
    }
} else {
    Write-Host "  ISO fornita: $DebianISO" -ForegroundColor Green
}

# --- 5. Crea VM ---
Write-Host ""
Write-Host "[5/7] Creazione VM '$VMName'..." -ForegroundColor Yellow

$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Host "  VM '$VMName' gia' esistente. Saltata creazione." -ForegroundColor Yellow
    Write-Host "  Per ricrearla: Remove-VM -Name '$VMName' -Force"
} else {
    New-Item -ItemType Directory -Force -Path $VMPath | Out-Null

    # Crea VM Gen 2
    New-VM -Name $VMName `
        -MemoryStartupBytes ($MemoryMB * 1MB) `
        -NewVHDPath "$VMPath\$VMName.vhdx" `
        -NewVHDSizeBytes ($DiskGB * 1GB) `
        -Generation 2 `
        -SwitchName $sw1Name | Out-Null

    # Aggiungi seconda NIC
    Add-VMNetworkAdapter -VMName $VMName -SwitchName $sw2Name

    # Configura
    Set-VMProcessor -VMName $VMName -Count 2
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -MinimumBytes 512MB -MaximumBytes ($MemoryMB * 1MB)
    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

    # Monta ISO
    Add-VMDvdDrive -VMName $VMName -Path $DebianISO
    $dvd = Get-VMDvdDrive -VMName $VMName
    Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd

    # Abilita guest services (per file copy)
    Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

    Write-Host "  VM creata: 2 vCPU, ${MemoryMB}MB RAM, ${DiskGB}GB disco" -ForegroundColor Green
    Write-Host "  NIC1: $sw1Name (WAN1)" -ForegroundColor Green
    Write-Host "  NIC2: $sw2Name (WAN2)" -ForegroundColor Green
}

# --- 6. Prepara file di configurazione ---
Write-Host ""
Write-Host "[6/7] Preparazione file di configurazione..." -ForegroundColor Yellow

$configDir = "$VMPath\vm-config"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Copy-Item "$scriptDir\vm\*" -Destination $configDir -Force -ErrorAction SilentlyContinue
Write-Host "  File copiati in: $configDir" -ForegroundColor Green

# --- 7. Istruzioni finali ---
Write-Host ""
Write-Host "[7/7] Prossimi passi:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Avvia la VM:" -ForegroundColor White
Write-Host "     Start-VM -Name '$VMName'"
Write-Host ""
Write-Host "  2. Connettiti alla console e installa Debian:" -ForegroundColor White
Write-Host "     vmconnect localhost '$VMName'"
Write-Host "     - Installazione minimal (no desktop)"
Write-Host "     - Configura entrambe le interfacce di rete via DHCP"
Write-Host "     - Abilita SSH server"
Write-Host ""
Write-Host "  3. Dopo l'installazione, copia i file sulla VM:" -ForegroundColor White
Write-Host "     scp -r $configDir/* root@<VM_IP>:/root/setup/"
Write-Host ""
Write-Host "  4. Sulla VM, esegui il setup:" -ForegroundColor White
Write-Host "     ssh root@<VM_IP>"
Write-Host "     cd /root/setup && bash setup.sh"
Write-Host ""
Write-Host "  5. Su Windows, configura il routing:" -ForegroundColor White
Write-Host "     route add 0.0.0.0 mask 0.0.0.0 <VM_IP> metric 5"
Write-Host ""
Write-Host "  6. Installa FDM e imposta 16 connessioni per download" -ForegroundColor White
Write-Host ""
Write-Host "=== Setup completato ===" -ForegroundColor Cyan
