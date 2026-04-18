#!/bin/bash
# setup.sh — Deploy Multi-WAN Gateway on a fresh Debian 12/13 VM
# Rileva automaticamente le interfacce, configura ECMP, NAT e split proxy.
#
# Prerequisites:
#   - Debian 12+ con due interfacce di rete (DHCP attivo su entrambe)
#   - Accesso root
#
# Usage: bash setup.sh
#
# Opzionale (per VPN con IP fisso):
#   - glorytun binary in /usr/local/bin/glorytun-clean
#   - Chiave in /etc/glorytun/key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Multi-WAN Gateway Setup ==="
echo ""

# --- Auto-detect interfacce ---
echo "[1/6] Rilevamento interfacce di rete..."
IFACES=()
while IFS= read -r line; do
    dev=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $2}')
    ip=$(echo "$line" | awk '{print $3}' | cut -d/ -f1)
    if [[ "$dev" != "lo" && "$state" == "UP" && -n "$ip" && "$dev" != tun* ]]; then
        IFACES+=("$dev:$ip")
        echo "  $dev = $ip ($state)"
    fi
done < <(ip -br -4 addr show)

if [ ${#IFACES[@]} -lt 2 ]; then
    echo ""
    echo "ERRORE: Servono almeno 2 interfacce di rete attive con IP."
    echo "Interfacce trovate: ${#IFACES[@]}"
    echo "Verificare che entrambe le NIC abbiano IP via DHCP."
    exit 1
fi

ETH0_DEV=$(echo "${IFACES[0]}" | cut -d: -f1)
ETH0_IP=$(echo "${IFACES[0]}" | cut -d: -f2)
ETH1_DEV=$(echo "${IFACES[1]}" | cut -d: -f1)
ETH1_IP=$(echo "${IFACES[1]}" | cut -d: -f2)

ETH0_GW=$(ip route show dev $ETH0_DEV default 2>/dev/null | awk '{print $3}' | head -1)
ETH1_GW=$(ip route show dev $ETH1_DEV default 2>/dev/null | awk '{print $3}' | head -1)

echo ""
echo "  WAN1: $ETH0_DEV = $ETH0_IP (gw $ETH0_GW)"
echo "  WAN2: $ETH1_DEV = $ETH1_IP (gw $ETH1_GW)"
echo ""
read -p "Confermi queste interfacce? [Y/n] " confirm
if [[ "$confirm" =~ ^[Nn] ]]; then
    echo "Setup annullato."
    exit 0
fi

# --- 2. sysctl ---
echo ""
echo "[2/6] Configurazione sysctl..."
cp "$SCRIPT_DIR/sysctl-multiwan.conf" /etc/sysctl.d/90-multiwan.conf
sysctl -p /etc/sysctl.d/90-multiwan.conf
echo "  ip_forward=1, fib_multipath_hash_policy=1"

# --- 3. Configura ECMP + NAT ---
echo ""
echo "[3/6] Configurazione ECMP routing e NAT..."

# Policy routing
ip rule del from $ETH0_IP lookup 201 2>/dev/null || true
ip rule del from $ETH1_IP lookup 202 2>/dev/null || true
ip rule add from $ETH0_IP table 201 prio 100
ip rule add from $ETH1_IP table 202 prio 101
ip route flush table 201 2>/dev/null || true
ip route flush table 202 2>/dev/null || true
ip route add default via $ETH0_GW dev $ETH0_DEV table 201
ip route add default via $ETH1_GW dev $ETH1_DEV table 202
echo "  Policy routing tables 201/202 OK"

# ECMP default route
ip route del default 2>/dev/null || true
ip route add default \
    nexthop via $ETH0_GW dev $ETH0_DEV weight 1 \
    nexthop via $ETH1_GW dev $ETH1_DEV weight 1
echo "  ECMP default route OK"

# NAT masquerade
nft flush ruleset 2>/dev/null || true
nft add table ip nat
nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
nft add rule ip nat postrouting oifname "$ETH0_DEV" masquerade
nft add rule ip nat postrouting oifname "$ETH1_DEV" masquerade
nft add table ip mangle
nft add chain ip mangle FORWARD '{ type filter hook forward priority mangle; policy accept; }'
echo "  NAT masquerade OK"

# --- 4. Installa split proxy ---
echo ""
echo "[4/6] Installazione split proxy..."

# Aggiorna IFACES nel proxy con gli IP rilevati
cp "$SCRIPT_DIR/split_proxy.py" /usr/local/bin/split_proxy.py
sed -i "s|IFACES.*=.*\[.*\]|IFACES       = ['$ETH0_IP', '$ETH1_IP']   # $ETH0_DEV, $ETH1_DEV|" /usr/local/bin/split_proxy.py
chmod +x /usr/local/bin/split_proxy.py
echo "  split_proxy.py installato (IFACES = $ETH0_IP, $ETH1_IP)"

# --- 5. Installa glorytun (opzionale) ---
echo ""
echo "[5/6] Glorytun (opzionale)..."
if [ -f /usr/local/bin/glorytun-clean ]; then
    # Aggiorna startup script con interfacce rilevate
    cp "$SCRIPT_DIR/glorytun-client-start.sh" /usr/local/bin/glorytun-client-start.sh
    sed -i "s|ETH0_DEV=.*|ETH0_DEV=\"$ETH0_DEV\"|" /usr/local/bin/glorytun-client-start.sh
    sed -i "s|ETH1_DEV=.*|ETH1_DEV=\"$ETH1_DEV\"|" /usr/local/bin/glorytun-client-start.sh
    chmod +x /usr/local/bin/glorytun-client-start.sh

    cp "$SCRIPT_DIR/glorytun-client.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable glorytun-client.service
    echo "  Glorytun configurato (editare VPN_SERVER in glorytun-client-start.sh)"
else
    echo "  glorytun-clean non trovato, VPN non configurata (opzionale)"
    echo "  Per abilitare: compilare glorytun e posizionare in /usr/local/bin/glorytun-clean"
fi

# --- 6. Avvia servizi ---
echo ""
echo "[6/6] Avvio servizi..."
cp "$SCRIPT_DIR/split-proxy.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable split-proxy.service
systemctl restart split-proxy.service

if [ -f /usr/local/bin/glorytun-clean ] && [ -f /etc/glorytun/key ]; then
    systemctl restart glorytun-client.service
fi

echo ""
echo "=== Setup completato ==="
echo ""
echo "Stato:"
systemctl is-active split-proxy.service && echo "  split-proxy: ATTIVO" || echo "  split-proxy: NON ATTIVO"
ss -tlnp | grep 8080 && echo "  Proxy porta 8080: OK" || echo "  Proxy porta 8080: NON IN ASCOLTO"
echo ""
echo "IP della VM per il routing Windows:"
echo "  $ETH0_IP (via $ETH0_DEV)"
echo "  $ETH1_IP (via $ETH1_DEV)"
echo ""
echo "Su Windows (CMD admin):"
echo "  route add 0.0.0.0 mask 0.0.0.0 $ETH0_IP metric 5"
echo ""
echo "Test velocita':"
echo "  curl -x http://$ETH0_IP:8080 -o /dev/null -w '%{speed_download}' http://lon.download.datapacket.com/100mb.bin"
