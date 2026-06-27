#!/usr/bin/env python3
"""Build a SINGLE-frame ICAP write sequence (one FAR-set per sequence) from a
bitstream's FDRI word stream — the M7.3+ checkpoint-to-fabric writer.

Why one FAR per sequence: a 7-series frame write is double-buffered (a frame
commits only when the NEXT frame shifts in), so we write the target frame F plus
its neighbour F+1 (202 words). CRUCIAL lesson from M7.3+ (2026-06-27): putting
MULTIPLE FAR-sets inside ONE sync..DESYNC envelope mis-commits the buffered frame
to the new FAR and CORRUPTS the array (mailbox went all-saturated 0x7F7F7F7F).
The fix is one complete envelope (233 words, == the M6.5.2 proven size) per frame,
streamed separately by `hwicap-uart.py writeseq`. Run this once per changed frame.

Locate the (FAR, frame-index) of a changed weight bit with prjxray bitread:
  bitread -part_file <part.yaml> -y -o base.bits  baseline_partial.bit
  bitread -part_file <part.yaml> -y -o edit.bits  edited_partial.bit
  comm -13 <(sort base.bits) <(sort edit.bits)      # -> bit_<FAR>_<word>_<bit>
The frame-index is the FDRI-stream position; see docs/m7_plan.md §M7.3+ for the
FDRI-block parse (here: data start word S, frame# = (FAR-frame order)).

  hwicap-build-frameseq.py <bit> <FAR_hex> <frame_index> <fdri_start_word> <out.seq.bin>
"""
import struct, sys

SYNC = b'\xaa\x99\x55\x66'
FW = 101
IDCODE = 0x03722093          # the value the M6.5.2 proven seq used (works on rev-1 silicon)


def cfg_words(path):
    b = open(path, 'rb').read()
    s = b.find(SYNC)
    n = (len(b) - s) // 4
    return list(struct.unpack('>%dI' % n, b[s:s + n * 4]))


def main():
    bit, far_hex, fr, S, out = (sys.argv[1], int(sys.argv[2], 16),
                                int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
    far = far_hex
    W = cfg_words(bit)
    base = S + fr * FW
    frames2 = W[base:base + 2 * FW]
    if len(frames2) != 2 * FW:
        sys.exit("frame extraction out of range")
    seq = [0xFFFFFFFF] * 8 + [
        0xAA995566, 0x20000000,
        0x30008001, 0x00000007,            # CMD RCRC
        0x20000000, 0x20000000,
        0x30018001, IDCODE,                # write IDCODE
        0x30008001, 0x00000001, 0x20000000,  # CMD WCFG
        0x30002001, far,                   # FAR
        0x30004000, 0x50000000 | (2 * FW), # FDRI type2 202 words
    ] + list(frames2) + [
        0x30000001, 0x00000000,            # CRC reg = 0 (CRC disabled)
        0x30008001, 0x0000000D,            # CMD DESYNC
        0x20000000, 0x20000000, 0x20000000, 0x20000000,
    ]
    open(out, 'wb').write(struct.pack('>%dI' % len(seq), *seq))
    print(f"FAR=0x{far:08x} frame#{fr} words[{base}:{base + 2 * FW}] "
          f"w50(ECC)=0x{W[base + 50]:08x} -> {out} ({len(seq)} words)")


if __name__ == '__main__':
    main()
