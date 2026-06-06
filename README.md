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

## Results (all hardware-verified on the EBAZ4205)

| Milestone | What | Status |
|---|---|---|
| M1 | Self-made bitstream live on the board; PS reads PL over AXI | ✅ |
| M2 | NEORV32 + 4×4 INT8 TPU in the PL; PS reads the live TPU result (`0x001E0046`) | ✅ |
| **M3 (Track A)** | **Live DFX module hot-swap** of the accelerator partition via PCAP (`0x001E0046`↔`0x00BB00CC`) | ✅ |
| **M4 (Track B)** | **Live LUT-INIT surgery** — a LUT6 truth table hand-edited in the partial and applied live via `loadbp` (`0x005A004D`→`0x005B004D`) | ✅ [docs/lut_surgery.md](docs/lut_surgery.md) |
| M5 | Measured-boot trust gate — a non-allowlisted (tampered) bitstream is refused | ✅ [docs/measured_boot.md](docs/measured_boot.md) |
| #8 pt.2 | **prjxray independently names the edited bit** (`CLBLM_R_X17Y21.SLICEL_X1.ALUT.INIT[1]`) | ✅ |
| #8 pt.1 | ICAP self-reconfig *from inside the fabric* | ⛔ hard Zynq-7 wall on this board — [docs/icap_investigation.md](docs/icap_investigation.md) |

The core migration goal is met: both XPART tracks that the Cyclone-IV physically could **not**
do — live module swap (Track A) and live single-LUT-truth-table editing (Track B) — run live on
the Zynq, with a measured-boot gate and prjxray confirming the exact edited bit. The one
deferred refinement, doing the LUT edit over **ICAP from inside the fabric** (vs PCAP), was
investigated exhaustively (custom ICAPE2 + AXI HWICAP, PS- and PL-driven) and is documented as a
hard board-specific wall.

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
