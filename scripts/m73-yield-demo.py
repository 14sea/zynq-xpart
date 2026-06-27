#!/usr/bin/env python3
"""m73-yield-demo.py — M7.3 path (a) train->yield->infer orchestrator (Tier-2).

Drives the converged-seed single-step demo end-to-end against the m73_yield.c
firmware (sw/m7_train/m73_yield.c) baked into the DFX static IMEM:

  1. (--load-full) measured/plain loadb the full bitstream (today's clean static +
     rm_train) -> board runs Phase 1: settle, ONE verified HW SGD step on the oracle's
     CONVERGED weights, publishes the learned model + READY_TO_YIELD over mailbox
     0x41200000.
  2. Poll the mailbox; decode the learned W2 row0 + b2 (tags 0xC0..0xC4) and check them
     against the oracle golden (W2=[382,45,475,288], b2=-59). Wait for READY (0x600D0000).
  3. On READY: run a MEASURED `loadbp` swap rm_train -> rm_tpuvpu (the yield). The static
     NEORV32 keeps running; the learned weights live in DMEM and survive the RP reconfig.
  4. Keep polling; the Phase-2 inference loop publishes DONE = 0x8000_0000|XOR<<16|... .
     After the post-swap settle the score settles to XOR 4/4 on the LEARNED weights, now
     computed by the swapped-in inference RM. PS/NEORV32 heartbeat is never interrupted.

Mailbox protocol (sw/m7_train/m73_yield.c):
  0xC0..0xC4 << 24 | signed24 : learned W2[0],W2[1],W2[2],W2[3],b2
  0x600D0000                  : READY_TO_YIELD
  0x80000000 | XOR<<16 | preds<<8 | 0xED : DONE / inference pass

Usage:
  scripts/m73-yield-demo.py --infer-bit vivado/dfx/build/dfx.runs/impl_5/<rm_tpuvpu_partial>.bit
  scripts/m73-yield-demo.py --load-full vivado/dfx/build/dfx.runs/impl_8/dfx_top.bit \
                            --infer-bit .../impl_5/<rm_tpuvpu_partial>.bit
"""
import argparse
import os
import re
import subprocess
import sys
import time

import serial

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ADDR = 0x41200000
LINE = re.compile(rb'%08x:\s*([0-9a-fA-F]{8})' % ADDR)

GOLD_W2 = [382, 45, 475, 288]
GOLD_B2 = -59


def s24(v):
    v &= 0xFFFFFF
    return v - (1 << 24) if (v & 0x800000) else v


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


def loadb(bit, op, port, gated=True):
    """loadb/loadbp a bitstream. gated=True -> through the M5 measured-load gate."""
    if gated:
        cmd = [sys.executable, os.path.join(HERE, 'measured-load.py'),
               '--bit', bit, '--op', op, '--port', port]
    else:
        cmd = [sys.executable, os.path.join(HERE, 'uboot-fpga-load.py'),
               '--bit', bit, '--op', op, '--port', port]
    print(f"\n$ {' '.join(os.path.basename(c) if i == 1 else c for i, c in enumerate(cmd))}")
    return subprocess.run(cmd, cwd=ROOT).returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='/dev/ebaz-uart')
    ap.add_argument('--infer-bit', required=True, help='rm_tpuvpu partial (yield target)')
    ap.add_argument('--load-full', help='full bitstream to loadb first (static+rm_train)')
    ap.add_argument('--ungated-full', action='store_true',
                    help='loadb the full via uboot-fpga-load (bypass the gate; the full '
                         'may not be allowlisted)')
    ap.add_argument('--timeout', type=float, default=300.0)
    args = ap.parse_args()

    if args.load_full:
        print("[1] loadb full (static + rm_train) -> Phase 1 starts on board")
        if loadb(args.load_full, 'loadb', args.port, gated=not args.ungated_full) != 0:
            sys.exit("full load failed")

    ser = serial.Serial(args.port, 115200, timeout=0.2)
    print(f"[2] poll mailbox 0x{ADDR:08x}: decode learned model + wait READY_TO_YIELD")
    learned = {}
    ready = False
    swapped = False
    last = None
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        v = read_mbox(ser)
        if v is None or v == last:
            time.sleep(0.25)
            continue
        last = v
        tag = v >> 24
        if 0xC0 <= tag <= 0xC4 and not ready:
            idx = tag - 0xC0
            learned[idx] = s24(v)
            name = f"W2[{idx}]" if idx < 4 else "b2"
            print(f"    learned {name:5s} = {s24(v)}")
        elif v == 0x600D0000 and not ready:
            gold = GOLD_W2 + [GOLD_B2]
            got = [learned.get(i) for i in range(5)]
            match = (got == gold)
            print(f"[3] READY_TO_YIELD. learned model {got} vs oracle {gold} -> "
                  f"{'MATCH' if match else 'MISMATCH'}")
            ready = True
            print("[4] measured loadbp swap rm_train -> rm_tpuvpu (the yield)")
            if loadb(args.infer_bit, 'loadbp', args.port, gated=True) != 0:
                sys.exit("inference RM gate/loadbp failed")
            swapped = True
            ser.reset_input_buffer()
        elif (v & 0x80000000) and (v & 0xFF) == 0xED:
            ok = (v >> 16) & 0xFF
            preds = (v >> 8) & 0xF
            where = "rm_tpuvpu (post-yield)" if swapped else "rm_train (pre-yield)"
            print(f"[infer] XOR {ok}/4  preds={preds:04b}  on {where}  (mbox=0x{v:08x})")
            if swapped and ok == 4:
                print("\n=== M7.3 Tier-2 DONE: trained (1 verified step) -> measured yield "
                      "-> inference XOR 4/4 on the LEARNED weights, computed by the "
                      "swapped-in RM, PS/NEORV32 never reset. ===")
                return 0
        time.sleep(0.25)
    print("[m73] TIMEOUT before post-yield XOR 4/4", file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
