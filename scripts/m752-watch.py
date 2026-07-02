#!/usr/bin/env python3
"""M7.5.2 phase-1 watcher: fast-poll the PS mailbox (0x41200000) over U-Boot `md`
while m752_loop.c trains, decode the brief loss curve + the 16 converged W1-tile
INT8 values (tags 0xE0..0xEF) + READY, and verify the board's learned weights
== the oracle tile. Poll tight (no sleep) so the ~0.26 s/value publish windows
aren't missed. Run IMMEDIATELY after `loadb impl_5/dfx_top.bit` (chain with &&).
"""
import re, sys, time
import serial

ADDR = 0x41200000
LINE = re.compile(rb'%08x:\s*([0-9a-fA-F]{8})' % ADDR)
# oracle first-L1-tile INT8 (sim/m75_predict.py): row-major W[r][c]
ORACLE = [3, 11, 16, 12, 2, 2, -4, -3, 2, 13, 13, 15, -4, 16, 15, 12]
READY = 0x600D0000


def s8(v):
    return v - 256 if v & 0x80 else v


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else '/dev/ebaz-uart'
    dur = float(sys.argv[2]) if len(sys.argv) > 2 else 45.0
    s = serial.Serial(port, 115200, timeout=0.15)
    tile = {}
    curve = []
    ready = False
    t0 = time.time()
    print(f"[m752-watch] polling {ADDR:#x} for phase-1 (train -> tile -> READY)")
    while time.time() - t0 < dur:
        s.reset_input_buffer()
        s.write(b'md 0x%08x 1\r' % ADDR)
        time.sleep(0.05)
        data = s.read(256)
        m = LINE.search(data)
        if not m:
            continue
        v = int(m.group(1), 16)
        tag = v >> 24
        if v == READY:
            if not ready:
                print("[m752-watch] READY_TO_YIELD seen")
            ready = True
            if len(tile) == 16:
                break
        elif 0xE0 <= tag <= 0xEF:
            idx = tag - 0xE0
            if idx not in tile:
                tile[idx] = s8(v & 0xFF)
                print(f"  W1tile[{idx:2d}] = {tile[idx]:4d}")
        elif (v >> 31) == 0 and tag <= 59:
            ep, cor, sse = tag, (v >> 16) & 0xFF, v & 0xFFFF
            if not curve or curve[-1][0] != ep:
                curve.append((ep, cor, sse))
                print(f"  ep{ep:2d}  test {cor}/40  SSE={sse}")
    # ---- verdict ----
    got = [tile.get(i) for i in range(16)]
    print(f"\n[m752-watch] curve points: {len(curve)}  (last: {curve[-1] if curve else None})")
    print(f"[m752-watch] board learned tile: {got}")
    print(f"[m752-watch] oracle tile       : {ORACLE}")
    if None in got:
        print(f"FAIL: only caught {16 - got.count(None)}/16 tile values")
        return 2
    ok = got == ORACLE
    print(f"\n{'PASS' if ok else 'FAIL'}: board-trained tile {'==' if ok else '!='} oracle"
          f"{' — safe to checkpoint' if ok else ''}")
    return 0 if (ok and ready) else 1


if __name__ == '__main__':
    sys.exit(main())
