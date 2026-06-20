# Phase 6 — M6: boot-time RoT → runtime TPU+VPU on one Reconfigurable Partition

> **STATUS: PLANNED.** Builds directly on the *done* M2 (NEORV32+TPU in PL),
> M3 (live DFX hot-swap over PCAP), and M5 (measured-boot allowlist gate).
> Nothing here needs a new mechanism — M6 is a *composition* milestone: time-multiplex
> the existing Reconfigurable Partition (RP) so it serves as the **root-of-trust at boot**
> and the **full TPU+VPU accelerator at runtime**, with the swap itself gated by the
> measured-boot allowlist.

## Goal

One sentence: **at power-on the board comes up as a measured root-of-trust; once the
chain of trust is established, the same fabric area is live-reconfigured into the full
VPU-equipped TPU — no cold boot, no PS reset.**

This is the literal "启动时 RoT，启动后切换到 TPU" request, realized as DFX time-multiplexing
of the RP plus the M5 trust gate. It also lands the *full version* of the accelerator (the
4×4 systolic array **+ a Vector Processing Unit**) that neither the EP4CE6 (area/timing
ceiling) nor the current 4×4-only RM1 carries.

## Trust model (pick A; B is the stretch)

Two ways to map "boot=RoT, runtime=TPU" onto the existing static/RP split. Both reuse M3+M5
unchanged; they differ in *where the trust anchor lives across the swap*.

### Model A — RoT stays in the static region, RP = TPU+VPU (recommended, least risk)
- **Static region** (unchanged from M3): PS7 + NEORV32 (the *measured RoT element*) + XBUS
  decode + mailbox + AXI-GPIO. The trust anchor **never leaves the fabric**.
- **Boot**: FSBL/U-Boot (NAND, untouched) → `measured-load` the **static full bitstream**
  (hash ∈ allowlist) → NEORV32 RoT runs its boot-time measurement → on pass it authorizes
  loading the accelerator.
- **Runtime**: `measured-load` the **TPU+VPU partial** into the RP over PCAP (`loadbp`) →
  `RESET_AFTER_RECONFIG` gives the accelerator a clean start → switch to inference.
- "boot=RoT, after=TPU" here is a **logical sequence**: the live RoT is the gatekeeper; the
  RP only becomes the TPU after the gate passes. Live trust anchor survives the whole time
  (can even drive M4 ICAP weight edits at runtime).

### Model B — RP itself is time-multiplexed: boot RM = RoT engine, runtime RM = TPU+VPU (stretch, reclaims area)
- The RP partition def carries **two reconfigurable modules**: `rm_rot` (a boot-time
  measurement / attestation co-processor) and `rm_tpuvpu` (the full accelerator).
- **Boot**: static brings up the *minimal* trust anchor (the existing static NEORV32 +
  `measured-load`); RP is first loaded with `rm_rot` to perform boot measurement.
- **Runtime**: once measurement passes, `loadbp` swaps the RP to `rm_tpuvpu`, **reclaiming the
  same DSP/BRAM/LUT columns** for inference. Classic *measure-then-yield*.
- Use B only if you actually want the area-reclaim story; the live trust anchor is then just
  the smaller static NEORV32. Start with A, add B's `rm_rot` as a second config later.

**Decision for M6: implement A. Leave a `rm_rot` config stub wired into the DFX flow so B is a
later drop-in (it is one extra `create_reconfig_module` + `create_pr_configuration`).**

## The full-version accelerator RM: TPU + VPU

New reconfigurable module `rtl/dfx/tpu_rp_rm_tpuvpu.v`. **Must keep the exact `tpu_rp` port
list** (XBUS slave: `clk, rst_n, xbus_{adr,dat_w,sel,we,stb,cyc,dat_r,ack,err}, dbg_leds`) so it
drops into the existing partition def with no static-side change — identical contract to
`tpu_rp_rm1_tpu.v` / `tpu_rp_rm2_alt.v`.

Internals:
- The existing `wb_tpu_accel` (4×4 INT8 systolic array, INT32 row accumulators RES0..3).
- A new **VPU** stage that consumes RES0..3 and applies, fully pipelined, the post-matmul
  element-wise ops currently done in RISC-V software: **bias add → Leaky ReLU → INT8
  requantize (multiply + arithmetic shift + saturate)**. 4 lanes to match the 4×4 array.
- New XBUS registers appended above the existing map (existing `wb_tpu_accel` offsets
  0x00 CTRL / 0x04 STATUS / 0x08 W_ADDR / 0x0C W_DATA / 0x10 X_IN / 0x14 W_DATA4 /
  0x20–0x2C RES0–3 are preserved for back-compat):

  | Offset | Name | R/W | Description |
  |--------|------|-----|-------------|
  | 0x30 | VPU_CTRL | W | [0]=vpu enable, [1]=activation (0=passthrough,1=Leaky ReLU), [2]=bias enable |
  | 0x34 | VPU_BIAS | W | per-lane INT32 bias (lane select in [1:0] of W_ADDR) |
  | 0x38 | VPU_SCALE | W | requant multiplier (INT16) |
  | 0x3C | VPU_SHIFT | W | requant arithmetic right shift amount |
  | 0x40–0x4C | POST0–3 | R | INT8 post-activation results (one per lane) |
  | 0x50 | VPU_ALPHA | W | Leaky-ReLU negative-slope shift `k`: for x<0, y = x − (x >>ₐ k) (i.e. slope = 1 − 2⁻ᵏ). `k=4` ≈ slope 0.9375; set the bit also as `VPU_CTRL[1]`. A dedicated field (not a hard-wired slope) so the oracle and tiny-tpu reference can be matched exactly. |

  **Activation note (Leaky, not plain, ReLU):** tiny-tpu's reference activation is *leaky*
  ReLU (non-zero negative slope), so the VPU here is leaky by design — `VPU_ALPHA` carries the
  slope. A plain ReLU is just `VPU_ALPHA`→very large `k` (negative region → 0). Don't hard-code
  slope=0; the M6.0 oracle compares against tiny-tpu's leaky math.

### VPU arithmetic semantics (the contract the testbench must match bit-for-bit)

The M6.0 golden oracle and the RTL must agree on every one of these, or POST0–3 won't match:

- **Datapath order**: per lane, `acc = RES_n` (INT32) → `+ VPU_BIAS_n` (INT32, wrapping add,
  no saturation at this stage) → **Leaky ReLU** (`y = x` if `x≥0` else `x − (x >>ₐ VPU_ALPHA)`,
  arithmetic shift, so negatives stay negative with reduced magnitude) → **clamp activation to
  signed 25-bit** (see next bullet) → **requantize**.
- **Activation clamp (as-built, M6.0)**: before the multiply, saturate `y` to **signed 25-bit
  [−2²⁴, 2²⁴−1]** (clamp, not wrap). This bounds the multiplicand so each lane's requant
  multiply maps to a **single DSP48E1** (25×18) → 4 VPU DSP + 16 PE DSP = **20 DSP**, exactly the
  RP pblock budget (the alternative all-LUT multiply measured 4603 LUT > the 4400-LUT pblock).
  Loss-free for the M6 INT8 forward range: a 4×4 INT8 result (|RES| ≲ 64K/group) plus a sane
  bias never approaches ±2²⁴ (~16.7M); the clamp only bites on pathological inputs (tb corner C5).
- **Requantize**: `prod = act(SIGNED 25) * VPU_SCALE(INT16)` accumulated into a **48-bit signed**
  intermediate (no truncation before the shift). Then **arithmetic right shift** by
  `VPU_SHIFT` (sign-preserving). Rounding = **round-half-up**: add `(1 << (VPU_SHIFT-1))`
  before the shift when `VPU_SHIFT>0` (and `0` when `VPU_SHIFT==0`).
- **Saturate** the shifted result to **INT8 [−128, 127]** (clamp, not wrap) → POST_n.
- Sign throughout is two's-complement; all shifts on signed values are arithmetic.

  Software contract: firmware loads weights/inputs as today, sets
  VPU_CTRL/BIAS/SCALE/SHIFT/ALPHA, pulses CTRL.start, polls STATUS.done, then reads POST0–3
  (INT8) instead of doing bias/ReLU/requant on the CPU. The legacy RES0–3 INT32 path stays
  readable for parity checks. **STATUS.done timing**: because the VPU is pipelined, `done` MUST
  only assert after the VPU stage has fully drained and POST0–3 are settled (i.e. it covers
  matmul latency **plus** VPU pipeline depth) — otherwise firmware races and reads stale POST.
  When `VPU_CTRL[0]=0` (VPU bypassed), `done` keeps its legacy matmul-only timing.

## Resource sizing (does it fit the existing RP pblock?)

The RP pblock (`vivado/dfx/pblock_rp.xdc`) covers region X1Y0: **1100 SLICE
(`SLICE_X22Y0:X43Y49`, ≈4,400 LUT6) + 20 DSP48 (`DSP48_X1Y0:X1Y19`) + ~20 RAMB36**. RM1's
bare 4×4 TPU uses 16 DSP / 1 BRAM / ~700 LUT.

| RM | DSP48 | LUT6 | Fits current pblock? |
|---|---|---|---|
| RM1 4×4 TPU (today) | 16 | ~700 | yes, room to spare |
| **rm_tpuvpu: 4×4 + 4-lane VPU (as-built, OOC synth 2026-06-20)** | **20** (16 PE + 4 VPU @ 1 DSP/lane via 25-bit act clamp) | **2799** | **yes, no floorplan change** ✅ (DSP 20/20, LUT 64%) |
| 8×8 + VPU (future) | ~64 | ~6k+ | **no** — exceeds 20 DSP in X1Y0; re-floorplan RP across 2 clock regions (XC7Z010 has 80 DSP total) |

> **Sizing note (measured).** Two extremes both miss the pblock: requant fully on DSP = 24 DSP
> (>20), fully on LUT = 4603 LUT (>4400). The shipped middle path clamps the activation to signed
> 25-bit so each VPU multiply is a single DSP48E1 → exactly 20 DSP and 2799 LUT. No `pblock_rp`
> change needed.

**M6 targets 4×4 + VPU** → the current `pblock_rp` is reused as-is. Widening to 8×8 is an
explicit non-goal for M6 (it forces a multi-region RP re-floorplan and eats most of the 80
DSPs the static NEORV32/RoT also draw from). Keep `RESET_AFTER_RECONFIG true` +
`SNAPPING_MODE ON`; keep `BITSTREAM.GENERAL.CRC Disable` only if M4 LUT-edit is still wanted on
this RP, otherwise re-enable CRC for the M6 partials.

## Boot sequence and chain of trust

```
FSBL / miner U-Boot  (NAND, never touched — JTAG recovery anchor)
  └─ measured-load  STATIC full bitstream      [sha256 ∈ allowlist?] ──no──▶ refuse (exit 2)
        └─ NEORV32 RoT (static) performs boot-time measurement
              └─ measured-load  rm_tpuvpu PARTIAL  [sha256 ∈ allowlist?] ──no──▶ refuse, fabric unchanged
                    └─ loadbp into RP  (PCAP, PS+NEORV32 never reset, RESET_AFTER_RECONFIG)
                          └─ firmware switches to VPU path → POST0–3 inference results
```

Critical property: **the swap-to-TPU is itself gated by `measured-load`** — an attacker cannot
`loadbp` a malicious accelerator, because a non-allowlisted partial is rejected before it reaches
the fabric (exactly the M5 negative case, reused). The RoT authorizes its successor.

## Phased plan (sub-milestones)

### M6.0 — VPU RTL + full-version RM, simulated  ✅ DONE (2026-06-20)
> **As-built:** `rtl/vpu.v` (4-lane, fixed 4-cycle pipeline) + `rtl/dfx/tpu_rp_rm_tpuvpu.v`
> (wraps `wb_tpu_accel` + `vpu`, keeps `tpu_rp` interface; VPU regs 0x30-0x50 claimed at the
> wrapper, RES0-3/matmul-done tapped out of `tpu_accel`/`wb_tpu_accel` via new backward-compatible
> output ports — RM1 still elaborates). Two testbenches, both green under iverilog/vvp:
> - `sim/tb_tpu_vpu.v` — VPU core vs independent golden oracle: **307/307** (5 corners
>   [leaky-neg, sat-high, sat-low, shift0, 25-bit act clamp] + M2 MNIST tile + 300 random). Bit-exact.
> - `sim/tb_rm_tpuvpu.v` — full RM over XBUS: real systolic matmul (RES=14,40,28,6) → VPU →
>   POST0-3 == oracle, plus the VPU-bypass (`VPU_CTRL[0]=0`) legacy-done path. **2/2 pass.**
> OOC synth-lint (Vivado 2025.2, xc7z010clg400-1): clean — synth OK, **0 inferred latches**,
> 0 CRITICAL, fits the RP pblock at **20 DSP / 2799 LUT** (see "Sizing note" above for the
> 25-bit-activation-clamp decision that brought DSP from 24 → 20).
> Gotcha logged: the TB Wishbone master must sample the 1-cycle `xbus_ack` on negedge and let
> `pending` register a cycle after asserting, else it latches the *previous* transaction's ack
> and drops the strobe before the slave's write cycle (writes silently never land). RTL was fine.

- Write `rtl/vpu.v` (4-lane bias/Leaky-ReLU/requant, fully pipelined) and
  `rtl/dfx/tpu_rp_rm_tpuvpu.v` wrapping `wb_tpu_accel` + `vpu`, keeping the `tpu_rp` interface.
  `vpu.v` is **written from scratch** to the "VPU arithmetic semantics" contract above; tiny-tpu
  is a *reference only* (see "Licensing / attribution" below) — no tiny-tpu RTL is vendored.
- Testbench: drive a known 4×4 matmul + bias/scale/shift/alpha; assert POST0–3 INT8 match a
  golden software requant of RES0–3. **Golden oracle** = the leaky-ReLU + requant math from
  tiny-tpu's `vpu.sv` (so our hand-written `vpu.v` is validated against a recognized
  reference), cross-checked against the bit-exact semantics above. Reuse the MNIST-tile vectors
  from M2 as the matmul stimulus.
- **Evidence**: sim log, POST0–3 == software oracle for ≥1 MNIST tile, across all four
  activation/bias/requant corners (x<0 leaky path, saturate-high, saturate-low, shift=0).

### M6.1 — DFX build with the new config
- Extend `vivado/dfx/build_dfx.tcl`: `create_reconfig_module rm_tpuvpu` + `create_pr_configuration
  config_tpuvpu`; (stub) `rm_rot` config left commented for Model B.
- impl config_tpuvpu (locked static) → produce `partial/rm_tpuvpu.bit` and refreshed static full.
- Confirm the RP still routes inside `pblock_rp` with no DRC; check DSP/LUT utilization report.
- **Evidence**: Vivado impl report (RP util within pblock), generated full + partial bitstreams.

### M6.2 — measured boot sequencer
- Add `scripts/boot-sequence.sh`: `measured-load static.bit` → (poll NEORV32 RoT "measured OK"
  over UART/AXI) → `measured-load --op loadbp rm_tpuvpu.bit`. Add both hashes to
  `board/allowlist.sha256`.
- **Evidence**: on-board log showing static-load OK → RoT measure OK → partial-load OK.

### M6.3 — end-to-end on the EBAZ4205 (headline)
- Boot the board; confirm it comes up in RoT state (mailbox/LED pattern distinct from TPU);
  run the sequencer; observe the live swap; run a firmware MNIST tile through the VPU path and
  read POST0–3.
- Negative case: a tampered `rm_tpuvpu` (one byte flipped) → `measured-load` rejects it; fabric
  stays in RoT state (M5 gate, reused).
- **Evidence**: `md 0x41200000` transition RoT-marker → inference result; `dbg_leds` change on
  swap; PS + NEORV32 UART heartbeat uninterrupted across the `loadbp`; rejected-partial log.

### M6.4 (stretch, Model B) — RP-resident RoT module
- Add `rtl/dfx/tpu_rp_rm_rot.v` (boot-time measurement/attestation engine on the `tpu_rp`
  interface) and `config_rot`; sequence RP `rm_rot` → measure → `loadbp` `rm_tpuvpu`,
  reclaiming the RP area.
- **Evidence**: RP loaded with rm_rot at boot (distinct marker), then live-swapped to rm_tpuvpu
  with PS uninterrupted.

### M6.5 (optional) — LUT-KCM weights via ICAP live-edit ("weights = reconfigurable identity")
This is the milestone where the project's ICAP/LUT live-edit work (M4/T2.2/T2.3) finally earns a
*purpose* beyond a stunt: hold the TPU weights **as LUT-INIT constants** and swap models by
ICAP-editing them live — "the chip's logic *is* the model."
- New `rtl/dfx/tpu_rp_rm_lutkcm.v`: replace the DSP-multiply PEs with **LUT constant-coefficient
  multipliers (KCM)** whose INT8 weights are baked into LUT-INIT (`DONT_TOUCH`, located by the M4
  prjxray controlled-diff method). Same `tpu_rp` interface; VPU forward path unchanged.
- Swap weights/model at runtime with `scripts/hwicap-uart.py` writeseq / `lut-surgery.py` — no
  partial rebuild, no reset.
- **Honest trade-off (so it isn't misapplied):** KCM **trades DSP → LUT**, so it *raises* LUT use —
  it is a *fit-the-theme / DSP-relief* option for **inference with static weights**, **not** a
  resource-saver, and **not** for training (per-step ICAP rewrite is far too slow — see
  `m7_plan.md`). Use it only when the "weights are part of the reconfigurable fabric" story is the
  point, or when DSPs (not LUTs) are the binding constraint.
- **Evidence**: load model-A LUTs → run inference; ICAP-edit to model-B weights live → inference
  result changes; PS/NEORV32 never reset; per-weight frame located & verified (prjxray cross-check).

## Milestone definition

**M6 (the composition):** the EBAZ4205 powers up as a measured root-of-trust; after the trust
chain is established, the **same Reconfigurable Partition is live-reconfigured into the full
4×4 TPU + VPU** over PCAP — no cold boot, no PS/NEORV32 reset — with the swap gated by the
measured-boot allowlist, and the VPU producing INT8 post-activation results (POST0–3) that match
the software oracle. A non-allowlisted accelerator partial is refused and the fabric stays in the
RoT state.

## Licensing / attribution (tiny-tpu is reference-only)

M6 **does not vendor any tiny-tpu RTL** — `rtl/vpu.v` is written from scratch to the arithmetic
contract above. But since its leaky-ReLU/requant *algorithm* is referenced from
tiny-tpu-v2/tiny-tpu, treat the result as a derivative for attribution purposes:

- **Before writing `vpu.v`, confirm tiny-tpu's license** (its repo page shows no LICENSE file at
  the time of this plan — check `LICENSE`/`COPYING` in the repo or ask upstream). If it carries
  no clear OSS license, do **not** copy code/constants verbatim — re-derive from the public
  math/docs only.
- `rtl/`, unlike `rtl_src/`, **is tracked and pushed** to the public `github.com/14sea/zynq-xpart`
  (only `rtl_src/`+`sw_src/` are gitignored). So `vpu.v` will be published — add a header comment:
  `// Leaky-ReLU + requant algorithm referenced from tiny-tpu-v2/tiny-tpu (<license>, <url>).`
- On-chip training (MSE loss / ReLU-derivative / gradient-descent — tiny-tpu's headline) is an
  **explicit non-goal for M6** (forward inference only). Those modules remain a reference for a
  possible future M7, not part of this milestone.

## Key files (all inside `/home/test/zynq_xpart/`, zero changes to source projects)

- `rtl/vpu.v` — new 4-lane bias/Leaky-ReLU/requant VPU
- `rtl/dfx/tpu_rp_rm_tpuvpu.v` — full-version RM (`wb_tpu_accel` + `vpu`), keeps `tpu_rp` interface
- `rtl/dfx/tpu_rp_rm_rot.v` — (M6.4 stretch) boot-time RoT RM
- `rtl/dfx/tpu_rp_rm_lutkcm.v` — (M6.5 optional) LUT-KCM weight PEs, ICAP-editable weights
- `vivado/dfx/build_dfx.tcl` — extend with `rm_tpuvpu` (+ `rm_rot`, `rm_lutkcm` stubs) configs
- `vivado/dfx/pblock_rp.xdc` — unchanged for 4×4+VPU (re-floorplan only if going 8×8)
- `scripts/boot-sequence.sh` — measured static-load → RoT measure → measured `loadbp` of rm_tpuvpu
- `board/allowlist.sha256` — add rm_tpuvpu (+ static) hashes
- `sim/tb_tpu_vpu.v` — VPU vs software-oracle testbench
- **Explicitly not modified**: any file under
  `/home/test/{xilinx,neorv32_tpu,neorv32_rot,riscv_tpu_demo,rot_tpu_handoff,EP4CE6}`

## Verification (end-to-end)

- **M6.0**: `vvp` sim — POST0–3 == software requant(RES0–3) for the M2 MNIST tile, matching the
  bit-exact VPU arithmetic semantics (bias→leaky-ReLU→48-bit requant→INT8 saturate) across the
  four corners (negative leaky path, saturate-high, saturate-low, shift=0).
- **M6.1**: Vivado impl DRC clean; RP utilization within `pblock_rp`; full + partial generated.
- **M6.2**: `boot-sequence.sh` log: static OK → RoT measured OK → partial OK; hashes in allowlist.
- **M6.3**: live swap with PS/NEORV32 heartbeat uninterrupted; `md 0x41200000` shows RoT-marker →
  inference result; tampered partial rejected (fabric unchanged) — the M5 negative case.
- Never touches BOOT.BIN/FSBL; any brick recovered over JTAG
  (`scripts/jtag-scan.sh` + `program-pl.sh`).

## Relationship to existing milestones

| Reused as-is | New in M6 |
|---|---|
| M3 DFX RP + PCAP `loadbp` live swap | `rm_tpuvpu` RM (TPU+VPU) as the runtime config |
| M5 `measured-load` allowlist gate | gate now sequences static→RoT→accelerator at boot |
| static NEORV32 RoT element | (Model A) it authorizes loading the accelerator |
| `pblock_rp` floorplan | unchanged for 4×4+VPU |
| M4 ICAP/LUT live-edit | (M6.5 optional) `rm_lutkcm` — weights as ICAP-editable LUT-INIT |
| — | `vpu.v` + POST0–3 register/contract; (M6.4) RP-resident `rm_rot` |

## References
- DFX time-multiplexing / partial bitstreams: UG909
  <https://docs.amd.com/r/en-US/ug909-vivado-partial-reconfiguration>
- Existing milestone docs: `docs/dfx_design.md` (M3), `docs/measured_boot.md` (M5),
  `docs/lut_surgery.md` (M4), `docs/plan.md` (master plan)
- VPU reference (post-systolic element-wise: bias / Leaky ReLU / requant): tiny-tpu-v2/tiny-tpu
  `src/vpu.sv` (+ `leaky_relu`, `fixedpoint.sv`), <https://github.com/tiny-tpu-v2/tiny-tpu>.
  **Reference-only — verify its license before copying any code/constants** (see "Licensing /
  attribution"). Note tiny-tpu is 16-bit fixed-point + its own 94-bit ISA/Unified-Buffer; M6
  keeps the existing INT8 4×4 array + NEORV32/XBUS control and only borrows the element-wise math.
