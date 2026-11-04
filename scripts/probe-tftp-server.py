#!/usr/bin/env python3
"""Minimal TFTP read server used as a probe observatory.

Why: the stock hiboot has no video output and the Linux kernel we can build has
neither a display driver nor an Ethernet driver for this SoC. The only firmware
on the box that can talk on the network is hiboot itself, so a probe that makes
hiboot fetch a file over TFTP gives a result a human can SEE (a line in this
terminal / a file on disk) instead of guessing from a dark screen.

Run (port 69 needs root):

    sudo python3 scripts/probe-tftp-server.py --dir dist/probe-tftp

Every request is printed. Exit code is not meaningful; Ctrl-C stops it.

Protocol: TFTP RRQ, 512 byte blocks, octet mode - the oldest, dumbest subset,
which is all hiboot implements.
"""
import argparse
import os
import socket
import struct
import sys
import time

OP_RRQ, OP_WRQ, OP_DATA, OP_ACK, OP_ERROR = 1, 2, 3, 4, 5


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def send_error(sock, addr, code, msg):
    sock.sendto(struct.pack("!HH", OP_ERROR, code) + msg.encode() + b"\x00", addr)


def serve_file(sock, addr, path):
    with open(path, "rb") as fh:
        data = fh.read()
    blk = 1
    off = 0
    while True:
        chunk = data[off:off + 512]
        pkt = struct.pack("!HH", OP_DATA, blk) + chunk
        for attempt in range(5):
            sock.sendto(pkt, addr)
            try:
                resp, _ = sock.recvfrom(2048)
            except socket.timeout:
                continue
            if len(resp) >= 4 and struct.unpack("!H", resp[:2])[0] == OP_ACK \
                    and struct.unpack("!H", resp[2:4])[0] == blk:
                break
        else:
            log("    transfer aborted at block %d" % blk)
            return
        off += len(chunk)
        blk = (blk + 1) & 0xFFFF
        if len(chunk) < 512:
            log("    sent %d bytes in %d blocks" % (len(data), blk - 1))
            return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="dist/probe-tftp", help="directory served to the box")
    ap.add_argument("--port", type=int, default=69)
    ap.add_argument("--bind", default="0.0.0.0")
    args = ap.parse_args()

    root = os.path.abspath(args.dir)
    os.makedirs(root, exist_ok=True)
    probe = os.path.join(root, "probe.txt")
    if not os.path.exists(probe):
        with open(probe, "w") as fh:
            fh.write("EC6108V9C probe: hiboot reached the TFTP server.\n")
    log("serving %s on udp/%d" % (root, args.port))
    log("waiting for the box to fetch probe.txt ...")

    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, args.port))

    while True:
        pkt, addr = srv.recvfrom(2048)
        if len(pkt) < 4:
            continue
        op = struct.unpack("!H", pkt[:2])[0]
        if op == OP_RRQ:
            name = pkt[2:].split(b"\x00")[0].decode("utf-8", "replace")
            log("=" * 58)
            log("RRQ  '%s'  from %s:%d" % (name, addr[0], addr[1]))
            log("  -> the box's hiboot loaded and ran the U-disk env")
            safe = os.path.basename(name)
            path = os.path.join(root, safe)
            if not os.path.isfile(path):
                log("  file %s missing, answering error" % safe)
                send_error(srv, addr, 1, "not found")
                continue
            conn = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            conn.bind((args.bind, 0))
            conn.settimeout(2.0)
            try:
                serve_file(conn, addr, path)
            finally:
                conn.close()
        elif op == OP_WRQ:
            log("WRQ from %s:%d (ignored)" % (addr[0], addr[1]))
            send_error(srv, addr, 2, "read only")
        else:
            continue


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        sys.exit(0)
