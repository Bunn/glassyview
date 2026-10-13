#!/usr/bin/env python3
"""Minimal RFB 3.8 server that serves one still image (for marketing captures)."""
import socket, struct, sys, threading, time
from PIL import Image

image = Image.open(sys.argv[1]).convert("RGB")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 5901
W, H = image.size
R, G, B = image.split()
X = Image.new("L", image.size, 255)

def recvn(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk: raise ConnectionError
        data += chunk
    return data

def pixels(fmt):
    bpp, depth, big, true, rmax, gmax, bmax, rs, gs, bs = fmt
    order = [X, X, X, X]
    for channel, shift in ((R, rs), (G, gs), (B, bs)):
        index = shift // 8
        order[3 - index if big else index] = channel
    return Image.merge("RGBA", order).tobytes()

def serve(conn):
    try:
        conn.sendall(b"RFB 003.008\n"); recvn(conn, 12)
        conn.sendall(bytes([1, 1])); recvn(conn, 1)
        conn.sendall(struct.pack(">I", 0)); recvn(conn, 1)
        fmt = (32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        name = b"Studio Mac"
        conn.sendall(struct.pack(">HHBBBBHHHBBB3xI", W, H, *fmt, len(name)) + name)
        last = 0
        while True:
            kind = recvn(conn, 1)[0]
            if kind == 0:
                data = recvn(conn, 19); fmt = struct.unpack(">BBBBHHHBBB", data[3:16])
            elif kind == 2:
                count = struct.unpack(">xH", recvn(conn, 3))[0]; recvn(conn, 4 * count)
            elif kind == 3:
                incremental = recvn(conn, 9)[0]
                if incremental and time.time() - last < 1:
                    time.sleep(0.2)
                last = time.time()
                conn.sendall(struct.pack(">BxHHHHHi", 0, 1, 0, 0, W, H, 0) + pixels(fmt))
            elif kind == 4: recvn(conn, 7)
            elif kind == 5: recvn(conn, 5)
            elif kind == 6:
                length = struct.unpack(">3xI", recvn(conn, 7))[0]; recvn(conn, length)
            else:
                print("unknown message", kind, flush=True); return
    except Exception as error:
        print("closed", repr(error), flush=True)
    finally:
        conn.close()

server = socket.socket(); server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", PORT)); server.listen(5)
print("serving", W, H, "on", PORT, flush=True)
while True:
    conn, addr = server.accept(); print("client", addr, flush=True)
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
