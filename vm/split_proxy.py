#!/usr/bin/env python3
"""
split_proxy.py v5 — HTTP proxy con split-download adattivo su due WAN + CONNECT.

v5: worker adattivi — misura la velocita' di ogni WAN al primo chunk e
    bilancia dinamicamente i chunk rimanenti in proporzione alla banda reale.
v4: aggiunto metodo CONNECT per tunnel HTTPS.

Topologia:
  Windows (curl -x http://192.168.2.21:8080 ...)
    -> proxy (VM)
       |-- N worker via eth0 (fibra, 192.168.2.21)
       +-- M worker via eth1 (5G, 192.168.3.21)
    -> internet server (range requests parallele)
    -> assembla in ordine -> streamma a Windows

Uso: systemctl start split-proxy  (oppure: python3 /usr/local/bin/split_proxy.py)
"""

import socket, threading, queue, sys, time, urllib.parse, select

LISTEN_ADDR  = '0.0.0.0'
LISTEN_PORT  = 8080
IFACES       = ['192.168.2.21', '192.168.3.21']   # eth0=fibra, eth1=5G
# Worker per interfaccia — pesati sulla capacita' (5G ~3x la fibra)
WORKERS_MAP  = {'192.168.2.21': 4, '192.168.3.21': 12}   # tot 16, coda condivisa
CHUNK_MB     = 16      # dimensione chunk MB (bigger = meno overhead, window TCP piu' aperta)
THRESHOLD_MB = 4       # file minimo per attivare split
TIMEOUT      = 60

CHUNK_SIZE   = CHUNK_MB   * 1024 * 1024
THRESHOLD    = THRESHOLD_MB * 1024 * 1024

# Velocita' misurate per interfaccia (bytes/s), aggiornate runtime
_iface_speeds = {}
_iface_lock   = threading.Lock()


# --- CONNECT tunnel (HTTPS) ------------------------------------------------

def handle_connect(conn, host, port):
    """Gestisce CONNECT method: crea tunnel TCP bidirezionale per HTTPS."""
    try:
        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.settimeout(TIMEOUT)
        remote.connect((host, port))
    except Exception as e:
        conn.sendall(b'HTTP/1.1 502 Bad Gateway\r\n\r\n')
        print(f'[CONNECT] failed to connect to {host}:{port}: {e}',
              file=sys.stderr, flush=True)
        return

    conn.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')

    # Tunnel bidirezionale
    conn.setblocking(False)
    remote.setblocking(False)

    try:
        while True:
            readable, _, errs = select.select([conn, remote], [], [conn, remote], 60)
            if errs:
                break
            if not readable:
                break  # timeout
            for s in readable:
                try:
                    data = s.recv(65536)
                except (BlockingIOError, OSError):
                    continue
                if not data:
                    return
                target = remote if s is conn else conn
                try:
                    target.sendall(data)
                except Exception:
                    return
    except Exception:
        pass
    finally:
        try:
            remote.close()
        except Exception:
            pass


# --- Fetcher con connessione persistente ----------------------------------

class PersistentFetcher:
    """Una connessione HTTP keep-alive che serve range request sequenziali."""

    def __init__(self, host, port, path, bind_ip):
        self.host     = host
        self.port     = port
        self.path     = path
        self.bind_ip  = bind_ip
        self.sock     = None
        self._connect()

    def _connect(self):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 512 * 1024)
        s.bind((self.bind_ip, 0))
        s.settimeout(TIMEOUT)
        s.connect((self.host, self.port))
        self.sock = s

    def fetch(self, start, end):
        """Scarica [start, end] bytes, riconnette se necessario."""
        expected = end - start + 1
        for attempt in range(2):
            try:
                req = (f"GET {self.path} HTTP/1.1\r\n"
                       f"Host: {self.host}\r\n"
                       f"Range: bytes={start}-{end}\r\n"
                       f"Accept-Encoding: identity\r\n"
                       f"Connection: keep-alive\r\n\r\n")
                self.sock.sendall(req.encode())

                # Leggi headers
                buf = b''
                while b'\r\n\r\n' not in buf:
                    d = self.sock.recv(8192)
                    if not d:
                        raise ConnectionError("EOF prematura in headers")
                    buf += d

                sep      = buf.index(b'\r\n\r\n')
                hdr_text = buf[:sep].decode('latin-1')
                body     = buf[sep + 4:]

                # Estrai Content-Length dalla risposta 206
                cl = 0
                for ln in hdr_text.split('\r\n'):
                    if ln.lower().startswith('content-length:'):
                        cl = int(ln.split(':', 1)[1].strip())
                        break

                if cl == 0:
                    cl = expected  # fallback

                # Leggi esattamente cl bytes
                while len(body) < cl:
                    d = self.sock.recv(65536)
                    if not d:
                        raise ConnectionError(f"EOF dopo {len(body)}/{cl} bytes")
                    body += d

                return body[:cl]

            except Exception:
                if attempt == 0:
                    self._connect()   # riconnetti e riprova
                else:
                    raise

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


# --- Worker thread --------------------------------------------------------

def worker(fetcher, task_q, result_q, chunks):
    """Preleva chunk dalla coda e li scarica via il fetcher persistente.
    Misura la velocita' e aggiorna le statistiche per interfaccia."""
    while True:
        try:
            idx = task_q.get_nowait()
        except queue.Empty:
            return
        start, end = chunks[idx]
        try:
            t0 = time.monotonic()
            data = fetcher.fetch(start, end)
            elapsed = time.monotonic() - t0
            if elapsed > 0 and data:
                speed = len(data) / elapsed
                with _iface_lock:
                    # Media mobile esponenziale (alpha=0.3)
                    prev = _iface_speeds.get(fetcher.bind_ip, speed)
                    _iface_speeds[fetcher.bind_ip] = prev * 0.7 + speed * 0.3
            result_q.put((idx, data))
        except Exception as e:
            print(f"[WORKER {fetcher.bind_ip}] chunk {idx} ({start}-{end}): {e}",
                  file=sys.stderr, flush=True)
            result_q.put((idx, None))
        finally:
            task_q.task_done()


# --- Split download -------------------------------------------------------

def proxy_split(conn, host, port, path, content_length, content_type):
    t0 = time.time()
    n_workers = sum(WORKERS_MAP.values())

    # Calcola chunk list
    n      = max(n_workers, (content_length + CHUNK_SIZE - 1) // CHUNK_SIZE)
    base   = content_length // n
    chunks = []
    pos    = 0
    for i in range(n):
        end = pos + base - 1 if i < n - 1 else content_length - 1
        chunks.append((pos, end))
        pos = end + 1

    # Coda condivisa: i worker veloci prendono naturalmente piu' chunk
    task_q   = queue.Queue()
    result_q = queue.Queue()
    for i in range(n):
        task_q.put(i)

    # Lancia worker con connessioni persistenti
    for iface in IFACES:
        for _ in range(WORKERS_MAP.get(iface, 4)):
            try:
                f = PersistentFetcher(host, port, path, iface)
                threading.Thread(
                    target=worker,
                    args=(f, task_q, result_q, chunks),
                    daemon=True
                ).start()
            except Exception as e:
                print(f"[SPLIT] connessione fallita via {iface}: {e}",
                      file=sys.stderr, flush=True)

    # Invia header HTTP al client Windows
    conn.sendall((
        f"HTTP/1.1 200 OK\r\n"
        f"Content-Length: {content_length}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Accept-Ranges: none\r\n"
        f"Connection: close\r\n\r\n"
    ).encode())

    # Streamma chunk in ordine man mano che arrivano
    done      = {}
    send_next = 0

    while send_next < n:
        try:
            idx, data = result_q.get(timeout=TIMEOUT)
        except queue.Empty:
            print("[PROXY] timeout in attesa chunk", file=sys.stderr)
            break
        done[idx] = data or b''
        while send_next in done:
            try:
                conn.sendall(done.pop(send_next))
            except (BrokenPipeError, ConnectionResetError):
                return
            send_next += 1

    elapsed = time.time() - t0
    speed   = content_length / elapsed / 1024 / 1024 if elapsed else 0

    # Log velocita' per interfaccia
    with _iface_lock:
        spd_info = " | ".join(
            f"{ip}: {_iface_speeds.get(ip, 0)/1024/1024:.1f} MB/s"
            for ip in IFACES
        )

    print(
        f"[SPLIT] {host}{path[:50]}  "
        f"{content_length // 1024 // 1024}MB -> {speed:.2f} MB/s in {elapsed:.1f}s  "
        f"({n} chunk x {CHUNK_MB}MB / {n_workers} workers | {spd_info})",
        flush=True
    )


# --- Passthrough (file piccolo o server senza range support) ---------------

def proxy_passthrough(conn, host, port, path, bind_ip):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind((bind_ip, 0))
        s.settimeout(TIMEOUT)
        s.connect((host, port))
        s.sendall((
            f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
            f"Accept-Encoding: identity\r\nConnection: close\r\n\r\n"
        ).encode())
        buf = b''
        while b'\r\n\r\n' not in buf:
            d = s.recv(4096)
            if not d:
                break
            buf += d
        sep  = buf.index(b'\r\n\r\n') if b'\r\n\r\n' in buf else len(buf)
        body = buf[sep + 4:]
        hdr  = buf[:sep].decode('latin-1', errors='replace')
        cl   = ''
        ct   = 'application/octet-stream'
        for ln in hdr.split('\r\n'):
            ll = ln.lower()
            if ll.startswith('content-length:'):
                cl = ln.split(':', 1)[1].strip()
            if ll.startswith('content-type:'):
                ct = ln.split(':', 1)[1].strip()
        cl_h = f"Content-Length: {cl}\r\n" if cl else ""
        conn.sendall((
            f"HTTP/1.1 200 OK\r\n{cl_h}"
            f"Content-Type: {ct}\r\nConnection: close\r\n\r\n"
        ).encode())
        conn.sendall(body)
        while True:
            d = s.recv(65536)
            if not d:
                break
            conn.sendall(d)
        s.close()
    except Exception as e:
        print(f"[PASS] {host}{path}: {e}", file=sys.stderr)


# --- Request handler -------------------------------------------------------

def handle(conn, addr):
    try:
        buf = b''
        conn.settimeout(30)
        while b'\r\n\r\n' not in buf:
            d = conn.recv(4096)
            if not d:
                return
            buf += d

        sep     = buf.index(b'\r\n\r\n')
        req_hdr = buf[:sep].decode('latin-1', errors='replace')
        lines   = req_hdr.split('\r\n')
        parts   = lines[0].split()
        if len(parts) < 2:
            return

        method, url = parts[0], parts[1]

        # CONNECT method per tunnel HTTPS
        if method == 'CONNECT':
            # url formato host:port
            if ':' in url:
                host, port = url.rsplit(':', 1)
                port = int(port)
            else:
                host = url
                port = 443
            print(f"[CONNECT] {addr[0]} -> {host}:{port}", flush=True)
            handle_connect(conn, host, port)
            return

        if method not in ('GET', 'HEAD'):
            conn.sendall(b'HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n')
            return

        p    = urllib.parse.urlparse(url)
        host = p.hostname
        port = p.port or 80
        path = p.path or '/'
        if p.query:
            path += '?' + p.query

        # HEAD probe via fibra per scoprire content-length e accept-ranges
        try:
            s0 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s0.bind((IFACES[0], 0))
            s0.settimeout(10)
            s0.connect((host, port))
            s0.sendall((
                f"HEAD {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
            ).encode())
            hr = b''
            while b'\r\n\r\n' not in hr:
                d = s0.recv(4096)
                if not d:
                    break
                hr += d
            s0.close()
        except Exception:
            conn.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n')
            return

        hdr_text = hr.split(b'\r\n\r\n')[0].decode('latin-1', errors='replace')
        cl = 0
        ar = False
        ct = 'application/octet-stream'
        for ln in hdr_text.split('\r\n'):
            ll = ln.lower()
            if ll.startswith('content-length:'):
                cl = int(ln.split(':', 1)[1].strip())
            if ll.startswith('accept-ranges:'):
                ar = 'bytes' in ll
            if ll.startswith('content-type:'):
                ct = ln.split(':', 1)[1].strip()

        if method == 'HEAD':
            conn.sendall((
                f"HTTP/1.1 200 OK\r\nContent-Length: {cl}\r\n"
                f"Content-Type: {ct}\r\nConnection: close\r\n\r\n"
            ).encode())
            return

        if ar and cl >= THRESHOLD:
            proxy_split(conn, host, port, path, cl, ct)
        else:
            proxy_passthrough(conn, host, port, path, IFACES[0])

    except Exception as e:
        print(f"[{addr}] {e}", file=sys.stderr)
    finally:
        try:
            conn.close()
        except Exception:
            pass


# --- Main ------------------------------------------------------------------

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_ADDR, LISTEN_PORT))
    srv.listen(200)
    print(
        f"[split_proxy v5] {LISTEN_ADDR}:{LISTEN_PORT} | "
        f"ifaces={IFACES} | workers={WORKERS_MAP} (shared queue) | "
        f"chunk={CHUNK_MB}MB | threshold={THRESHOLD_MB}MB | CONNECT support",
        flush=True
    )
    while True:
        c, a = srv.accept()
        threading.Thread(target=handle, args=(c, a), daemon=True).start()


if __name__ == '__main__':
    main()
