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

## License

Apache-2.0 (see `LICENSE` / `NOTICE`). NEORV32 (BSD-3) and prjxray/Vivado are external tools (fetched/used, not vendored).

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
| **M7.1** | **Backward `Wᵀ·δ` on the same INT8 array** (transpose-load) — full train loop bit-exact to the oracle, `XOR 4/4`. (The "post-config settle" requirement reported here was later **busted** — it was the `image_gen` layout bug in disguise; a zero-settle, zero-warm-up cold start trains bit-exact on a correct image. See docs/m7_2_dcpdiff.md FOLLOW-UP) | ✅ [docs/m7_plan.md](docs/m7_plan.md) |
| **M7.2** | **The tiny-tpu trio (loss / leaky′ / SGD) in hardware** (`train_unit.v`) + master weights — single step AND **full multi-epoch training on `rm_train`, on-board loss curve bit-exact to the oracle** (ep0 SSE=469 → ep20 SSE=277 → convergence). The 10-day "7-series-DFX in-context-routing limit" was **root-caused to a NEORV32 `image_gen` bug** (LMA alignment gap dropped when `.text % 8 == 4` → whole `.rodata` shifted −4 B in IMEM; exposed by the picolibc port, masquerading as build-dependent silicon behavior; fixed in `sw/patches/image_gen_lma_fix/`) — Vivado/DFX/XC7Z010 exonerated, flat non-DFX control + `.text%8` 9/9 prediction table + unchanged-firmware QED in the doc | ✅ [docs/m7_2_dcpdiff.md](docs/m7_2_dcpdiff.md) |
| **M7.3** | **DFX train↔infer split + measured-boot gate** — measured `loadbp` swaps `rm_train`↔`rm_tpuvpu` with the **PS/NEORV32 heartbeat uninterrupted** and a tampered partial refused; converged-seed **single HW SGD step → yield → inference `XOR 4/4`** on the learned weights, carried across the swap in static DMEM | ✅ [docs/m7_plan.md](docs/m7_plan.md) |
| **M7.3+** | **ICAP checkpoint-to-fabric** — a learned weight (`W1[0][0]` INT8 = 45) **ICAP-written into the LUT-KCM fabric's PE LUT-INIT live** (mailbox `0x1019391F`→`0x1019397F`, surgical single-lane, reversible), no PS reset; register-level ICAP `readreg` runtime attestation (full-frame CRAM readback is RF-FIFO-bounded) | ✅ [docs/m7_plan.md](docs/m7_plan.md) |
| **M7.4** | **Bigger workload — a real classifier trained on the fabric.** M7.4-tiny: 16(=4×4)→4→2 MNIST 0/1 net trained multi-epoch on-board, per-epoch curve **bit-exact to the numpy oracle** (SSE 16066→1999, acc 50%→97.5%). **M7.4-full (2026-07-02): the original 64(=8×8)→8→4 four-digit net now trains on-board too** — 60 epochs, peak 30/32 (93.8%), SSE/acc **bit-exact to oracle over every sampled epoch**. Its earlier "too big for the build band" failure was a linker bug (RAM size defaulted to 8 K, .bss/stack collision), not the fabric — see docs/m7_2_dcpdiff.md FOLLOW-UP | ✅ [docs/m7_2_dcpdiff.md](docs/m7_2_dcpdiff.md) |
| **M7.5.1** | **A whole trained weight TILE ICAP-baked into the LUT fabric** — the 16 INT8 weights of M7.4's first converged L1 tile written live into `rm_lutkcm` (mailbox `0x1019391F`→`0x7F7FE57F`, bit-exact to the VPU model), reversible, attested; PS/NEORV32 never reset (scales M7.3+ from one weight to a full tile) | ✅ [docs/m7_plan.md](docs/m7_plan.md) |
| **M7.5.2** | **Single-session train → checkpoint-to-fabric → infer loop** — one power-on, no reset: the chip trains the net (`rm_tpuvpu`), publishes its learned tile (host verifies == oracle), live `loadbp`-swaps to `rm_lutkcm`, ICAP-bakes those learned weights into its own LUT logic, and computes with them (`0x1019391F`→`0x7F7FE57F`), then attests | ✅ [docs/m7_plan.md](docs/m7_plan.md) |
| **M7.5.3-lite** | **The WHOLE 2-layer classifier on one folded LUT-KCM tile** — a 4→4→2 net time-folded onto a single tile (spatial whole-net doesn't fit: one tile = 80.8% of the RP LUTs), ICAP-baking L1 then L2; **40 held-out digits classified bit-exact to the oracle** (`0xB12DC5B8`/`0xB2002D3E`), PS/NEORV32 never reset. Closed-loop tile-probe handshake, no RTL change | ✅ [docs/m7_plan.md](docs/m7_plan.md) |

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

## Known-good tool versions
The flows were developed and hardware-verified against these versions (others may work; these are the tested baseline):

| Tool | Version | Notes |
|---|---|---|
| Vivado | **2025.2** | DFX flow (`vivado/dfx/build_dfx.tcl`); `/home/test/Xilinx/2025.2/Vivado/bin/vivado` |
| NEORV32 | **v1.12.9** | `hw_version_c = 0x01120900`; pinned in `scripts/setup-deps.sh` + `sw/patches/image_gen_lma_fix/` auto-applied. **Intentionally frozen — do not upgrade**: all published silicon results (and every baked ICAP frame/LUT artifact) are bound to this version; new projects should start from current NEORV32 instead (post-2026-04-28 objcopy flow needs no patch) |
| RISC-V GCC | **`riscv64-unknown-elf-`** | firmware cross-compile (`RISCV_PREFIX=`) |
| picolibc | system pkg | linked via `-specs=picolibc.specs`; setup-deps applies the errno-guard patch |
| Python | **3.12.3** | host oracles + bring-up scripts (`/home/test/xilinx/.env`, numpy) |
| prjxray + DB | f4pga | `/home/test/prjxray` + `/home/test/prjxray-db` (LUT-INIT bit location for ICAP edits) |
| Board / boot | EBAZ4205 (XC7Z010) | original miner U-Boot, autoboot break key `d`; load via `fpga loadb`, not Linux fpgautil |

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
