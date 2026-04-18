#!/bin/bash
# glorytun-client-start.sh — ECMP multi-WAN startup script
# Configures policy routing, NAT, and launches glorytun MUD client.
#
# CUSTOMIZE: Update IPs and interface names for your environment.

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
log() { echo "$(date '+%H:%M:%S') $*"; }
log "=== glorytun-client startup (ECMP mode) ==="

# ============================================================================
# CONFIGURATION — Edit these for your setup
# ============================================================================
ETH0_DEV="eth0"                  # WAN 1 interface (e.g. fiber)
ETH1_DEV="eth1"                  # WAN 2 interface (e.g. 5G/LTE)
VPN_SERVER="192.3.15.172"        # Glorytun server public IP
VPN_PORT=65001                   # Glorytun server port
VPN_KEY_FILE="/etc/glorytun/key" # Shared key file
TUN_LOCAL_IP="10.255.255.2"      # Local tunnel IP
TUN_REMOTE_IP="10.255.255.1"     # Remote tunnel IP
GT_BINARY="/usr/local/bin/glorytun-clean"  # Glorytun binary
RATE="12500000"                  # Rate limit (bytes/s) for MUD bootstrap
# ============================================================================

# Auto-detect IPs and gateways
ETH0_IP=$(ip -4 addr show $ETH0_DEV | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
ETH0_GW=$(ip route show dev $ETH0_DEV | awk '/default/{print $3}' | head -1)
if [ -z "$ETH0_GW" ]; then
    ETH0_GW=$(ip route show dev $ETH0_DEV | awk '/proto dhcp/{print $1}' | head -1)
    [ "$ETH0_GW" = "default" ] && ETH0_GW=$(ip route show dev $ETH0_DEV default | awk '{print $3}')
fi

ETH1_IP=$(ip -4 addr show $ETH1_DEV | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
ETH1_GW=$(ip route show dev $ETH1_DEV | awk '/default/{print $3}' | head -1)
if [ -z "$ETH1_GW" ]; then
    ETH1_GW=$(ip route show dev $ETH1_DEV | awk '/proto dhcp/{print $1}' | head -1)
    [ "$ETH1_GW" = "default" ] && ETH1_GW=$(ip route show dev $ETH1_DEV default | awk '{print $3}')
fi

log "eth0: $ETH0_IP gw=$ETH0_GW | eth1: $ETH1_IP gw=$ETH1_GW"

# 1. Policy routing for glorytun paths (numeric tables, no rt_tables file needed)
ip rule del from $ETH0_IP lookup 201 2>/dev/null
ip rule del from $ETH1_IP lookup 202 2>/dev/null
ip rule add from $ETH0_IP table 201 prio 100
ip rule add from $ETH1_IP table 202 prio 101
ip route flush table 201 2>/dev/null
ip route flush table 202 2>/dev/null
ip route add default via $ETH0_GW dev $ETH0_DEV table 201
ip route add default via $ETH1_GW dev $ETH1_DEV table 202
log "Policy routing tables 201/202 configured"

# 2. Enable forwarding + L4 hash
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.fib_multipath_hash_policy=1

# 3. NAT masquerade via nftables
nft flush ruleset 2>/dev/null
nft add table ip nat
nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
nft add rule ip nat postrouting oifname "$ETH0_DEV" masquerade
nft add rule ip nat postrouting oifname "$ETH1_DEV" masquerade
nft add rule ip nat postrouting oifname "tun0" masquerade
nft add table ip mangle
nft add chain ip mangle FORWARD '{ type filter hook forward priority mangle; policy accept; }'
log "NAT masquerade on $ETH0_DEV, $ETH1_DEV, tun0"

# 4. Launch glorytun MUD client
log "Starting glorytun -> $VPN_SERVER:$VPN_PORT"
$GT_BINARY mud \
    keyfile $VPN_KEY_FILE \
    bind 0.0.0.0 \
    peer $VPN_SERVER port $VPN_PORT \
    dev tun0 \
    mtu auto \
    timeout 60 &

sleep 2

# 5. Configure tun0
ip addr replace $TUN_LOCAL_IP/30 dev tun0
ip link set tun0 up
log "tun0 up: $TUN_LOCAL_IP/30"

sleep 1

# 6. Register paths (one per WAN interface)
glorytun path dev tun0 add addr $ETH0_IP port 0 to $VPN_SERVER port $VPN_PORT \
    rate fixed tx $RATE rx $RATE 2>/dev/null && log "Path $ETH0_DEV registered"
glorytun path dev tun0 add addr $ETH1_IP port 0 to $VPN_SERVER port $VPN_PORT \
    rate fixed tx $RATE rx $RATE 2>/dev/null && log "Path $ETH1_DEV registered"

# 7. ECMP default route (equal-cost multi-path)
ip route del default 2>/dev/null
ip route add default \
    nexthop via $ETH0_GW dev $ETH0_DEV weight 1 \
    nexthop via $ETH1_GW dev $ETH1_DEV weight 1
log "ECMP default route set (WAN1 + WAN2, weight 1:1)"

log "=== Startup complete ==="
wait
