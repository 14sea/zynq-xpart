#!/usr/bin/env python3
"""m7-watch-mnist.py — watch the on-board MNIST-tile training curve (M7.4).

The NEORV32 trainer (sw/m7_train/main_mnist.c) publishes its per-epoch progress
through the PS-visible mailbox at AXI 0x41200000 (NEORV32 uart0 is not pinned out
on this board, so the mailbox is the only channel). This polls that word over the
U-Boot console (`md`) and decodes:

  bit31=0 -> checkpoint: [30:24]=epoch  [23:16]=test_correct(0..NTEST)  [15:0]=SSE&0xFFFF
  bit31=1 -> DONE:       [30:24]=peak_correct  [23:16]=final_correct     [15:0]=final SSE

With --golden <m7_mnist_vectors.h> it also compares each live (SSE, accuracy) to the
numpy-oracle golden parsed from the header, for an on-board bit-exact verdict. Run it
right after `fpga loadb` of the M7.4 static while the board trains.
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


def parse_golden(path):
    """Pull NTEST + the golden LOSS[] and ACC1000[] arrays out of the C header."""
    txt = open(path).read()
    def arr(name):
        m = re.search(name + r'\s*\[\d+\]\s*=\s*\{([^}]*)\}', txt, re.S)
        return [int(x) for x in re.findall(r'-?\d+', m.group(1))] if m else None
    ntest = int(re.search(r'#define\s+M7M_NTEST\s+(\d+)', txt).group(1))
    loss = arr('M7M_GOLD_LOSS')
    acc1000 = arr('M7M_GOLD_ACC1000')
    return ntest, loss, acc1000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='/dev/ebaz-uart')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--timeout', type=float, default=600.0)
    ap.add_argument('--interval', type=float, default=0.25)
    ap.add_argument('--golden', help='m7_mnist_vectors.h to compare against (bit-exact check)')
    args = ap.parse_args()

    ntest, gloss, gacc = (None, None, None)
    if args.golden:
        ntest, gloss, gacc = parse_golden(args.golden)
        print(f"[watch] golden loaded: NTEST={ntest}, {len(gloss)} epochs")

    ser = serial.Serial(args.port, args.baud, timeout=0.2)
    print(f"[watch] polling mailbox 0x{ADDR:08x} via U-Boot md (timeout {args.timeout:.0f}s)")
    seen = {}
    sse_mism = acc_mism = 0
    deadline = time.time() + args.timeout
    last = None
    while time.time() < deadline:
        v = read_mbox(ser)
        if v is None or v == last:
            time.sleep(args.interval)
            continue
        last = v
        if v & 0x80000000:
            peak = (v >> 24) & 0x7F
            fin = (v >> 16) & 0xFF
            sse = v & 0xFFFF
            denom = ntest if ntest else 32
            print(f"[watch] DONE: peak {peak}/{denom} ({100*peak/denom:.1f}%), "
                  f"final {fin}/{denom} ({100*fin/denom:.1f}%), final SSE={sse}  (mbox=0x{v:08x})")
            if args.golden:
                print(f"[watch] bit-exact vs oracle: SSE mism={sse_mism}, acc mism={acc_mism} "
                      f"(over {len(seen)} sampled epochs) -> "
                      f"{'PASS' if (sse_mism == 0 and acc_mism == 0) else 'CHECK'}")
            return 0
        epoch = (v >> 24) & 0x7F
        cor = (v >> 16) & 0xFF
        sse = v & 0xFFFF
        if epoch not in seen:
            seen[epoch] = (cor, sse)
            denom = ntest if ntest else 32
            tag = ""
            if args.golden and epoch < len(gloss):
                gs = gloss[epoch] & 0xFFFF
                ga = int(round(gacc[epoch] / 1000 * denom))   # golden ok-count
                ds = "" if gs == sse else f" !=golden_sse({gs})"
                da = "" if ga == cor else f" !=golden_ok({ga})"
                if gs != sse: sse_mism += 1
                if ga != cor: acc_mism += 1
                tag = f"  [oracle SSE={gs} ok={ga}]{ds}{da}"
            print(f"[watch] ep {epoch:2d}  acc {cor}/{denom} ({100*cor/denom:4.1f}%)  SSE={sse}{tag}")
        time.sleep(args.interval)
    print("[watch] TIMEOUT — no DONE marker seen", file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
