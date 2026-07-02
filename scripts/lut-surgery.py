#!/usr/bin/env python3
"""Phase 4 LUT-INIT surgery helper (zynq_xpart).

The DFX partial bitstreams are built with BITSTREAM.GENERAL.CRC Disable, so a
host edit of a LUT6 INIT bit can be loaded live via `fpga loadbp` without a CRC
recompute -- literal JBits/XPART LUT-truth-table surgery.

  diff A.bit B.bit            locate where two partials differ. Two partials that
                              differ by exactly one LUT6 INIT bit reveal that
                              INIT bit's location in the configuration frames
                              (the EP4CE6 mode-H 'diff to find the CRAM bit' method).
  flip in.bit out.bit OFF BIT flip bit BIT (0..7) of byte OFF, write out.bit.

Cross-checked against prjxray (xc7z010 tilegrid + segbits_clbll/clblm).
"""
import sys

SYNC = b'\xaa\x99\x55\x66'   # 7-series bitstream sync word


def load(p):
    return bytearray(open(p, 'rb').read())


def sync_off(b):
    i = b.find(SYNC)
    return i if i >= 0 else 0


def diff(pa, pb):
    A, B = load(pa), load(pb)
    s = sync_off(A)
    n = min(len(A), len(B))
    ds = [(i, A[i] ^ B[i]) for i in range(n) if A[i] != B[i]]
    print(f"sizes A={len(A)} B={len(B)}; sync@0x{s:x}; {len(ds)} differing bytes")
    cfg = [d for d in ds if d[0] >= s]
    print(f"config-region diffs: {len(cfg)} (header diffs = name/timestamp, ignore)")
    for off, x in cfg:
        bits = [k for k in range(8) if (x >> k) & 1]
        print(f"  CONFIG byte 0x{off:06x}  A=0x{A[off]:02x} B=0x{B[off]:02x}  xor=0x{x:02x} bit(s)={bits}")
    return cfg


def flip(inp, out, off, bit):
    B = load(inp)
    old = B[off]
    B[off] ^= (1 << bit)
    open(out, 'wb').write(B)
    print(f"byte 0x{off:x}: 0x{old:02x} -> 0x{B[off]:02x} (bit {bit}); wrote {out}")


if __name__ == '__main__':
    if len(sys.argv) >= 4 and sys.argv[1] == 'diff':
        diff(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 6 and sys.argv[1] == 'flip':
        flip(sys.argv[2], sys.argv[3], int(sys.argv[4], 0), int(sys.argv[5], 0))
    else:
        print(__doc__)
        sys.exit(1)
