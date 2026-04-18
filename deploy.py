#!/usr/bin/env python3
"""
deploy.py — Deploy completo MultiWAN Gateway in un comando.

Copia tutti i file necessari su VM e Server, abilita i servizi.

Prerequisiti:
  - glorytun-clean già compilato su VM in /usr/local/bin/glorytun-clean
  - Chiave tunnel già presente su VM e Server in /etc/glorytun/key
  - Python 3 + paramiko: pip install paramiko

Uso:
  python deploy.py          # deploy completo VM + Server
  python deploy.py vm       # solo VM
  python deploy.py server   # solo Server
  python deploy.py status   # verifica stato servizi
"""

import paramiko, sys, os, time

# ── Configurazione ────────────────────────────────────────────────────────────
VM_HOST     = '192.168.3.21'
VM_USER     = 'root'
VM_PASS     = 'Antonio123321@'

SERVER_HOST = '192.3.15.172'
SERVER_USER = 'root'
SERVER_KEY  = os.path.join(os.path.dirname(__file__),
                            '..', 'Test_Server', 'keys', 'id_rsa_servers')

HERE = os.path.dirname(os.path.abspath(__file__))
VM_DIR     = os.path.join(HERE, 'vm')
SERVER_DIR = os.path.join(HERE, 'server')


# ── Helpers ───────────────────────────────────────────────────────────────────

def connect_vm():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(VM_HOST, username=VM_USER, password=VM_PASS,
              look_for_keys=False, allow_agent=False, timeout=10)
    return c

def connect_server():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(SERVER_HOST, username=SERVER_USER,
              key_filename=SERVER_KEY, timeout=10)
    return c

def run(conn, cmd, timeout=30, label=''):
    _, out, err = conn.exec_command(cmd, timeout=timeout)
    o = out.read().decode('utf-8', 'replace').strip()
    e = err.read().decode('utf-8', 'replace').strip()
    prefix = f'[{label}] ' if label else ''
    if o:
        print(f'{prefix}{o}'.encode('ascii', 'replace').decode('ascii'))
    if e and 'warning' not in e.lower():
        print(f'{prefix}ERR: {e}'.encode('ascii', 'replace').decode('ascii'))
    return o

def put(sftp, local, remote, mode=0o644):
    sftp.put(local, remote)
    sftp.chmod(remote, mode)
    print(f'  -> {remote}')


# ── Deploy VM ─────────────────────────────────────────────────────────────────

def deploy_vm():
    print('\n=== Deploy VM ({}) ==='.format(VM_HOST))
    c = connect_vm()
    sftp = c.open_sftp()

    # Script di avvio
    put(sftp,
        os.path.join(VM_DIR, 'glorytun-client-start.sh'),
        '/usr/local/bin/glorytun-client-start.sh',
        0o755)

    # Split proxy
    put(sftp,
        os.path.join(VM_DIR, 'split_proxy.py'),
        '/usr/local/bin/split_proxy.py',
        0o755)

    # Systemd units
    put(sftp,
        os.path.join(VM_DIR, 'glorytun-client.service'),
        '/etc/systemd/system/glorytun-client.service')
    put(sftp,
        os.path.join(VM_DIR, 'split-proxy.service'),
        '/etc/systemd/system/split-proxy.service')

    # Sysctl
    put(sftp,
        os.path.join(VM_DIR, 'sysctl-99-gateway.conf'),
        '/etc/sysctl.d/99-gateway.conf')

    sftp.close()

    print('\nAbilitazione servizi...')
    run(c, 'sysctl -p /etc/sysctl.d/99-gateway.conf 2>&1 | tail -3', label='sysctl')
    run(c, 'systemctl daemon-reload', label='daemon-reload')
    run(c, 'systemctl enable glorytun-client split-proxy', label='enable')

    print('\nAvvio servizi...')
    run(c, 'systemctl restart glorytun-client', label='glorytun restart')
    time.sleep(15)
    run(c, 'systemctl restart split-proxy', label='split-proxy restart')
    time.sleep(2)

    print('\nStato servizi:')
    run(c, 'systemctl is-active glorytun-client split-proxy', label='active')
    run(c, 'ss -tlnp | grep 8080', label='proxy port')
    run(c, 'ip route show default', label='route')
    run(c, 'glorytun path dev tun0 2>&1', label='paths')

    c.close()
    print('\nVM deploy completato.')


# ── Deploy Server ─────────────────────────────────────────────────────────────

def deploy_server():
    print('\n=== Deploy Server ({}) ==='.format(SERVER_HOST))
    c = connect_server()
    sftp = c.open_sftp()

    put(sftp,
        os.path.join(SERVER_DIR, 'glorytun-server.service'),
        '/etc/systemd/system/glorytun-server.service')

    sftp.close()

    print('\nAvvio servizio...')
    run(c, 'systemctl daemon-reload', label='daemon-reload')
    run(c, 'systemctl enable glorytun-server', label='enable')
    run(c, 'pkill glorytun 2>/dev/null; ip link del tun0 2>/dev/null; sleep 1; true',
        label='cleanup')
    run(c, 'systemctl start glorytun-server && echo "OK" || echo "FAIL"',
        label='start')
    time.sleep(3)
    run(c, 'systemctl status glorytun-server --no-pager | head -6', label='status')
    run(c, 'ip -4 addr show tun0 2>&1', label='tun0')

    c.close()
    print('\nServer deploy completato.')


# ── Status ────────────────────────────────────────────────────────────────────

def status():
    print('\n=== Status VM ({}) ==='.format(VM_HOST))
    c = connect_vm()
    run(c, 'systemctl is-active glorytun-client split-proxy', label='services')
    run(c, 'ip route show default', label='route')
    run(c, 'glorytun path dev tun0 2>&1', label='tunnel paths')
    run(c, 'ss -tlnp | grep 8080', label='proxy')
    run(c, 'ping -c 3 -W 2 10.255.255.1 2>&1 | tail -2', label='tunnel ping', timeout=15)
    c.close()

    print('\n=== Status Server ({}) ==='.format(SERVER_HOST))
    s = connect_server()
    run(s, 'systemctl is-active glorytun-server', label='service')
    run(s, 'ip -4 addr show tun0 2>&1', label='tun0')
    run(s, 'glorytun path dev tun0 2>&1', label='paths')
    s.close()


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'all'

    if cmd in ('all', 'vm'):
        deploy_vm()
    if cmd in ('all', 'server'):
        deploy_server()
    if cmd == 'status':
        status()

    if cmd == 'all':
        print('\n' + '='*60)
        print('Deploy completo. Prossimi passi su Windows (CMD admin):')
        print('  1. route change 0.0.0.0 mask 0.0.0.0 192.168.2.21 metric 5')
        print('  2. powershell -File windows\\set_proxy.ps1')
        print('  3. curl -x http://192.168.2.21:8080 -o NUL -w "%{speed_download}" http://speedtest.tele2.net/100MB.zip')
        print('='*60)

if __name__ == '__main__':
    main()
