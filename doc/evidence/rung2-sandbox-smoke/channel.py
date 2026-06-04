#!/usr/bin/env python3
"""Model a write channel between a (sandboxed) harness client and an
(unsandboxed) 'geex' server. The server performs the actual repo write; the
client only sends a request. Used to test whether such a channel survives an
OS sandbox that denies the client direct filesystem writes."""
import socket, sys, time, os

mode = sys.argv[1]


def server(family_addr, target):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(family_addr)
    s.listen(1)
    s.settimeout(15)  # don't hang forever if the client can't connect
    print("READY", flush=True)
    try:
        conn, _ = s.accept()
    except socket.timeout:
        print("SERVER_TIMEOUT_NO_CLIENT", flush=True)
        return
    data = conn.recv(4096).decode()
    # The privileged write — this process runs OUTSIDE the sandbox.
    with open(target, "w") as f:
        f.write(data)
    conn.sendall(b"WROTE")
    conn.close()


def client(family_addr, msg):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(100):  # retry to absorb server-startup race (no shell sleep)
        try:
            s.connect(family_addr)
            break
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.05)
    else:
        print("CLIENT_CONNECT_FAILED", flush=True)
        return
    s.sendall(msg.encode())
    print("CLIENT_REPLY:" + s.recv(4096).decode(), flush=True)


# Filesystem socket: a path on the (read-only-mounted) real filesystem.
if mode == "server-fs":
    server(sys.argv[2], sys.argv[3])
elif mode == "client-fs":
    client(sys.argv[2], sys.argv[3])
# Abstract socket: no filesystem presence; lives in the (shared) net namespace.
elif mode == "server-abstract":
    server("\0" + sys.argv[2], sys.argv[3])
elif mode == "client-abstract":
    client("\0" + sys.argv[2], sys.argv[3])
