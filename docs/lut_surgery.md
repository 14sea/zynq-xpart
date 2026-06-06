# Phase 4 (M4-scaled) — live LUT-INIT surgery

> **STATUS: DONE — verified on hardware 2026-06-06.** A LUT6 truth table was
> edited *by hand in the partial bitstream* and applied **live** via `fpga loadbp`:
> PS `md 0x41200000` read `0x005A004D` → `0x005B004D` (the firmware's index X=1
> output Y went 0x5A → 0x5B), with the PS and NEORV32 never reset. This is the
> literal JBits/XPART use case — the EP4CE6 mode-H CRAM-bit edit, now truly live.

## Idea
"Weights in LUTs": the reconfigurable partition holds a small lookup unit whose
table lives in 8 explicit `(* DONT_TOUCH *)` LUT6 INIT values (`rtl/dfx/tpu_rp_rm_lut.v`).
The existing firmware loop writes the index to X_IN and reads the result; editing a
LUT INIT bit changes the table entry, and a partial reconfig applies it with no
resynthesis and no cold boot.

## Locating the INIT bit (controlled-diff = EP4CE6 mode-H method)
Two independently-built partials differ by ~70 routing-noise bytes, so a naive diff
can't isolate the INIT bit. Instead:
1. Open LUT_A's routed checkpoint, change **only** `l0`'s INIT (`set_property INIT`),
   `write_bitstream` → a partial with identical place/route, differing only in that
   one LUT's contents.
2. `scripts/lut-surgery.py diff` the two → the LUT's CRAM bytes drop out cleanly
   (6 config bytes: the 3-byte INIT encoding, written twice because DFX programs the
   RP frames in two passes).

`l0` placement (for prjxray cross-validation, db has `xc7z010/tilegrid.json` +
`segbits_clbll/clblm`): `SLICE_X25Y21`, `A6LUT`.

## The surgery
`scripts/lut-surgery.py` patches those bytes in LUT_A by hand; the result's config
region is byte-identical to the Vivado-built `l0=0x2` version (verified), confirming
the edit is exactly the LUT truth-table change. Build uses
`BITSTREAM.GENERAL.CRC Disable` so the edited bitstream loads without a CRC recompute.

## On-board result
```
fpga loadb  full (RM1)       -> md 0x41200000 = 0x001E0046
fpga loadbp LUT_A (Y=0x5A)   -> md 0x41200000 = 0x005A004D
fpga loadbp hand-patched     -> md 0x41200000 = 0x005B004D   (LUT INIT edited by hand)
```

## Deferred to the very end (the "original" M4, task #8)
- **ICAP self-reconfiguration**: drive an AXI HWICAP from the PL so the soft-core
  pushes the edited frame from *inside* the chip (vs PCAP/`loadbp` from the PS here).
- **Full prjxray prediction**: compute the exact frame/bit from `l0`'s placement via
  tilegrid+segbits as an independent locate, cross-checked against the diff method.
