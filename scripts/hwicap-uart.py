#!/usr/bin/env python3
"""Drive the AXI HWICAP on the EBAZ4205 PL from the host, over UART, via U-Boot
`mw`/`md` commands (task #8 ICAP retry).

T1 proved PS->PL AXI writes land and T2.1 proved AXI HWICAP comes up healthy under
miner U-Boot (SR=0x5 DONE/EOS, WFV=0x3f). This tool streams config-word sequences
into the HWICAP write FIFO (64-deep -> chunked with CR.Write triggers) and reads
frames back through the read FIFO -- the clean ICAP path the hand-rolled xbus_icap.v
could not drive (its readback returned 0xFFFFFF__).

AXI HWICAP register map (byte offset from base, default 0x41400000):
  WF=0x100 RF=0x104 SZ=0x108 CR=0x10C SR=0x110 WFV=0x114 RFO=0x118 ASR=0x11C GIER=0x1C
CR bits: 0x1=Write(WF->ICAP)  0x2=Read(ICAP->RF)  (self-clears when done)
SR bits: bit0=DONE  bit2=EOS

Subcommands:
  regs                         dump SR/WFV/CR/ASR/RFO
  readback <FAR_hex> <nwords>  read nwords from frame at FAR (prints + saves .bin)
  writeseq <seq.bin>           stream a big-endian uint32 .bin into WF (CR.Write chunks)
"""
import argparse, struct, sys, time
import serial

BASE = 0x41400000
WF, RF, SZ, CR, SR, WFV, RFO, ASR = (BASE+o for o in
    (0x100, 0x104, 0x108, 0x10C, 0x110, 0x114, 0x118, 0x11C))
PROMPT = b'zynq-uboot> '


def cmd(s, line, timeout=1.5):
    s.reset_input_buffer()
    s.write(line.encode() + b'\r')
    buf, t0 = b'', time.time()
    while time.time() - t0 < timeout:
        c = s.read(256)
        if c:
            buf += c
            if buf.rstrip().endswith(b'zynq-uboot>'):
                break
    return buf


def md1(s, addr):
    """read one 32-bit word at addr."""
    r = cmd(s, f"md 0x{addr:08x} 1")
    for ln in r.split(b'\n'):
        ln = ln.strip()
        if ln.lower().startswith(f"{addr:08x}:".encode()):
            return int(ln.split(b':')[1].split()[0], 16)
    raise RuntimeError(f"md parse fail @0x{addr:08x}: {r!r}")


def mw1(s, addr, val):
    cmd(s, f"mw 0x{addr:08x} 0x{val:08x} 1")


def mw_many(s, addr, words):
    """push many words to a single (FIFO) addr, one command at a time.
    Per-word with prompt-wait: the board UART has no flow control, so bursting
    multiple mw commands overruns its RX FIFO and corrupts the WF stream."""
    for w in words:
        mw1(s, addr, w)
    return len(words)


def dump_regs(s):
    names = [("SR", SR), ("WFV", WFV), ("CR", CR), ("ASR", ASR), ("RFO", RFO)]
    return {n: md1(s, a) for n, a in names}


def wait_cr_clear(s, timeout=2.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if md1(s, CR) == 0:
            return True
        time.sleep(0.02)
    return False


def wf_write(s, words):
    """stream words into WF, chunked to FIFO vacancy, CR.Write each chunk."""
    i = 0
    while i < len(words):
        vac = md1(s, WFV) & 0xffff
        if vac == 0:
            wait_cr_clear(s); vac = md1(s, WFV) & 0xffff
        chunk = words[i:i+max(1, vac)]
        mw_many(s, WF, chunk)
        mw1(s, CR, 0x1)            # initiate WF->ICAP
        if not wait_cr_clear(s):
            print(f"  [warn] CR did not clear after chunk @word {i}", file=sys.stderr)
        i += len(chunk)
    return i


# ---- frame readback (7-series, via HWICAP) ----
def readback(s, far, nwords):
    # 1. setup sequence -> WF (sync, RCRC, FAR, RCFG, FDRO read header)
    setup = [
        0xFFFFFFFF,               # dummy
        0xAA995566,               # sync
        0x20000000, 0x20000000,   # NOP
        0x30008001, 0x00000007,   # CMD = RCRC
        0x20000000, 0x20000000,
        0x30002001, far,          # FAR = target frame
        0x30008001, 0x00000004,   # CMD = RCFG (read configuration)
        0x20000000,
        0x28006000,               # Type1 read FDRO, 0 words
        0x48000000 | (nwords & 0x07ffffff),  # Type2 read nwords
        0x20000000, 0x20000000,
    ]
    wf_write(s, setup)
    # 3. pull nwords from ICAP into RF
    mw1(s, SZ, nwords)
    mw1(s, CR, 0x2)               # initiate ICAP->RF
    wait_cr_clear(s, timeout=3.0)
    # 4. drain RF
    out = []
    for k in range(nwords):
        out.append(md1(s, RF))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='/dev/ebaz-uart')
    ap.add_argument('--baud', type=int, default=115200)
    sub = ap.add_subparsers(dest='op', required=True)
    sub.add_parser('regs')
    rb = sub.add_parser('readback'); rb.add_argument('far'); rb.add_argument('nwords', type=int)
    rb.add_argument('--out', default='/tmp/hwicap_frame.bin')
    ws = sub.add_parser('writeseq'); ws.add_argument('binfile')
    args = ap.parse_args()

    s = serial.Serial(args.port, args.baud, timeout=0.1)
    cmd(s, '')  # sync to prompt

    if args.op == 'regs':
        r = dump_regs(s)
        print("  ".join(f"{n}=0x{v:08x}" for n, v in r.items()))

    elif args.op == 'readback':
        far = int(args.far, 16)
        print(f"[*] readback FAR=0x{far:08x} nwords={args.nwords}", flush=True)
        words = readback(s, far, args.nwords)
        blob = struct.pack('>%dI' % len(words), *words)
        open(args.out, 'wb').write(blob)
        nz = sum(1 for w in words if w not in (0, 0xFFFFFFFF))
        print(f"[*] {len(words)} words, {nz} non-trivial; saved {args.out}")
        for i in range(0, min(len(words), 24), 6):
            print("  " + " ".join(f"{w:08x}" for w in words[i:i+6]))

    elif args.op == 'writeseq':
        b = open(args.binfile, 'rb').read()
        words = list(struct.unpack('>%dI' % (len(b)//4), b))
        print(f"[*] writeseq {len(words)} words from {args.binfile}", flush=True)
        before = dump_regs(s); print("  before:", "  ".join(f"{n}=0x{v:08x}" for n,v in before.items()))
        n = wf_write(s, words)
        after = dump_regs(s); print(f"  after {n} words:", "  ".join(f"{n2}=0x{v:08x}" for n2,v in after.items()))

    s.close()


if __name__ == '__main__':
    main()
