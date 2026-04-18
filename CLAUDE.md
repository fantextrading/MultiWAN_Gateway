# MultiWAN Gateway — Aggregazione fibra + 5G su VM Hyper-V

Gateway Linux (Debian 13, Hyper-V) che aggrega due connessioni internet
(fibra + 5G) tramite ECMP routing e split-download proxy HTTP.

## Topologia

```
Windows host (192.168.2.183 / 192.168.3.208)
  └── route 0.0.0.0/0 via 192.168.2.21 metric 5
         │
  ┌──────▼──────────────────────────────────────┐
  │  VM Debian 13 (Hyper-V)                     │
  │  eth0: 192.168.2.21  ── fibra ── gw .2.1    │
  │  eth1: 192.168.3.21  ── 5G   ── gw .3.1     │
  │  tun0: 10.255.255.2/30  (glorytun, fallback) │
  │                                             │
  │  ECMP default route: nexthop eth0 + eth1    │
  │  NAT masquerade: eth0, eth1, tun0           │
  │  split_proxy.py  :8080  (HTTP aggregation)  │
  └──────────────────────────────────────────────┘
         │ eth0 (fibra)       │ eth1 (5G)
         ▼                    ▼
      internet             internet
         │                    │
         └────── (opzionale) ──┘
                    ▼
         RackNerd VPS 192.3.15.172
         tun0: 10.255.255.1/30
         (glorytun-server — modalità VPN)
```

## Prerequisiti

### VM (Debian 13, Hyper-V)
- 2 vNIC su switch esterni Hyper-V (una su fibra, una su 5G/WiFi)
- `glorytun-clean` compilato: `/usr/local/bin/glorytun-clean`
- Chiave tunnel: `/etc/glorytun/key` (stessa su VM e Server)
- Python 3 installato

### Server (RackNerd 192.3.15.172)
- `glorytun` (binary stock): `/usr/local/bin/glorytun`
- Chiave tunnel: `/etc/glorytun/key`
- Porta UDP 65001 aperta in iptables/ufw

### Windows (host Hyper-V)
- Route verso VM con metric bassa (vedi §Windows setup)
- Proxy di sistema impostato su 192.168.2.21:8080 (per HTTP)

---

## Deploy rapido

```bash
# Da Windows, nella cartella del progetto:
pip install paramiko
python deploy.py          # VM + Server
python deploy.py vm       # solo VM
python deploy.py server   # solo Server
python deploy.py status   # verifica stato
```

---

## Setup manuale passo-passo

### 1. Build glorytun-clean (VM)

```bash
# Solo la prima volta — il binary non è incluso per portabilità
apt install build-essential libsodium-dev git -y
git clone https://github.com/angt/glorytun /tmp/glorytun
cd /tmp/glorytun
git submodule update --init

# Rimuovi debug fprintf dal hot-path mud_send (causano stall del tunnel sotto carico)
# File: /tmp/glorytun/mud/mud.c  — rimuovi le righe fprintf(stderr,...) in mud_send
# File: /tmp/glorytun/src/bind.c — rimuovi fprintf che accedono a struct mud (privata)
make
cp glorytun /usr/local/bin/glorytun-clean
```

### 2. Chiave tunnel (VM + Server, identica)

```bash
# Genera su VM, copia su Server
dd if=/dev/urandom bs=32 count=1 2>/dev/null | xxd -p -c 64 > /etc/glorytun/key
chmod 600 /etc/glorytun/key

# Copia su Server
scp /etc/glorytun/key root@192.3.15.172:/etc/glorytun/key
```

### 3. Deploy file (VM)

```bash
# Copia script
cp vm/glorytun-client-start.sh /usr/local/bin/
chmod +x /usr/local/bin/glorytun-client-start.sh

cp vm/split_proxy.py /usr/local/bin/
chmod +x /usr/local/bin/split_proxy.py

# Systemd
cp vm/glorytun-client.service /etc/systemd/system/
cp vm/split-proxy.service     /etc/systemd/system/

# Sysctl
cp vm/sysctl-99-gateway.conf /etc/sysctl.d/99-gateway.conf
sysctl -p /etc/sysctl.d/99-gateway.conf

# Avvia
systemctl daemon-reload
systemctl enable --now glorytun-client split-proxy
```

### 4. Deploy file (Server)

```bash
cp server/glorytun-server.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now glorytun-server
```

### 5. Windows — routing

Da **CMD amministratore**:

```cmd
REM Abbassa metrica route verso VM (la route esiste già, metric 25 default)
route change 0.0.0.0 mask 0.0.0.0 192.168.2.21 metric 5

REM Permanente (sopravvive a reboot):
route -p change 0.0.0.0 mask 0.0.0.0 192.168.2.21 metric 5
```

Oppure esegui `windows\set_route.cmd` come amministratore.

### 6. Windows — proxy HTTP (per aggregazione su singolo download)

```powershell
.\windows\set_proxy.ps1       # attiva proxy 192.168.2.21:8080
.\windows\set_proxy.ps1 off   # disattiva (torna ECMP diretto)
```

---

## Modalità operative

### Modalità A — ECMP diretto (default, massima velocità)

Il traffico Windows viene bilanciato su fibra e 5G. Ogni connessione TCP
usa una delle due WAN. Più connessioni in parallelo usano entrambe.

- IP pubblico: fibra (93.49.249.144) o 5G (151.35.155.155) per connessione
- Velocità singola connessione: max(fibra, 5G) ≈ 53 Mbits
- Velocità parallele: fibra + 5G ≈ 95 Mbits

### Modalità B — Split proxy (banda cumulata su singolo download HTTP)

`curl -x http://192.168.2.21:8080 URL` oppure proxy di sistema attivo.
Il proxy scarica metà file via fibra, metà via 5G, riassembla e invia a Windows.

- Funziona solo per HTTP (non HTTPS)
- Velocità singolo download: fibra + 5G ≈ 73-82 Mbits
- Richiede server che supporta `Range: bytes=N-M` (la maggior parte)

### Modalità C — VPN (IP fisso RackNerd)

Tutto il traffico esce dall'IP VPS (192.3.15.172). Attivazione manuale:

```bash
# Su VM:
ip route del default
ip route add default via 10.255.255.1 metric 50
# Torna ECMP:
systemctl restart glorytun-client
```

---

## Verifica e diagnostica

```bash
# Stato completo (da Windows, con paramiko)
python deploy.py status

# Manuale via SSH
ssh root@192.168.3.21

systemctl status glorytun-client split-proxy
glorytun path dev tun0           # paths fibra+5G verso VPS
ip route show default            # deve mostrare nexthop eth0+eth1
tail -f /var/log/glorytun-client.log
tail -f /var/log/split-proxy.log

# Test velocità dal proxy
curl -x http://192.168.2.21:8080 -o /dev/null \
     -w "Speed: %{speed_download} B/s" \
     http://speedtest.tele2.net/100MB.zip
```

---

## Prestazioni misurate (2026-04-18)

| Test | Velocità |
|------|---------|
| Fibra sola (eth0, VM) | 6.73 MB/s = 53.8 Mbits |
| 5G sola (eth1, VM) | 5.21 MB/s = 41.7 Mbits |
| 2 paralleli (VM, una per WAN) | 9.12 MB/s = 73 Mbits |
| **Split proxy — singolo download (Windows)** | **7.6–10.2 MB/s = 61–82 Mbits** |
| ECMP singolo (Windows, una WAN) | 7.7 MB/s = 62 Mbits |
| 4 paralleli ECMP (Windows) | ~22 MB/s totale |
| VPN tunnel (glorytun via VPS) | 2.6 MB/s = 20.7 Mbits |

---

## File del progetto

```
MultiWAN_Gateway/
├── CLAUDE.md                       # questa guida
├── deploy.py                       # deploy automatico VM + Server
├── vm/
│   ├── glorytun-client-start.sh    # script avvio: policy routing, ECMP, NAT, glorytun
│   ├── glorytun-client.service     # systemd unit client
│   ├── split_proxy.py              # proxy HTTP split-download
│   ├── split-proxy.service         # systemd unit proxy
│   └── sysctl-99-gateway.conf      # ip_forward + ECMP hash persistente
└── server/
│   └── glorytun-server.service     # systemd unit server VPS
└── windows/
    ├── set_proxy.ps1               # attiva/disattiva proxy di sistema
    └── set_route.cmd               # configura routing (da eseguire come admin)
```

---

## Indirizzi di riferimento

| Componente | Indirizzo |
|-----------|-----------|
| VM eth0 (fibra) | 192.168.2.21 |
| VM eth1 (5G) | 192.168.3.21 |
| VM tun0 (tunnel client) | 10.255.255.2/30 |
| Server VPS (RackNerd) | 192.3.15.172 |
| Server tun0 (tunnel server) | 10.255.255.1/30 |
| Split proxy | 192.168.2.21:8080 |
| IP fibra pubblico | 93.49.249.144 |
| IP 5G pubblico | 151.35.155.155 |
| IP VPS (modalità VPN) | 192.3.15.172 |

---

## Note tecniche critiche

- **Debian 13 usa nftables**, non iptables. Tutti i comandi NAT usano `nft`.
- **`/etc/iproute2/rt_tables` non esiste** su questa VM. Policy routing usa
  tabelle numeriche (201, 202) direttamente.
- **glorytun-clean** è il binary senza `fprintf` nel hot-path `mud_send`
  (mud.c). Il binary stock con debug prints stalla il tunnel sotto carico.
- **`rate fixed tx 12500000 rx 12500000`**: necessario per bootstrap della
  finestra MUD (altrimenti window=0 perché rate=0 all'avvio).
- **ExecStartPre pkill glorytun**: necessario per evitare che glorytun si
  agganci a un tun0 residuo di un avvio precedente.
- Il server RackNerd necessita di `pkill glorytun + ip link del tun0` prima
  di `systemctl start` se il servizio era in stato failed.
