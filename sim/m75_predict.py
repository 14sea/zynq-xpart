#!/usr/bin/env python3
"""M7.5.1 checkpoint-to-fabric: derive the trained 4x4 weight tile + predict the
on-board mailbox after ICAP-baking it into rm_lutkcm.

The M7.4-tiny 16-4-2 net (sim/oracle_tiny.py) is trained to convergence; we take
the INT8 view of the FIRST 4x4 tile of layer-1 weights — W1[0:4][0:4], the same
quant the array uses (quant_int8 with WSHIFT) — and bake those 16 real learned
weights into the LUT-KCM PE array (rtl/dfx/lutkcm_pe.v: each weight = 8 dont_touch
LUT6 INIT[0]s), live via ICAP, no reset. This extends M7.3+ (which baked ONE
synthetic-ish weight) to a full tile of genuinely-trained weights.

The rm_lutkcm static firmware (sw/tpu_vpu_firmware/main.c) feeds a FIXED input
x = {x0,x1,x2,x3} = {2,3,4,5} and runs the M6 VPU (bias -> Leaky ReLU -> requant)
over the raw row sums, publishing {POST3,POST2,POST1,POST0} to the PS mailbox.
Baseline tile = [[1,1,1,1],[1,2,3,4],[2,2,2,2],[1,0,1,0]] -> RES [14,40,28,6]
-> POST [31,57,25,16] -> 0x1019391F (verified M6.3/M7.3+). This script reuses that
exact VPU model so the trained-tile mailbox is a precise functional golden to
check on silicon.

Usage:
  python3 sim/m75_predict.py            # print tile + predicted mailbox
  python3 sim/m75_predict.py --tcl-args # emit the 16 ints for m75_edit_tile.tcl
"""
import argparse
import sys
sys.path.insert(0, "sim")
import numpy as np
import oracle_tiny as o

# rm_lutkcm static firmware (sw/tpu_vpu_firmware/main.c) fixed config:
X = [2, 3, 4, 5]                 # x0,x1,x2,x3 (x_in packs {x3,x2,x1,x0})
VPU_BIAS  = [8, 0, -10, 5]
VPU_SCALE = 181
VPU_SHIFT = 7
VPU_ALPHA = 4
BASELINE = [[1, 1, 1, 1], [1, 2, 3, 4], [2, 2, 2, 2], [1, 0, 1, 0]]


def leaky(z, k):
    # M6 VPU leaky ReLU (rtl/vpu.v): y = z>=0 ? z : z - (z>>>k)  (slope 1-2^-k).
    # NOT z>>k — the negative path keeps sign with reduced magnitude.
    return z if z >= 0 else (z - (z >> k))      # >> is arithmetic for Python ints


def requant(a):
    v = (a * VPU_SCALE + (1 << (VPU_SHIFT - 1))) >> VPU_SHIFT   # round-half-up
    return max(-128, min(127, v))


def vpu_post(W):
    """Model lutkcm_array + M6 VPU: POST[r] = requant(leaky(RES[r]+bias[r]))."""
    post = []
    for r in range(4):
        res = sum(int(W[r][c]) * X[c] for c in range(4))
        z = res + VPU_BIAS[r]
        post.append(requant(leaky(z, VPU_ALPHA)))
    return post


def mailbox(post):
    """{POST3,POST2,POST1,POST0} packed bytes, exactly as the firmware writes."""
    return (((post[3] & 0xFF) << 24) | ((post[2] & 0xFF) << 16) |
            ((post[1] & 0xFF) << 8) | (post[0] & 0xFF))


def trained_tile():
    trx, trY, tex, teY = o.load_dataset()
    P, _, _ = o.train(trx, trY, tex, teY, verbose=False)
    Wi = o.quant_int8(P['W1'][:4, :4], o.WSHIFT)        # INT8 view, first L1 tile
    return Wi.astype(int)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tcl-args', action='store_true',
                    help='print the 16 row-major ints for m75_edit_tile.tcl')
    args = ap.parse_args()

    Wt = trained_tile()
    flat = [int(Wt[r][c]) for r in range(4) for c in range(4)]   # row-major W[r][c]

    if args.tcl_args:
        print(" ".join(str(v) for v in flat))
        return

    print("== M7.5.1 trained tile (M7.4-tiny W1[0:4][0:4], INT8 view) ==")
    print(Wt)
    print("row-major (W[r][c], r=0..3 c=0..3):", flat)
    bm = mailbox(vpu_post(BASELINE))
    tm = mailbox(vpu_post(Wt))
    print(f"\nbaseline tile {BASELINE}")
    print(f"  RES={[sum(BASELINE[r][c]*X[c] for c in range(4)) for r in range(4)]}"
          f"  POST={vpu_post(BASELINE)}  mailbox=0x{bm:08X}  (expect 0x1019391F)")
    print(f"trained tile -> on-board functional golden:")
    print(f"  RES={[sum(int(Wt[r][c])*X[c] for c in range(4)) for r in range(4)]}"
          f"  POST={vpu_post(Wt)}  mailbox=0x{tm:08X}")


if __name__ == '__main__':
    main()
