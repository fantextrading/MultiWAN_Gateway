# MultiWAN Gateway

Gateway Linux che aggrega due connessioni WAN (es. fibra + 5G) per un host Windows, tramite una VM Debian in Hyper-V.

## Architettura

```
Windows host
  └── default route via VM (metric 5)
         ↓
  VM Debian (Hyper-V)
  ├── eth0 (WAN1, es. fibra) → gateway ISP → internet
  └── eth1 (WAN2, es. 5G)   → gateway ISP → internet
  
  Modalita':
  ├── ECMP: ogni connessione TCP → WAN1 oppure WAN2 (L4 hash)
  ├── Split Proxy (:8080): download aggregati su entrambe le WAN
  └── VPN (Glorytun MUD): tunnel aggregato con IP fisso VPS
```

## Componenti

| Componente | Descrizione |
|-----------|-------------|
| `vm/split_proxy.py` | Proxy HTTP con split-download su due WAN + tunnel CONNECT per HTTPS |
| `vm/glorytun-client-start.sh` | Script avvio: policy routing, NAT, ECMP, glorytun |
| `vm/glorytun-client.service` | Systemd unit per glorytun |
| `vm/split-proxy.service` | Systemd unit per il proxy |
| `vm/sysctl-multiwan.conf` | Sysctl: ip_forward + L4 hash policy |
| `vm/setup.sh` | Script di deploy automatico sulla VM |
| `windows/setup-route.bat` | Configura route Windows verso la VM |
| `windows/set-proxy.bat` | Abilita/disabilita proxy di sistema |

## Quick Start

### 1. Preparare la VM

VM Debian 12+ con due interfacce di rete (una per WAN).

```bash
# Sulla VM, da root:
git clone <repo> && cd MultiWAN_Gateway

# Editare le configurazioni in vm/glorytun-client-start.sh:
#   - ETH0_DEV, ETH1_DEV (nomi interfacce)
#   - VPN_SERVER (IP del VPS per il tunnel)
#   - TUN_LOCAL_IP, TUN_REMOTE_IP

# Editare IFACES in vm/split_proxy.py con gli IP delle due WAN

# Deploy
bash vm/setup.sh
```

### 2. Configurare Windows

```cmd
REM Da CMD come amministratore:

REM Routing diretto via VM (ECMP, max banda):
windows\setup-route.bat

REM Opzionale: abilitare il proxy per split-download HTTP:
windows\set-proxy.bat

REM Disabilitare il proxy:
windows\set-proxy.bat off
```

## Modalita' di funzionamento

### ECMP (default, max banda)

Ogni nuova connessione TCP viene instradata su WAN1 o WAN2 tramite L4 hash. Nessun reordering, banda aggregata per download paralleli.

```
sysctl net.ipv4.fib_multipath_hash_policy=1
ip route add default nexthop via GW1 dev eth0 w 1 nexthop via GW2 dev eth1 w 1
```

### Split Proxy (porta 8080)

Proxy HTTP che spezza i download grandi in chunk e li scarica in parallelo su entrambe le WAN. Supporta:
- **GET/HEAD**: split-download con range requests (file > 4MB)
- **CONNECT**: tunnel HTTPS bidirezionale (per Electron, Claude Desktop, ecc.)

```bash
# Test download via proxy:
curl -x http://VM_IP:8080 http://example.com/large-file.bin

# Test HTTPS via proxy (tunnel CONNECT):
curl -x http://VM_IP:8080 https://claude.ai
```

### VPN (Glorytun MUD, IP fisso)

Tunnel che aggrega entrambe le WAN verso un VPS con IP fisso. Utile quando serve un IP pubblico stabile.

```bash
# Attivare VPN mode:
ip route del default
ip route add default via 10.255.255.1 metric 50

# Tornare a ECMP:
systemctl restart glorytun-client
```

## Prerequisiti

### VM (Debian 12+)
- `nftables` (installato di default)
- `python3` (per split_proxy.py)
- `glorytun` compilato (per il tunnel VPN)

### VPS (per modalita' VPN)
- Glorytun server in ascolto
- Stessa chiave in `/etc/glorytun/key`

### Windows
- Hyper-V con VM Debian collegata a entrambe le WAN
- Route default via VM

## Troubleshooting

| Problema | Soluzione |
|---------|-----------|
| `ERR_TUNNEL_CONNECTION_FAILED` in app Electron | Verificare che split_proxy supporti CONNECT (v4+) |
| Download non aggregati | Verificare `fib_multipath_hash_policy=1` e ECMP route attiva |
| App MSIX non si connette | `CheckNetIsolation LoopbackExempt -a -n="<PackageFamily>"` |
| Proxy non raggiungibile | `ss -tlnp \| grep 8080` sulla VM, verificare firewall |
