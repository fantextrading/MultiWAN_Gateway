#!/bin/bash
# setup.sh — Deploy Multi-WAN Gateway on a fresh Debian 12/13 VM
# Run as root on the VM that has two WAN interfaces.
#
# Prerequisites:
#   - Debian 12+ with two network interfaces (e.g. eth0=fiber, eth1=5G)
#   - glorytun binary compiled and placed at /usr/local/bin/glorytun-clean
#   - Glorytun key generated: glorytun keygen -o /etc/glorytun/key
#
# Usage: bash setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Multi-WAN Gateway Setup ==="

# 1. sysctl
echo "[1/5] Configuring sysctl..."
cp "$SCRIPT_DIR/sysctl-multiwan.conf" /etc/sysctl.d/90-multiwan.conf
sysctl -p /etc/sysctl.d/90-multiwan.conf

# 2. Glorytun key directory
echo "[2/5] Setting up glorytun..."
mkdir -p /etc/glorytun
if [ ! -f /etc/glorytun/key ]; then
    echo "  WARNING: /etc/glorytun/key not found."
    echo "  Generate with: glorytun keygen -o /etc/glorytun/key"
    echo "  Copy the same key to the VPN server."
fi

# 3. Install scripts
echo "[3/5] Installing scripts..."
cp "$SCRIPT_DIR/split_proxy.py" /usr/local/bin/split_proxy.py
cp "$SCRIPT_DIR/glorytun-client-start.sh" /usr/local/bin/glorytun-client-start.sh
chmod +x /usr/local/bin/split_proxy.py
chmod +x /usr/local/bin/glorytun-client-start.sh

# 4. Install systemd services
echo "[4/5] Installing systemd services..."
cp "$SCRIPT_DIR/split-proxy.service" /etc/systemd/system/
cp "$SCRIPT_DIR/glorytun-client.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable split-proxy.service
systemctl enable glorytun-client.service

# 5. Start services
echo "[5/5] Starting services..."
systemctl start glorytun-client.service
sleep 3
systemctl start split-proxy.service

echo ""
echo "=== Setup complete ==="
echo ""
echo "Check status:"
echo "  systemctl status glorytun-client"
echo "  systemctl status split-proxy"
echo "  ss -tlnp | grep 8080"
echo ""
echo "IMPORTANT: Edit /usr/local/bin/glorytun-client-start.sh to set your:"
echo "  - Interface names (ETH0_DEV, ETH1_DEV)"
echo "  - VPN server IP (VPN_SERVER)"
echo "  - Tunnel IPs (TUN_LOCAL_IP, TUN_REMOTE_IP)"
echo ""
echo "IMPORTANT: Edit /usr/local/bin/split_proxy.py to set your:"
echo "  - IFACES list (your two WAN interface IPs)"
