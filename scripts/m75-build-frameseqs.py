#!/usr/bin/env python3
"""M7.5.1: build ALL per-frame ICAP write sequences to bake a trained 4x4 weight
tile into rm_lutkcm — the multi-frame generalisation of hwicap-build-frameseq.py /
hwicap-make-framewrite.py (which handled the single-weight M7.3+ case).

Editing 16 PE weights (vs M7.3+'s 1) flips ~48 INIT bits across ~18 config frames.
Per the hard-won M7.3+ lesson we emit ONE complete sync..DESYNC envelope per frame
(one FAR-set each), streamed separately by `hwicap-uart.py writeseq`.

Method (raw-faithful, anchored by prjxray):
  - prjxray `bitread -y` of A(baseline) vs B(edited) partial gives changed bits
    `bit_<FAR>_<wofs>_<bit>` — <wofs> is the frame-internal word offset (raw frame
    word index; NOT skipping ECC — verified against the M7.3+ proven writes).
  - For each changed FAR, find its frame start in B's RAW config-word stream by
    anchoring on the differing raw words at the reported wofs set (so we extract
    the REAL frame incl. the per-frame ECC word — NOT a prjxray .bits rebuild).
  - Extract the target frame F + neighbour F+1 (202 words) from B, wrap in the
    proven 233-word envelope (RCRC, WCFG, FAR, FDRI type2 202w, CRC=0, DESYNC).
  - Self-check: B-vs-A flips inside [start, start+101) match exactly the prjxray
    set/clear bits for that FAR.

Usage:
  m75-build-frameseqs.py <A.bit> <B.bit> <setbits.txt> <clrbits.txt> <out_dir>
where setbits/clrbits are `comm -13/-23` outputs of the sorted bitread -y files.
Emits <out_dir>/m75_frame_<FAR>.seq.bin (one per frame) + m75_manifest.txt.
"""
import os, re, struct, sys

SYNC = b'\xaa\x99\x55\x66'
FW = 101
IDCODE = 0x03722093          # xc7z010 config IDCODE (the M6.5.2-proven value)
BIT = re.compile(r'bit_([0-9a-fA-F]+)_(\d+)_(\d+)')


def cfg_words(path):
    b = open(path, 'rb').read()
    s = b.find(SYNC)
    n = (len(b) - s) // 4
    return list(struct.unpack('>%dI' % n, b[s:s + n * 4]))


def parse_bits(path):
    """-> {FAR: {(wofs,bit), ...}}"""
    d = {}
    for ln in open(path):
        m = BIT.search(ln)
        if m:
            far, wofs, bit = int(m.group(1), 16), int(m.group(2)), int(m.group(3))
            d.setdefault(far, set()).add((wofs, bit))
    return d


def build_seq(frames2, far):
    return [0xFFFFFFFF] * 8 + [
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


def main():
    a, b, setf, clrf, outd = sys.argv[1:6]
    WA, WB = cfg_words(a), cfg_words(b)
    n = min(len(WA), len(WB))
    D = [i for i in range(n) if WA[i] != WB[i]]      # raw differing word indices
    Dset = set(D)

    setb, clrb = parse_bits(setf), parse_bits(clrf)
    fars = sorted(set(setb) | set(clrb))
    os.makedirs(outd, exist_ok=True)
    man = open(os.path.join(outd, 'm75_manifest.txt'), 'w')
    print(f"raw differing words: {len(D)}   changed frames: {len(fars)}")

    ok = 0
    for far in fars:
        changes = setb.get(far, set()) | clrb.get(far, set())
        wofss = sorted({w for w, _ in changes})
        wset = set(wofss)
        w0 = wofss[0]
        # Frame data appears twice in the partial (two FDRI blocks). A valid start s
        # is one where the differing raw-word OFFSETS inside [s, s+101) equal exactly
        # the prjxray-reported wofs (plus the per-frame ECC word 50, which always
        # changes when an INIT in the frame changes). This exact-set match pins the
        # frame uniquely (modulo the duplicate copy, of which we take the first).
        cand = {r - w0 for r in D if (r - w0 + w0) in Dset}
        starts = []
        for s in sorted(cand):
            if s < 0 or s + FW > n:
                continue
            # full (word,bit) match: the frame's bit-level diff (excl. ECC word 50)
            # must equal exactly the prjxray set/clear bits — pins the real frame, not
            # a first-copy spurious word-offset coincidence.
            got = set()
            for w in range(FW):
                if w == 50:
                    continue
                x = WA[s + w] ^ WB[s + w]
                bit = 0
                while x:
                    if x & 1:
                        got.add((w, bit))
                    x >>= 1; bit += 1
            if got == changes:
                starts.append(s)
        if not starts:
            man.write(f"FAR 0x{far:08x}: NO valid start (wofs={wofss})\n")
            print(f"  FAR 0x{far:08x}: NO valid start", file=sys.stderr)
            continue
        start = starts[0]
        frames2 = WB[start:start + 2 * FW]
        if len(frames2) != 2 * FW:
            man.write(f"FAR 0x{far:08x}: out-of-range start={start}\n"); continue
        # self-check: flips within frame F match prjxray set/clear exactly
        want = {(w, bit) for w, bit in changes}
        got = set()
        for w in range(FW):
            x = WA[start + w] ^ WB[start + w]
            bit = 0
            while x:
                if x & 1 and w != 50:        # word 50 = ECC (prjxray doesn't model it)
                    got.add((w, bit))
                x >>= 1; bit += 1
        status = "OK" if got == want else f"MISMATCH want={len(want)} got={len(got)}"
        if got == want:
            ok += 1
        out = os.path.join(outd, f"m75_frame_{far:08x}.seq.bin")
        seq = build_seq(frames2, far)
        open(out, 'wb').write(struct.pack('>%dI' % len(seq), *seq))
        ecc = WB[start + 50]
        man.write(f"FAR 0x{far:08x} start={start} wofs={wofss} ECC=0x{ecc:08x} "
                  f"selfcheck={status} -> {os.path.basename(out)}\n")
        print(f"  FAR 0x{far:08x} start={start:6d} ECC=0x{ecc:08x} {status}")
    man.write(f"\n{ok}/{len(fars)} frames self-checked OK\n")
    man.close()
    print(f"{ok}/{len(fars)} frames self-checked OK; manifest -> {outd}/m75_manifest.txt")
    sys.exit(0 if ok == len(fars) else 1)


if __name__ == '__main__':
    main()
