#!/usr/bin/env python3
"""Tiny DNS responder for *.dev.local → gateway IP.

Binds privileged port 53, run with sudo. Prints "OK" on stdout when ready.
Arguments: <bind_ip> <port> <domain> <answer_ip>
"""
import socket, struct, sys

bind_ip = sys.argv[1]
port = int(sys.argv[2])
domain = sys.argv[3].lower()
answer_ip = sys.argv[4]

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((bind_ip, port))
print("OK", flush=True)

ip_bytes = bytes(int(x) for x in answer_ip.split("."))

while True:
    data, addr = s.recvfrom(512)
    if len(data) < 12:
        continue

    tid = data[:2]

    # Parse question
    i = 12
    labels = []
    while i < len(data) and data[i] != 0:
        n = data[i]
        labels.append(data[i + 1 : i + 1 + n].decode())
        i += 1 + n
    i += 1  # skip null terminator
    qname = ".".join(labels).lower()

    # Check if it matches our domain
    if not (qname == domain or qname.endswith("." + domain)):
        # NXDOMAIN
        resp = tid + b"\x84\x03" + b"\x00" * 8
        s.sendto(resp, addr)
        continue

    # Build A record response
    qsection = data[12 : i + 4]  # question section including qtype+qclass
    ans = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + ip_bytes
    resp = tid + b"\x84\x00\x00\x01\x00\x01\x00\x00\x00\x00" + qsection + ans
    s.sendto(resp, addr)
