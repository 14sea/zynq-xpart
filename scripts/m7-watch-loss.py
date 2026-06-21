#!/usr/bin/env python3
"""m7-watch-loss.py — watch the on-board XOR training loss curve (M7.0b).

The NEORV32 trainer publishes its loss curve through the PS-visible mailbox at
AXI 0x41200000 (NEORV32 uart0 is not pinned out on this board, so the mailbox is
the only channel). This script polls that word over the U-Boot console (`md`)
and decodes the protocol from sw/m7_train/main.c:

  bit31=0 -> TRAINING checkpoint: bits[30:24]=index, [23:0]=SSE  (held ~2 s each)
  bit31=1 -> DONE: 0x80000000 | (XOR_score<<16) | (final_SSE & 0xFFFF)

Run it right after `fpga loadb` of the M7 static while the board trains.
"""
import argparse
import re
import sys
import time

import serial

ADDR = 0x41200000
LINE = re.compile(rb'%08x:\s*([0-9a-fA-F]{8})' % ADDR)


def read_mbox(ser):
    ser.reset_input_buffer()
    ser.write(b'md 0x%08x 1\r' % ADDR)
    deadline = time.time() + 0.4
    buf = b''
    while time.time() < deadline:
        buf += ser.read(256)
        m = LINE.search(buf)
        if m:
            return int(m.group(1), 16)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='/dev/ebaz-uart')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--timeout', type=float, default=180.0)
    ap.add_argument('--interval', type=float, default=0.3)
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.2)
    print(f"[watch] polling mailbox 0x{ADDR:08x} via U-Boot md (timeout {args.timeout:.0f}s)")
    seen = {}
    deadline = time.time() + args.timeout
    last = None
    while time.time() < deadline:
        v = read_mbox(ser)
        if v is None or v == last:
            time.sleep(args.interval)
            continue
        last = v
        if v & 0x80000000:
            ok = (v >> 16) & 0xFF
            sse = v & 0xFFFF
            print(f"[watch] DONE: XOR {ok}/4, final SSE={sse}  (mbox=0x{v:08x})")
            return 0 if (ok == 4) else 1
        idx = (v >> 24) & 0x7F
        sse = v & 0xFFFFFF
        if idx not in seen:
            seen[idx] = sse
            print(f"[watch] ckpt {idx:2d}  epoch~{idx*200:4d}  SSE={sse}")
        time.sleep(args.interval)
    print("[watch] TIMEOUT — no DONE marker seen", file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
