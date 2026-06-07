#!/usr/bin/env python3
"""Stage an ICAP frame-write sequence into the neorv32_soc_icap AXI-Lite framebuf from
the PS, over UART U-Boot `mw` (zynq_xpart T2.3). Layout: word[0]=length N (written LAST
as the ready flag), word[1..N]=sequence. NEORV32 polls word[0] and, once non-zero,
streams word[1..N] to its in-fabric xbus_icap->ICAPE2 controller.

  framebuf-load.py <seq.bin> <base_hex>     e.g. framebuf-load.py /tmp/t23.bin 0x42000000
"""
import struct, sys, time
import serial

PORT = '/dev/ebaz-uart'


def cmd(s, line, timeout=1.0):
    s.reset_input_buffer()
    s.write(line.encode() + b'\r')
    buf, t0 = b'', time.time()
    while time.time() - t0 < timeout:
        c = s.read(128)
        if c:
            buf += c
            if buf.rstrip().endswith(b'zynq-uboot>'):
                return buf
    return buf


def main():
    binf, base = sys.argv[1], int(sys.argv[2], 16)
    w = list(struct.unpack('>%dI' % (len(open(binf, 'rb').read()) // 4),
                           open(binf, 'rb').read()))
    n = len(w)
    print(f"[*] staging {n} words to framebuf @0x{base:08x} (word[0]=len last)", flush=True)
    s = serial.Serial(PORT, 115200, timeout=0.1)
    cmd(s, '')
    # seq -> word[1..n]
    for i, x in enumerate(w):
        cmd(s, f"mw 0x{base + 4*(i+1):08x} 0x{x:08x} 1")
        if i % 50 == 0:
            print(f"  {i}/{n}", flush=True)
    # length -> word[0]  (ready flag)
    cmd(s, f"mw 0x{base:08x} 0x{n:08x} 1")
    # sanity read-back of a few
    print("[*] readback word0/word1/word9:")
    for off in (0, 4, 36):
        r = cmd(s, f"md 0x{base+off:08x} 1")
        for ln in r.split(b'\n'):
            if (f"{base+off:08x}".encode()) in ln.lower():
                print("   ", ln.strip().decode(errors='replace'))
    s.close()
    print("[*] done")


if __name__ == '__main__':
    main()
