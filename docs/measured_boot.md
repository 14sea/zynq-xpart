# Phase 5 (M5) — measured-boot trust anchor

> **STATUS: DONE — verified on hardware 2026-06-06.** Trusted bitstreams measure
> (SHA-256) and load; the tampered hand-edited LUT partial from Phase 4 is rejected
> because its hash is not in the allowlist, so it never reaches the fabric.

## Idea
A PS-side **measured loader** (`scripts/measured-load.py`) that hash-gates every
full/partial bitstream against an allowlist (`board/allowlist.sha256`) before
loading it. On a match it hands off to `uboot-fpga-load.py` (`fpga loadb|loadbp`);
on a miss it refuses (exit 2). This is the rot_tpu_handoff modes-g/G/c
"CRC / whitelist -> load" pipeline and the EP4CE6 "editable-LE allowlist + integrity
gate", run on the host orchestrating the PS. The soft-core firmware is measured
transitively: its image is baked into the full bitstream's IMEM, so the full
bitstream's hash anchors it.

Deliberately NOT done: eFUSE burning / Zynq hardware secure boot (RSA/AES) -- the
EBAZ4205 must keep JTAG recovery and the original BOOT.BIN/FSBL untouched. A
hardware-anchored variant is a separate follow-up.

## On-board result
```
measured-load full  (allowlisted)   -> [trust] OK     -> load -> md 0x41200000 = 0x001E0046
measured-load LUT_A (allowlisted)   -> [trust] OK     -> load -> md 0x41200000 = 0x005A004D
measured-load hand-patched (M4 edit, NOT allowlisted) -> [trust] REJECTED -> refused, fabric unchanged
```

The closing loop with M4: a LUT-INIT edit you can apply live is only permitted if
its resulting bitstream is allowlisted; an unauthorized edit is caught here.
