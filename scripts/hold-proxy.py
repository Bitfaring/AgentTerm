#!/usr/bin/python3
"""Stands between the iPhone app and the host in scripts/test-both.sh (#198).

    hold-proxy.py <listen port> <host port> <control folder>

Passes everything through both ways, until the test, which cannot reach
the host's connection itself, says otherwise with files in the control
folder:

- `hold`: what the host sends is held, not passed on, while what the
  phone sends still goes through. Once something of the phone's went
  through while holding, `asked` is written.
- `close`: every connection is closed, and one that comes is closed at
  once, for as long as the file is there.

With neither, what was held is let go in order.
"""
import os
import select
import socket
import sys

LISTEN, TARGET, CONTROL = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]


def control(name):
    return os.path.exists(os.path.join(CONTROL, name))


server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", LISTEN))
server.listen(8)
# Each pair: the phone's socket, the host's, and what the host sent that is held.
pairs = []

while True:
    closing = control("close")
    if closing and pairs:
        for phone, host, _ in pairs:
            phone.close()
            host.close()
        pairs = []
    holding = control("hold")
    if not holding:
        for pair in pairs:
            if pair[2]:
                pair[0].sendall(pair[2])
                pair[2] = b""
    sockets = [server] + [s for phone, host, _ in pairs for s in (phone, host)]
    readable, _, _ = select.select(sockets, [], [], 0.1)
    for ready in readable:
        if ready is server:
            phone, _ = server.accept()
            if closing:
                phone.close()
                continue
            host = socket.create_connection(("127.0.0.1", TARGET))
            pairs.append([phone, host, b""])
            continue
        for pair in pairs:
            phone, host, _ = pair
            if ready is not phone and ready is not host:
                continue
            try:
                data = ready.recv(65536)
            except OSError:
                data = b""
            if not data:
                phone.close()
                host.close()
                pairs.remove(pair)
            elif ready is phone:
                host.sendall(data)
                if holding:
                    open(os.path.join(CONTROL, "asked"), "w").close()
            elif holding:
                pair[2] += data
            else:
                phone.sendall(data)
            break
