# Phase 3 — DFX (Dynamic Function eXchange) design

> **STATUS: M3 DONE — verified on hardware 2026-06-06.** Loaded the full bitstream
> (static + RM1), then live-swapped the TPU partition via `fpga loadbp`:
> `md 0x41200000` read `0x00BB00CC` (RM2 alt) ↔ `0x001E0046` (RM1 real TPU), with
> the PS and NEORV32 never reset. First true live partial reconfiguration on the
> EBAZ4205 — the capability the Cyclone-IV EP4CE6 physically could not do.

Goal (M3): the first **live partial reconfiguration** — carve the TPU into a
Reconfigurable Partition (RP) and hot-swap it on the board while the PS and the
NEORV32 soft-core keep running. This is the capability the Cyclone-IV EP4CE6
physically could not do.

## Architecture
- **Static region**: PS7 + NEORV32 + XBUS decode + mailbox + AXI-GPIO. Unchanged
  from M2 except the TPU cell is now the reconfigurable partition.
- **Reconfigurable Partition cell**: `tpu_rp` (instance `wb_tpu_inst` inside
  `neorv32_soc_dfx`), interface = the XBUS slave signals.
- **RM1** `rtl/dfx/tpu_rp_rm1_tpu.v`: the real 4×4 TPU → firmware matmul gives
  PS mailbox **0x001E0046** (RES0=30, RES1=70).
- **RM2** `rtl/dfx/tpu_rp_rm2_alt.v`: a tiny alternate that returns RES0=0xBB,
  RES1=0xCC → PS mailbox **0x00BB00CC**. Unmistakably different.

## Demo (live swap)
1. Firmware loops the matmul + mailbox write forever (so the result tracks the
   currently-loaded RM without any CPU reset).
2. Load the full bitstream (static + RM1) via `fpga loadb` → PS reads 0x001E0046.
3. `fpga loadbp` the RM2 **partial** bitstream → PS reads 0x00BB00CC, with the PS
   and NEORV32 never reset. (miner U-Boot supports `fpga loadbp`, confirmed in M1.)

## Vivado DFX flow (project mode) — as built in `vivado/dfx/build_dfx.tcl`
1. A **PS-only BD** (PS7 + axi_gpio mailbox) plus an **RTL top `dfx_top`** that
   instantiates the BD wrapper and `neorv32_soc_dfx`, so the RP cell
   `u_soc/wb_tpu_inst` is a true top-level partition. (Putting the RP inside a BD
   module-ref *hid* the cell — using an RTL top was the key fix.) `set_property PR_FLOW 1`.
2. Mark the RP cell `HD.RECONFIGURABLE`; `create_partition_def` / `create_reconfig_module`
   for RM1 and RM2; `create_pr_configuration` config_1 (RM1) and config_2 (RM2).
3. Floorplan a **Pblock** for the RP covering enough DSP48 (≥16 for RM1) + BRAM
   (≥1) + LUTs, snapped to reconfig-frame boundaries (`RESET_AFTER_RECONFIG`,
   `SNAPPING_MODE`).
4. impl config_1 → full + RM1 partial bitstreams; impl config_2 (locked static) →
   RM2 partial bitstream.

## Notes / risks
- XC7Z010 floorplan: 4 clock regions (X0Y0/X1Y0/X0Y1/X1Y1), each 1100 SLICE +
  20 DSP48 + BRAM. **As built**, `pblock_rp.xdc` floorplans the RP by explicit
  SLICE/DSP48/RAMB **site ranges** in the X1Y0 region — *not* a `CLOCKREGION_X1Y0`
  rectangle, which fails because it includes the central clock spine (illegal in a
  Pblock). `RESET_AFTER_RECONFIG true` + `SNAPPING_MODE ON`. The static (NEORV32 + PS
  interface) places elsewhere; PS7 is hard (in the PS).
- Partial bitstream loaded over UART ymodem like M1/M2 (`uboot-fpga-load.py --op loadbp`).
- This is the most involved phase; expect iteration on the Pblock + DFX runs.

## Extended in M4/M5
The same DFX flow was extended to **4 PR configurations** — RM1, RM2, and the
LUT-table RMs `rm_lut` / `rm_lut_b` — for the live LUT-INIT surgery (M4) and the
measured-boot allowlist (M5). See `docs/lut_surgery.md` and `docs/measured_boot.md`.
