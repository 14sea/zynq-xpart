#!/usr/bin/env python3
"""M7.5.3-lite on-board orchestrator: classify the test set on ONE LUT-KCM tile by
time-folding the 4-4-2 net — host bakes L1, board computes all hidden activations;
host bakes L2, board computes all outputs + argmax. PS/NEORV32 never reset.

Assumes the board is at U-Boot with impl_7/dfx_top.bit (m753 static + rm_lutkcm)
already loaded and m753_infer running. The board waits (closed-loop, probing the
tile) for each bake. State machine:
  PCAP_PR=0 (verify ICAP IDCODE) -> ICAP-bake L1 (baseline->L1 frames) -> wait
  A_DONE (board did layer 1) -> ICAP-bake L2 (L1->L2 frames!) -> read B1/B2
  classification bitmap -> compare to golden -> restore PCAP_PR=1.

CRITICAL: the L2 frames must be the L1->L2 diff (the tile already holds L1 when L2
is baked), NOT baseline->L2 — else frames that L1 touched but L2==baseline keeps at
L1 and the tile is a corrupt L1/L2 mix.

Usage: m753-demo.py <L1_seq_dir> <L1toL2_seq_dir> [port]
Golden (classes) parsed from sw/m7_train/m753_vectors.h.
"""
import glob, os, re, subprocess, sys, time
import serial

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HW = os.path.join(HERE, 'hwicap-uart.py')
ADDR = 0x41200000
LINE = re.compile(rb'%08x:\s*([0-9a-fA-F]{8})' % ADDR)
PCAP0 = b'mw 0xF8007000 0x4400e07f\r'
PCAP1 = b'mw 0xF8007000 0x4c00e07f\r'


def golden():
    txt = open(os.path.join(ROOT, 'sw/m7_train/m753_vectors.h')).read()
    cls = [int(v) for v in re.search(r'M753_GOLD_CLS\[\d+\]\s*=\s*\{([^}]*)\}', txt).group(1).split(',')]
    return cls


def md1(s):
    s.reset_input_buffer()
    s.write(b'md 0x%08x 1\r' % ADDR)
    time.sleep(0.05)
    m = LINE.search(s.read(256))
    return int(m.group(1), 16) if m else None


def poll_until(s, want, timeout, capture=None):
    """poll until md == one of `want` (set); return (matched, captured_dict)."""
    capture = set(capture or [])
    cap = {}
    t0 = time.time()
    while time.time() - t0 < timeout:
        v = md1(s)
        if v is None:
            continue
        tag = v >> 24
        if tag in capture:
            cap[tag] = v
            if not want and capture.issubset(cap):
                return v, cap
        if want and v in want:
            return v, cap
    return None, cap


def bake(port, seqdir):
    seqs = sorted(glob.glob(os.path.join(seqdir, 'm75_frame_*.seq.bin')))
    if not seqs:
        raise RuntimeError(f"no m75_frame_*.seq.bin files found in {seqdir}")
    print(f"[bake] {len(seqs)} frames from {os.path.basename(seqdir)}")
    for f in seqs:
        subprocess.run([sys.executable, HW, '--port', port, 'writeseq', f],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)


def main():
    if len(sys.argv) < 3:
        print("Usage: m753-demo.py <L1_seq_dir> <L1toL2_seq_dir> [port]", file=sys.stderr)
        return 2
    l1dir, l2dir = sys.argv[1], sys.argv[2]
    port = sys.argv[3] if len(sys.argv) > 3 else '/dev/ebaz-uart'
    gold = golden()
    gold_lo = sum((gold[i] & 1) << i for i in range(24))
    gold_hi = sum((gold[24 + i] & 1) << i for i in range(16))

    s = serial.Serial(port, 115200, timeout=0.15)
    s.write(b'\r'); time.sleep(0.2); s.read(256)            # flush any residual
    print("[m753] PCAP_PR=0 (ICAP owns config)")
    s.write(PCAP0); time.sleep(0.3); s.read(256)
    # verify the ICAP read path is alive BEFORE baking (else writes go nowhere).
    s.close()
    idc = subprocess.run([sys.executable, HW, '--port', port, 'readreg', '12'],
                         capture_output=True, text=True).stdout
    print(f"  ICAP IDCODE: {idc.strip()}")
    if '0x13722093' not in idc:
        print("FAIL: ICAP not healthy (PCAP_PR / readreg) — aborting"); return 2

    # board boots m753_infer and is probing the tile, waiting for the L1 bake.
    print("[m753] baking L1 (board is waiting for it) ...")
    s.close()
    bake(port, l1dir)
    s = serial.Serial(port, 115200, timeout=0.15)

    print("[m753] waiting for A_DONE (board finished layer 1) ...")
    v, cap = poll_until(s, set(), 60, capture={0xAD})
    if 0xAD not in cap:
        print("FAIL: no A_DONE (L1 bake may not have landed)"); return 2
    sc = cap[0xAD]
    print(f"  A_DONE; hi8[0][0..2] = [{(sc>>16)&0xFF},{(sc>>8)&0xFF},{sc&0xFF}]  (expect [1,6,0])")

    print("[m753] baking L2 ...")
    s.close()
    bake(port, l2dir)
    s = serial.Serial(port, 115200, timeout=0.15)

    print("[m753] reading classification bitmap ...")
    _, cap = poll_until(s, set(), 40, capture={0xB1, 0xB2})
    s.write(PCAP1); time.sleep(0.3); s.read(256)
    s.close()
    if 0xB1 not in cap or 0xB2 not in cap:
        print(f"FAIL: incomplete bitmap {cap}"); return 2
    lo, hi = cap[0xB1] & 0xFFFFFF, cap[0xB2] & 0xFFFF
    board = [(lo >> i) & 1 for i in range(24)] + [(hi >> i) & 1 for i in range(16)]

    nmatch = sum(int(board[i] == gold[i]) for i in range(40))
    print(f"\n[m753] board bitmap  : B1=0x{lo:06x} B2=0x{hi:04x}")
    print(f"[m753] golden bitmap : B1=0x{gold_lo:06x} B2=0x{gold_hi:04x}")
    print(f"[m753] board vs oracle: {nmatch}/40 match")
    ok = (lo == gold_lo and hi == gold_hi)
    print(f"\n{'PASS' if ok else 'FAIL'}: whole 4-4-2 net classified on the folded LUT-KCM "
          f"tile {'== oracle (bit-exact)' if ok else '!= oracle'}")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
