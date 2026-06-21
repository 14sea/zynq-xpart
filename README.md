# zynq_xpart — real *live* Xilinx-XPART demo on Zynq-7010 (EBAZ4205)

Migrate `rot_tpu_handoff` — which hit its ceiling on the Altera **EP4CE6** ("XPART minus
liveness": mode-H = `.rbf` LUT surgery + EPCS staging + **cold boot**) — onto the **Xilinx
XC7Z010**, and use the Zynq's native **ICAP + PCAP + Partial Reconfiguration (DFX)** to achieve,
for the first time, **live** partial reconfiguration (no halt, no cold boot).

- **Track A (foundation)**: DFX module hot-swap over PCAP — the partial bitstream applied live
  via `fpga loadbp` (U-Boot; how M3 was verified here) or `fpgautil -f Partial` (Linux); the
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
| #8 pt.1 | **ICAP self-reconfig — live LUT-INIT edit over ICAP from inside the fabric** (`0`↔`1`, no reset, no PCAP); PS-driven (HWICAP) **and** soft-core-driven (NEORV32→ICAPE2, no PS in the loop) | ✅ [docs/icap_investigation.md](docs/icap_investigation.md) |
| M6 | **Forward TPU+VPU composition** (bias→Leaky-ReLU→INT8 requant) as a DFX RM, live-swapped in (mailbox `0x1019391F`); boot-RoT→TPU Model B; **LUT-KCM** weights baked as ICAP-editable LUT-INIT (`0x1019391F`→`0x10193925` by one live CRAM-bit edit) | ✅ [docs/m6_plan.md](docs/m6_plan.md) |
| **M7.0** | **On-chip training** — the board trains XOR end-to-end (4×4 INT8 array forward + NEORV32 software backprop/SGD); host watches the loss curve fall **bit-exact to a numpy oracle** (`ep0=469→…→0`, `XOR 4/4`) via the PS mailbox | ✅ [docs/m7_plan.md](docs/m7_plan.md) |

The core migration goal is met: both XPART tracks that the Cyclone-IV physically could **not**
do — live module swap (Track A) and live single-LUT-truth-table editing (Track B) — run live on
the Zynq, with a measured-boot gate and prjxray confirming the exact edited bit. The headline
refinement, doing the LUT edit over **ICAP from inside the fabric** (vs PCAP), was first
believed to be a hard board-specific wall but is now **solved** (2026-06-07): a clean,
deterministic, reversible single-frame LUT-INIT edit runs over ICAPE2, the fabric rewriting its
own CRAM with no reset and no PCAP/`loadbp`. Two flavours work — **PS-driven** via AXI HWICAP,
and the headline **soft-core-driven** where the in-PL **NEORV32** reads the frame from a shared
BRAM and drives ICAPE2 itself (no PS in the reconfiguration loop). The one missing piece was
handing the config-engine MUX to ICAP via `devcfg.CTRL[PCAP_PR]` — see
[docs/icap_investigation.md](docs/icap_investigation.md) for the full recipe.

## Isolation principle (hard constraint)
This directory is a **standalone project**. The contents of `rtl_src/`, `sw_src/`, `board/`, and
`scripts/` are read-only **copies** taken from other projects
(`/home/test/{xilinx,neorv32_tpu,neorv32_rot,riscv_tpu_demo,rot_tpu_handoff}`). All edits happen
only inside this directory — **never modify any file in those source projects**.

## Layout
- `board/` — EBAZ4205 board config copies (`ebaz4205.cfg`, `ebaz4205_defconfig`)
- `scripts/` — bring-up script copies (`program-pl.sh`, `nand-flash.py`, `jtag-scan.sh`,
  `uart-poke.py`, `uboot-intercept.py`) plus `uboot-fpga-load.py` (this project)
- `rtl_src/` — external NEORV32 source + porting copies (read-only); **local only, gitignored** (see Build / reproduce)
- `rtl/` — ported / new Vivado RTL (this project's output, incl. `dfx/` reconfigurable modules; `xbus_icap.v` = ICAP investigation artifact)
- `sw/` — this project's firmware source: `tpu_firmware/` (the demo NEORV32 firmware, canonical copy)
- `sw_src/` — firmware build working tree (NEORV32 sw layout + `stage2_loader` copy); **local only, gitignored**
- `vivado/` — Vivado build scripts: `hello_pl/` (M1), `m2/` (M2), `neorv32_soc/`, `dfx/` (M3–M5 DFX flow + `pblock_rp.xdc`)
- `partial/` — output dir for generated bitstreams (the `*.bit` are gitignored; regenerated by the Vivado builds)
- `docs/` — `plan.md`, build/porting notes, and the milestone write-ups (`lut_surgery.md`, `measured_boot.md`, `icap_investigation.md`)

## Build / reproduce
Two dependencies are kept **out of the repo** (gitignored) because they're large upstream
trees, not project-authored code: the **NEORV32 source** (`rtl_src/neorv32_tpu/neorv32/`, used
by `vivado/dfx/build_dfx.tcl`) and the **firmware build tree** (`sw_src/neorv32_tpu_sw/tpu_test/`).
Recreate both with one idempotent helper:

```bash
scripts/setup-deps.sh          # clones NEORV32 (pinned ~v1.12.9) + picolibc patch, scaffolds firmware
```

It prints the exact `make` (firmware) and `vivado -mode batch -source build_dfx.tcl` (DFX full +
partials) commands. Details: `docs/firmware_build.md`, `sw/tpu_firmware/README.md`. Flash/observe
over UART with `scripts/uboot-fpga-load.py` + `scripts/measured-load.py`; prjxray cross-check via
`scripts/prjxray-fasm.sh` (paths overridable with `PRJXRAY=` / `XRAY_DATABASE_DIR=`).
