# EP4CE6 → Zynq-7010 migration: a real live Xilinx-XPART demo

## Final results (updated 2026-06-07) — project complete, hardware-verified on the EBAZ4205

The migration goal is met: both XPART capabilities that the Cyclone-IV physically could **not**
do now run **live** on the Zynq, with a measured-boot trust gate and prjxray confirming the edit.
The plan's stretch goal — the LUT-INIT edit over **ICAP from inside the fabric** — was initially
written off as a hard board wall but is now **solved** (2026-06-07), in both a PS-driven (AXI
HWICAP) and a soft-core-driven (NEORV32 → ICAPE2, no PS in the loop) flavour.

| Phase / milestone | Outcome | Evidence |
|---|---|---|
| Step 0 — toolchain | Vivado ML Standard + prjxray (xc7z010 DB) installed on WSL2 | — |
| Phase 1 — M1 (self-made bitstream) | ✅ done | PS reads PL over AXI live |
| Phase 2 — M2 (NEORV32 + 4×4 TPU) | ✅ done | PS reads `0x001E0046` |
| **Phase 3 — M3 (Track A: live DFX module hot-swap)** | ✅ **done** | `0x001E0046`↔`0x00BB00CC` via PCAP, no reset |
| **Phase 4 — M4 (Track B: live LUT-INIT surgery)** | ✅ **done** | `0x005A004D`→`0x005B004D`; `docs/lut_surgery.md` |
| Phase 5 — M5 (measured-boot trust anchor) | ✅ done | tampered bitstream refused; `docs/measured_boot.md` |
| Task #8 pt.2 — full prjxray prediction | ✅ done | prjxray names `CLBLM_R_X17Y21.SLICEL_X1.ALUT.INIT[1]` |
| Task #8 pt.1 — ICAP self-reconfig *from inside the fabric* | ✅ **done** (PS-driven HWICAP **and** soft-core-driven NEORV32→ICAPE2, no PS in the loop) | live LUT flip `0`↔`1`; `docs/icap_investigation.md` |

**Scope note vs the plan below:** the headline LUT-INIT edit (Track B / M4) was first achieved over
**PCAP** (`fpga loadbp`) — *live*, no cold boot — clearing the EP4CE6 ceiling. The *same* edit over
**ICAP from inside the fabric** (the plan's stretch goal, Task #8 pt.1) is now also done (2026-06-07):
the missing piece was handing the config-engine MUX to ICAP via `devcfg.CTRL[PCAP_PR]=0`; with that,
both AXI HWICAP (PS-driven) and a custom XBUS→ICAPE2 controller driven by the in-PL NEORV32 perform a
clean, deterministic single-frame LUT-INIT write — see `docs/icap_investigation.md`. Phase 5's trust
anchor is realized host-side (`scripts/measured-load.py`) rather than as a PS-side C program, per the
plan's "no eFUSE / keep JTAG recovery" constraint. Known un-done (low priority, orthogonal to the
XPART story): the TPU systolic array stayed 4×4 (never widened to 8×8); and ICAP *frame* read-back
isn't a clean full-frame capture — the readback **mechanism** is proven (config-register reads e.g.
IDCODE come back correct with `PCAP_PR=0`), but a full single frame exceeds the HWICAP read-FIFO
depth, so the M4 oracle byte-compare uses the observable GPIO instead (see `icap_investigation.md`).

Repo: `github.com/14sea/zynq-xpart`. See the root `README.md` results table + Build/reproduce.

---

## Context (why this)

**"XPART" = Xilinx Partial Reconfiguration Toolkit** (derived from JBits, ICAP-based runtime
fine-grained LUT/CRAM surgery, including in-chip self-reconfiguration). It is not a public product
name — this conclusion comes from this project's own docs
(`/home/test/rot_tpu_handoff/docs/notes/cyclone_cram_mapper_modeH_reply_2026_05_31.txt`,
`docs/plan.md`).

`rot_tpu_handoff` wanted two XPART capabilities on the **Altera Cyclone IV EP4CE6**:
- **Track A**: switch to a different pre-built bitstream at runtime (pick one off the SD card → load it).
- **Track B**: edit the base bitstream's **LUT truth tables** in-chip (bake quantized NN weights
  into LUTs, no recompile) — the signature JBits/XPART use case (constant folding / self-reconfig).

**EP4CE6's physical ceiling**: Cyclone IV E has **no ICAP and no partial reconfig** (Intel hardware
fact). So live-fabric XPART is physically impossible; the project could only do `mode H` = `.rbf`
LUT surgery + EPCS staging + **cold boot** ("XPART minus liveness"), silicon-validated on
2026-05-21 on a single LE (X22,Y12,N4) 0x0000→0xFFFF. LE resources were also maxed out
(`riscv_tpu_demo` 83% / `neorv32_tpu` 87% — logic density saturates first).

**Why Zynq-7010 unlocks this**: the XC7Z010 (EBAZ4205) PL is Artix-7 fabric, with **native ICAP +
PCAP + official Partial Reconfiguration / DFX**. So the "real live XPART" the EP4CE6 couldn't do
becomes feasible for the first time:
- Track A → **DFX module hot-swap** (partial bitstream, static region keeps running)
- Track B → **prjxray + ICAP** single-frame LUT-INIT live edit (the format is publicly
  reverse-engineered, and reconfiguration can be live)
- Resources: ~17,600 LUT6 / 35,200 FF / 80 DSP48E1 / 2.1 Mb BRAM — versus the EP4CE6 (6,272 LE /
  30 mult9 / 276 Kb M9K) that's ~2.7× the DSP, ~7.6× the BRAM, ~2–3× the logic, plenty to widen the
  4×4 systolic array to 8×8/16×16.

**Locked direction (user decisions)**:
1. **Scope = both, layered**: DFX as the foundation (a Reconfigurable Partition as the vehicle) +
   prjxray/ICAP LUT surgery as the headline (fine-grained edits inside the RP).
2. **Host = hybrid**: the Zynq PS (ARM Linux, reusing the existing EBAZ4205 bring-up) loads/
   orchestrates; the NEORV32 soft-core stays in the PL as the "measured RoT element". Trust anchor =
   software measured-boot (**don't touch BOOT.BIN/FSBL, don't burn eFUSE**, keep JTAG recovery).
3. **Toolchain = install Vivado ML Standard (free) locally**: confirmed XC7Z010 + DFX are in the
   free edition's support range.

**Target deliverable**: an end-to-end demo on the EBAZ4205 — ARM Linux boots → A-route loads a
"self-made full bitstream" (PS + soft-core RoT + a TPU-containing Reconfigurable Partition) →
measured-boot verifies the soft-core → (A) hot-swap the accelerator partial bit inside the RP over
PCAP → (B) bake new NN weights live into the RP's LUT-INIT over ICAP, no cold boot, no halt.

---

## Working directory and isolation principle (hard constraint)

- All new work lives in a **fresh standalone directory** `/home/test/zynq_xpart/` (its own git repo,
  fully independent of existing projects).
- Existing projects `/home/test/xilinx`, `/home/test/neorv32_tpu`, `/home/test/neorv32_rot`,
  `/home/test/riscv_tpu_demo`, `/home/test/rot_tpu_handoff`, `/home/test/EP4CE6` are **read-only
  references**: **copy** needed files into `zynq_xpart/` and edit the copies; **never modify any
  file in the source projects**.
- One-time copy-in (afterwards only the copies change):
  - Board bring-up (from `/home/test/xilinx`): `ebaz4205.cfg`, `scripts/{program-pl.sh,nand-flash.py,
    jtag-scan.sh,uart-poke.py,uboot-intercept.py}`, `buildroot-config/ebaz4205_defconfig` →
    `zynq_xpart/board/`, `zynq_xpart/scripts/`.
  - RTL/firmware to port: `neorv32_tpu/rtl/`, `riscv_tpu_demo/rtl/`, `rot_tpu_handoff/sw/stage2_loader/`
    → `zynq_xpart/rtl_src/`, `zynq_xpart/sw_src/` (copies used only as porting starting points).
- System-level tools (Vivado ML, prjxray) install outside any project dir (e.g. `/home/test/Xilinx`,
  `/home/test/prjxray`), belonging to no project.
- Directory skeleton: `zynq_xpart/{board,scripts,rtl,rtl_src,sw,sw_src,vivado,partial,docs}`.

---

## Target hardware and existing assets

| Asset | Path | Status |
|---|---|---|
| EBAZ4205 bring-up (Linux/NAND/fpgautil A-route, verified) | `/home/test/xilinx` | ✅ reusable as-is |
| Buildroot (with `BR2_PACKAGE_XILINX_FPGAUTIL`) | `/home/test/xilinx/buildroot-config/ebaz4205_defconfig` | ✅ |
| JTAG load / OpenOCD | `/home/test/xilinx/ebaz4205.cfg`, `scripts/program-pl.sh`, `scripts/jtag-scan.sh` | ✅ |
| NAND flashing (incl. mtd5 bitstream slot) | `/home/test/xilinx/scripts/nand-flash.py` | ✅ |
| RTL to port: PicoRV32+TPU | `/home/test/riscv_tpu_demo/rtl/` (soc_top.v, picorv32.v, tpu_accel.v, systolic_array_4x4.v, pe.v) | 🔁 Quartus→Vivado |
| RTL to port: NEORV32 (VHDL, with RoT) +TPU | `/home/test/neorv32_tpu/rtl/`, `/home/test/neorv32_rot/` | 🔁 |
| CRTM software (modes g/G/c/H, lutcodec, measured-boot) | `/home/test/rot_tpu_handoff/` (patches + `sw/stage2_loader/`) | 🔁 re-ground to Zynq |
| Vivado / Vitis | —— | ❌ not installed (Step 0) |

**EBAZ4205 constraints** (from `/home/test/xilinx/CLAUDE.md`): Ethernet is dead (UART only); no DIP,
fixed NAND boot; BOOT.BIN/FSBL/U-Boot stay untouched; self-made bitstreams load at runtime via the
**A-route** (`fpgautil -b` or `program-pl.sh`) without touching the original boot chain → fully
compatible with DFX's "load static full first, then hot-swap partials".

---

## Phased plan

### Step 0 — toolchain in place (prerequisite, gate)
- Free disk (Vivado ML + 7-series device support ~80–120 GB). `df -h` first; clean
  `/home/test/buildroot`, old `output/`, `tmp/`, etc. if needed.
- Install **Vivado ML Standard (free)**, selecting **only 7-series / Zynq-7000 device support**
  (saves half the space), plus `Cable Drivers`.
- Confirm `vivado -mode batch` runs under WSL; confirm no license purchase needed (DFX is included
  in the free edition).
- Install **prjxray** (clone f4pga/prjxray + 7-series DB under `/home/test`); get the `clb-lutinit`
  read chain working, confirm you can extract/write LUT-INIT bits from a known frame.
- Output: a working `vivado` + `prjxray` environment; record the env paths and `settings64.sh`.

### Phase 1 — "Hello PL": get the whole self-made-bitstream loop working first (de-risk)
*Goal: before touching DFX/ICAP, prove "a .bit I synthesized myself can run on the EBAZ4205 and be
observed".*
- New minimal Vivado project (XC7Z010-1CLG400I): Zynq PS (DDR3/UART1 on EBAZ4205 pins) + one
  AXI-GPIO LED/counter in the PL. Write the **EBAZ4205 XDC** (PS DDR/MIO from the board's existing
  config; minimal PL pins to start).
- Synthesize `system.bit`, load via the **A-route**: `zynq_xpart/scripts/program-pl.sh system.bit`
  (JTAG, local copy) or `fpgautil -b system.bit` from Linux. Observe a successful PS↔PL AXI
  read/write on `/dev/ebaz-uart`.
- Key files: `zynq_xpart/vivado/hello_pl/` (new project, all inside the standalone dir).
- **Milestone M1**: a self-made full bitstream runs live on the board; the PS can read a PL register
  over AXI.

### Phase 2 — port NEORV32 + TPU to Vivado, attach AXI to the PS
*Goal: move the EP4CE6 compute+RoT core onto the Zynq PL, as the "device under test" in the DFX
static base.*
- Pick **NEORV32 (VHDL, vendor-neutral)** as the soft-core (lowest porting cost; `riscv_tpu_demo`'s
  PicoRV32 is the fallback). Port the sources from `zynq_xpart/rtl_src/` (copies of the originals)
  into `zynq_xpart/rtl/`; the originals stay untouched.
- Quartus→Vivado porting checklist (item by item):
  - `.qsf`/SDC → **`.xdc`** constraints.
  - Altera-inferred BRAM (`altsyncram`/M9K + `.mif/.hex` init) → Xilinx **BRAM (RAMB36E1)**, init via
    `.mem`/`$readmemh` (all of IMEM ROM/DMEM/TPU LUT).
  - `(* multstyle="dsp" *)` 8×8 multiply → **DSP48E1** (`(* use_dsp="yes" *)`; the Zynq has 80, so no
    need to push a PE back to LUTs like on the EP4CE6).
  - **EPCS/`altasmi`/ALTREMOTE_UPDATE** all removed — boot/config is taken over by the PS (see Phase 3/5).
  - SDRAM controller removed — use the PS **DDR3** (soft-core memory mapped over AXI to PS DDR, or the
    soft-core uses PL BRAM + accesses the PS over AXI).
- Wrap the soft-core + TPU as an **AXI4 slave / or AXI-Lite control + AXI-master DMA**, hung off the
  Zynq PS GP/HP ports.
- While at it, widen the systolic array 4×4 → **8×8** (resources are ample; one of the "only on
  Zynq" highlights).
- **Milestone M2**: NEORV32 in the PL runs firmware, the TPU computes one MNIST tile, and the PS reads
  the result over AXI.

### Phase 3 — Track A: DFX foundation (Reconfigurable Partition + PCAP hot-swap)
*This is the "live partial reconfig" the EP4CE6 physically couldn't do, available for the first time
on Zynq.*
- In the Vivado DFX flow, make the **accelerator a Reconfigurable Partition (RP)**; the static region
  = Zynq PS interface + NEORV32 RoT + AXI interconnect.
- Build ≥2 **Reconfigurable Modules** for the RP (e.g. `rm_tpu_8x8`, `rm_alt_accel`/`rm_debug`),
  producing a full bitstream + a **partial bitstream** per RM.
- Runtime hot-swap over **PCAP**: `fpgautil -b rm_xxx.bit -f Partial` from Linux (the FPGA Manager
  partial flow; the static region and PS keep running). Wire this into the existing `nand-flash.py`/mtd
  persistence (partial bits can go in a new mtd slot or rootfs).
- **Milestone M3 (the EP4CE6 Track A equivalent)**: while the board runs, hot-switch the TPU partition
  from 8×8 to another accelerator with no interruption on the PS side.

### Phase 4 — Track B: live LUT truth-table surgery with prjxray + ICAP (headline)
*This is literal JBits/XPART — bake NN weights into LUT-INIT and change them live in-chip.*
- Put a small compute block in the RP whose **weights are carried in LUT-INIT** (continuing the EP4CE6
  mode-B "weights→LUT TT" idea; start with a constant-folding-style single/few LUTs to verify an
  observable functional change).
- Tooling: use the **prjxray 7-series DB** to locate that LUT's INIT bits in the partial frame
  (`clb-lutinit` knowledge), edit the INIT host-side → reassemble that frame's partial bitstream
  (including frame ECC/CRC handling).
- Injection over **ICAP**: instantiate **AXI HWICAP** in the PL (or a small custom ICAP controller),
  and have NEORV32/PS push the edited single-frame partial through ICAP → change the LUT truth table
  **live, no cold boot, no halt**. Can reference a VR-ZYCAP-style resource-level ICAP controller.
- This step **wholesale replaces** the EP4CE6 `lutcodec`/σ⁻¹/canon reverse-engineering with prjxray
  (the 7-series format is public, no need to fuzz CRAM yourself) — the biggest engineering reduction.
- **Milestone M4 (the EP4CE6 Track B equivalent, and live for the first time)**: with no resynthesis
  and no cold boot, edit one LUT-INIT (e.g. a weight bit) and the TPU output changes as expected;
  ICAP read-back of that frame is byte-identical to the host oracle.

### Phase 5 — trust anchor / CRTM re-grounded on Zynq
*Keep the rot_tpu_handoff security narrative, but ground it in Zynq reality with no irreversible
hardware actions.*
- **Measured-boot (software anchor, recommended)**: the PS (U-Boot/Linux) hash-measures and checks
  against an allowlist before loading full/partial bitstreams and the soft-core firmware (reuse the
  rot_tpu_handoff modes g/G/c "CRC/whitelist→load" pipeline, ported to PS-side C + the existing
  `nand-flash.py`/`fpgautil` hooks). The soft-core is the "measured RoT element" — the hash of its
  IMEM ROM image is anchored in the PS's measurement record.
- **Track B trust gate**: before any ICAP LUT edit, apply the EP4CE6 "editable-LE allowlist +
  integrity gate" idea — the PS/soft-core checks the partial frame against an allowlist and read-back
  before releasing it to ICAP.
- **Explicitly not doing**: no eFUSE burning, no Zynq hardware secure boot (RSA/AES), no touching the
  original BOOT.BIN/FSBL — the EBAZ4205 must keep JTAG recovery, and hardware RoT is irreversible with
  a bricking risk on a second-hand miner board. (A hardware-anchored variant is a separate follow-up.)
- **Milestone M5**: a soft-core image that fails measurement / a partial frame not on the allowlist is
  rejected; passing ones take effect live as normal.

---

## What's "potentially achievable" (pragmatic assessment, answering the question)

| Capability | Feasibility on Zynq | Notes |
|---|---|---|
| Self-made full bitstream runs live on EBAZ4205 (A-route) | **High** (infra verified) | M1, do first |
| NEORV32+TPU port, widen systolic to 8×8/16×16 | **High** | ample resources; VHDL soft-core is port-friendly |
| **Track A: DFX module live hot-swap (PCAP)** | **High** | officially supported, free edition; the first win the EP4CE6 couldn't do |
| **Track B: ICAP single-frame LUT-INIT live edit** | **Medium** (research precedent + prjxray format public) | main risks: partial-frame ECC/CRC recompute, ICAP controller details, single-frame boundary. Start with a minimal LUT in the RP |
| Measured-boot software trust anchor + allowlist gate | **High** | reuse existing modes pipeline, move to PS side |
| Hardware RoT (eFUSE/RSA/AES secure boot) | **Out of scope** (deliberate) | irreversible + bricking risk; separate topic |

**Overall judgment**: the migration instinct is right. Both EP4CE6 "XPART minus liveness" tracks can
be upgraded to **truly live** on Zynq, and Track B no longer needs to reverse-engineer the bitstream
format itself (prjxray already did it). The largest uncertainty is concentrated in Phase 4's ICAP
single-frame injection details — the plan uses the solid Phase 1–3 milestones as a runway to isolate
that risk to the last step.

---

## Key files (all inside `/home/test/zynq_xpart/`, zero changes to source projects)

- `zynq_xpart/vivado/hello_pl/` (M1 minimal project), `zynq_xpart/vivado/zynq_xpart/` (main project, DFX)
- `zynq_xpart/vivado/zynq_xpart/constraints/ebaz4205.xdc` (PS + PL pin constraints, new)
- `zynq_xpart/rtl/` (NEORV32 + TPU ported from the `rtl_src/` copies; `rtl_src/` is a read-only copy of the originals)
- `zynq_xpart/scripts/load-partial.sh` (wraps `fpgautil -b … -f Partial`, PCAP hot-swap)
- `zynq_xpart/scripts/icap-lut-edit.py` (host: prjxray locate INIT bits → reassemble single-frame partial → hand to the on-board ICAP injector over UART/AXI)
- `zynq_xpart/sw/measured_boot/` (PS-side measured-boot, ported from the modes g/G/c copy of `sw_src/stage2_loader/`)
- Local copies of board scripts (copied from `/home/test/xilinx`, only the copies change):
  `zynq_xpart/board/ebaz4205.cfg`, `zynq_xpart/scripts/{program-pl.sh,nand-flash.py,jtag-scan.sh,uart-poke.py}`,
  `zynq_xpart/board/ebaz4205_defconfig`
- **Explicitly not modified**: any file under `/home/test/{xilinx,neorv32_tpu,neorv32_rot,riscv_tpu_demo,rot_tpu_handoff,EP4CE6}`

## Verification (end-to-end)
- All scripts run from the local copies in `zynq_xpart/` (never call the source projects).
- **M1**: `zynq_xpart/scripts/program-pl.sh hello.bit` → PS reads an incrementing AXI-GPIO counter over UART.
- **M2**: on-board NEORV32 firmware prints over UART + a single-tile MNIST TPU result; the PS reads back a matching value over AXI.
- **M3 (Track A)**: `load-partial.sh rm_alt.bit` switches the partition at runtime; the PS workload/UART heartbeat is uninterrupted; `fpgautil` returns success.
- **M4 (Track B)**: `icap-lut-edit.py` edits one weight LUT-INIT → no cold boot, the TPU output changes as expected; ICAP read-back of that frame hash = host oracle.
- **M5**: a tampered/non-allowlisted image or partial frame is rejected by the measured-boot/allowlist gate (negative case).
- Never touches BOOT.BIN/FSBL; any brick is recovered over JTAG (`zynq_xpart/scripts/jtag-scan.sh` + `program-pl.sh`).

## References
- Vivado ML Standard (free) + DFX + Zynq-7000 support:
  <https://www.xilinx.com/products/design-tools/vivado/dynamic-function-exchange.html> ·
  <https://www.xilinx.com/products/design-tools/vivado/vivado-ml.html>
- DFX user guide UG909:
  <https://www.xilinx.com/content/dam/xilinx/support/documents/sw_manuals/xilinx2020_2/ug909-vivado-partial-reconfiguration.pdf>
- Project X-Ray (7-series bitstream / LUT-INIT): <https://github.com/f4pga/prjxray> ·
  <https://f4pga.readthedocs.io/projects/prjxray/en/latest/index.html>
- VR-ZYCAP: a resource-level ICAP fine-grained reconfiguration controller for Zynq: <https://www.mdpi.com/2079-9292/10/8/899>
- Internal basis: `/home/test/rot_tpu_handoff/docs/notes/cyclone_cram_mapper_modeH_reply_2026_05_31.txt`,
  `docs/plan.md`, `/home/test/xilinx/CLAUDE.md`
