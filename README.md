# zynq_xpart — real *live* Xilinx-XPART demo on Zynq-7010 (EBAZ4205)

Migrate `rot_tpu_handoff` — which hit its ceiling on the Altera **EP4CE6** ("XPART minus
liveness": mode-H = `.rbf` LUT surgery + EPCS staging + **cold boot**) — onto the **Xilinx
XC7Z010**, and use the Zynq's native **ICAP + PCAP + Partial Reconfiguration (DFX)** to achieve,
for the first time, **live** partial reconfiguration (no halt, no cold boot).

- **Track A (foundation)**: DFX module hot-swap — `fpgautil -b rm.bit -f Partial` (PCAP); the
  static region / PS keep running.
- **Track B (headline)**: prjxray + ICAP single-frame **LUT-INIT** live edit — bake quantized NN
  weights into LUT truth tables and change them with no resynthesis and no cold boot.
- **Host = hybrid**: the Zynq PS (ARM Linux) loads/orchestrates; a NEORV32 soft-core lives in the
  PL as the "measured RoT element".
- **Trust anchor = software measured-boot**; no eFUSE burning, no hardware secure boot, and the
  original BOOT.BIN/FSBL is left untouched (keep JTAG recovery).

Full plan in `docs/plan.md`. Target-board hardware details under `board/` (copied from the
EBAZ4205 bring-up).

## Isolation principle (hard constraint)
This directory is a **standalone project**. The contents of `rtl_src/`, `sw_src/`, `board/`, and
`scripts/` are read-only **copies** taken from other projects
(`/home/test/{xilinx,neorv32_tpu,neorv32_rot,riscv_tpu_demo,rot_tpu_handoff}`). All edits happen
only inside this directory — **never modify any file in those source projects**.

## Layout
- `board/` — EBAZ4205 board config copies (`ebaz4205.cfg`, `ebaz4205_defconfig`)
- `scripts/` — bring-up script copies (`program-pl.sh`, `nand-flash.py`, `jtag-scan.sh`,
  `uart-poke.py`, `uboot-intercept.py`) plus `uboot-fpga-load.py` (this project)
- `rtl_src/` — RTL porting starting points (read-only copies of NEORV32+TPU, PicoRV32+TPU); local only, gitignored
- `rtl/` — ported / new Vivado RTL (this project's output)
- `sw_src/` — firmware porting starting point (read-only copy of `stage2_loader`); local only, gitignored
- `sw/` — this project's firmware (PS-side measured-boot, etc.)
- `vivado/` — Vivado projects (`hello_pl/`, `zynq_xpart/`)
- `partial/` — generated full/partial bitstreams and ICAP single-frame artifacts
- `docs/` — plan and notes
