# Phase 7 — M7: on-chip training (backprop) — the chip learns by itself

> **⚑ 2026-07-02 ROOT-CAUSE UPDATE:** every mention below of the M7.2 multi-epoch
> "7-series-DFX in-context-routing limitation / build lottery / good size band" is
> **RETRACTED** — the real cause was a NEORV32 `image_gen` bug (LMA alignment gap
> dropped when `.text % 8 == 4` → `.rodata` shifted −4 B in IMEM; picolibc port
> exposed it). With the fix, **M7.2 multi-epoch training on `rm_train` is
> hardware-verified bit-exact to the oracle** (ep0 469 → ep20 277 → convergence).
> Full evidence chain + fix: docs/m7_2_dcpdiff.md "ROOT CAUSE (2026-07-02)";
> fixed tool tracked at sw/patches/image_gen_lma_fix/. **Same-day follow-up: the
> M7.1 "wall-clock settle" is BUSTED (zero-settle cold start trains bit-exact on a
> correct image) and M7.4's "size band" was a second real bug — the linker's RAM
> size defaulted to 8 K (never defsym'd) → .bss/stack collision for the MNIST
> firmware; with `--defsym,__neorv32_ram_size=16384` the full 64→8→4 MNIST now
> trains on-board bit-exact (peak 93.8%). See dcpdiff FOLLOW-UP section.**

> **STATUS: M7.0–M7.3+ DONE & hardware-verified; M7.4 host bit-exact, M7.4-tiny (16-4-2) HW-verified
> on-board bit-exact (2026-06-28).** Builds on M2
> (NEORV32 + 4×4 INT8 systolic array), **M6** (the VPU: bias / Leaky-ReLU / requant forward path),
> M3 (live DFX hot-swap), and M5 (measured-boot gate). M7 is the first milestone that is **not**
> pure inference: it closes the loop and runs the **backward pass + weight update on the board**, so
> the EBAZ4205 trains a tiny network end-to-end with **no host doing the math**. tiny-tpu-v2/tiny-tpu
> is the algorithmic **reference** for the three new pieces (MSE loss, Leaky-ReLU derivative,
> gradient descent) — **reference only, no RTL vendored** (same policy as M6, see "Licensing").
>
> **M7.0 result:** on-board XOR training converges — the host watched the loss curve fall
> (`ep0=469 → ep160=14 → … → 0`, **bit-exact to the numpy oracle at every sampled epoch**) and
> `XOR 4/4, final SSE=0` via the PS mailbox. Forward `W·x` on the 4×4 INT8 array, all of
> loss/δ/outer-product/SGD in NEORV32 software (the QAT hybrid: Q8.8 master, INT8 forward view).
> No new RTL — reuses the M6 `rm_tpuvpu` RM with the VPU bypassed. Code: `sw/m7_train/`,
> `sim/oracle_train.py`, `scripts/m7-watch-loss.py`.

## Goal

One sentence: **the board trains a small MLP from scratch using on-fabric forward + backward
passes and on-fabric weight updates — the headline demo is XOR converging on the EBAZ4205 with
the host only feeding data and reading the loss curve.**

This lands tiny-tpu's actual differentiator (on-chip *training*, the thing inference-only TPUs and
the EP4CE6 design never had) on top of our DFX + measured-boot + live-reconfig stack.

## Why training is genuinely harder than M6 (the three hard problems)

M6 was a forward-only composition. Backprop introduces three problems M1–M6 never faced. The plan
below is organized around solving them, cheapest-risk first.

### Problem 1 — the transpose Wᵀ (turns out to be cheap on *our* array)
A 2-layer net (the minimum for XOR) needs the input-gradient `δ_prev = Wᵀ · δ` to push error to the
previous layer. On a generic weight-stationary array transposing W is the classic pain point. **But
our array loads weights serially by `(w_row_sel, w_col_sel)` and computes `result[i] = Σⱼ W[i][j]·x[j]`
(see `rtl/systolic_array_4x4.v`).** So computing `Wᵀ·δ` is just **loading the same weights with row/col
select swapped** (`W[j][i]` into PE`[i][j]`) and feeding `δ` as the activation vector — *no new
datapath, no second array*. M7 exploits this: the array is reused for **all three** matmuls
(forward `W·x`, input-grad `Wᵀ·δ`, and — see Problem 3 — the weight-grad outer product).

### Problem 2 — training numerics: INT8 is not enough (precision strategy = QAT-style hybrid)
Pure INT8 weight updates don't converge: a single SGD step `W -= lr·dW` quantizes to **zero** because
the gradient·lr is far below 1 LSB of INT8. This is exactly why tiny-tpu uses **16-bit fixed-point**.
We **keep the INT8 forward array** (so M6/M2 stay valid) and adopt the standard
**quantization-aware-training (QAT) split**:
- **Master weights** live in **higher precision** (Q8.8 / INT16, or INT32 accumulator) in BRAM.
- Gradients accumulate into the **master** copy at full precision.
- The forward matmul uses an **INT8 quantized view** of the master weights (round + clamp) loaded
  into the array — identical to the M2/M6 INT8 datapath.
- The activation/delta path (`δ`, loss grad) is carried in the same Q-format as the master weights.

This is the single most important M7 decision and it is **made**: hybrid QAT, INT8 forward + INT16/Q8.8
master. We do **not** widen the systolic array to 16-bit (that would break the M6 contract and blow
the DSP budget — see sizing).

### Problem 3 — gradient storage + the weight-grad outer product
`dW = δ ⊗ xᵀ` (rank-1 outer product, `dW[i][j] = δ[i]·x[j]`) and the master-weight update need writable
high-precision storage the LUT-baked M4 path **cannot** provide. **M7 weights live in BRAM/registers,
not LUT-INIT** — the M4 ICAP/LUT-edit stunt is *orthogonal* and explicitly not used here (you would
otherwise be doing an ICAP frame write per SGD step, which is absurd). The outer product itself is 16
MACs for 4×4; it is cheap enough to start in NEORV32 software and later fold onto the array (load `δ`
stationary, stream `x`).

## Math we implement (per training step, 2-layer leaky-MLP, MSE loss)

```
Forward:   z1 = W1·x + b1 ;  h = leaky(z1)
           z2 = W2·h + b2 ;  y = leaky(z2)
Loss:      L  = ½·Σ (y − t)²                          (MSE)              ← tiny-tpu loss
Backward:  δ2 = (y − t) ⊙ leaky'(z2)                                     ← tiny-tpu relu-deriv
           dW2 = δ2 ⊗ hᵀ ;  db2 = δ2
           δ1 = (W2ᵀ · δ2) ⊙ leaky'(z1)              ← transpose reuse (Problem 1)
           dW1 = δ1 ⊗ xᵀ ;  db1 = δ1
Update:    W ← W − lr·dW ;  b ← b − lr·db             (on master weights) ← tiny-tpu grad-descent
```
`leaky'(z) = 1 for z≥0, else 2⁻ᵏ` — the same `VPU_ALPHA` shift `k` as M6's forward leaky ReLU, so the
forward and backward activations are consistent by construction.

## New hardware vs software split (staged — start SW-heavy, then offload)

The array does the heavy matmuls; everything element-wise can start in NEORV32 firmware and migrate
to hardware once convergence is proven. This staging is the de-risking spine of M7.

| Op | M7.0–7.1 (prove it) | M7.2+ (offload) |
|---|---|---|
| forward `W·x`, `W·h` | **array** (M2/M6) | array |
| input-grad `Wᵀ·δ` | **array** (transpose-load) | array |
| weight-grad `δ⊗xᵀ` | NEORV32 SW | array (δ stationary) |
| loss `½Σ(y−t)²`, `dL/dy` | NEORV32 SW | HW `loss` unit (ref tiny-tpu) |
| leaky' gate | NEORV32 SW | HW in VPU (ref tiny-tpu) |
| weight update `W−=lr·dW` | NEORV32 SW (master in BRAM) | HW `grad_descent` unit |
| training loop / lr schedule | NEORV32 firmware (always) | firmware |

## New XBUS registers (appended above the M6 map; M6 used through 0x50)

Existing 0x00–0x14 (matmul ctrl) / 0x20–0x2C (RES0–3) / 0x30–0x4C (VPU) / 0x50 (VPU_ALPHA) are
**preserved** for forward back-compat.

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x54 | TRAIN_CTRL | W | [0]=train enable, [1]=transpose-load mode (load Wᵀ), [2]=accumulate-grad, [3]=apply-update |
| 0x58 | LR_SHIFT | W | learning-rate as arithmetic right-shift `s`: `W −= dW >>ₐ s` (power-of-two lr, avoids a divider) |
| 0x5C | TARGET0–3 | W | per-lane INT/Q target `t` for the loss/δ computation (lane in W_ADDR[1:0]) |
| 0x60–0x6C | DELTA0–3 | R/W | per-lane δ (Q-format); R after a backward matmul, W to seed the output-layer δ |
| 0x70 | LOSS | R | accumulated MSE loss for the current batch (Q-format) — read for the convergence curve |
| 0x74–0x7C | WMASTER_LO/HI window | R/W | windowed read/write of the **master** high-precision weights (debug + checkpoint) |

Software contract: firmware sets weights/inputs/target, runs forward (M6 path), reads `y`/`LOSS`,
seeds `DELTA`, toggles `TRAIN_CTRL` transpose-load + accumulate + apply per the math above, polls
`STATUS.done` (which, as in M6, must cover the full pipeline drain). Loop over samples/epochs in
firmware.

## Phased plan (sub-milestones)

### M7.0 — fixed-point training oracle + bring-up in firmware (no new RTL) — ✅ DONE & hw-verified
- Pure NEORV32-software backprop using the **existing M6 forward hardware** for `W·x` only; loss,
  δ, outer product, update all in C with a chosen Q-format (Q8.8 master, INT8 forward view).
- Host-side **numpy fixed-point reference** (`sim/oracle_train.py`) — the golden oracle. A portable-C
  twin (`sw/m7_train/train_xor.c`) shares one kernel (`m7_kernel.h`) with the board firmware
  (`sw/m7_train/main.c`); the only thing that differs is `array_macc()` (plain C on host, the 4×4
  array XBUS sequence on board). Host-seeded init + sample order are baked from the oracle
  (`m7_vectors.h`) — no on-board RNG.
- **Evidence (achieved):** host C bit-exact to the oracle (weights + full 4000-epoch loss curve,
  XOR 4/4, SSE=0). **On board:** the loss curve published progressively to the PS mailbox
  (`0x41200000`) and watched live (`scripts/m7-watch-loss.py`) — `ep0=469, ep20=274, … ep160=14,
  … 0`, **bit-exact to the oracle at every sampled epoch**, ending `XOR 4/4, final SSE=0`
  (mailbox `0x80040000`). So the board reproduced the oracle's loss *trajectory*, not just the
  endpoint. **Finding:** NEORV32 `uart0` is not pinned out on this board (`dfx_top.v`), so the
  mailbox is the only PS-visible channel; the loss curve goes through it, not `printf`.

### M7.1 — array reuse for `Wᵀ·δ` (transpose-load) — ✅ DONE & hw-verified (2026-06-21)
- Backward input-grad `Wᵀ·δ` now runs on the **same 4×4 INT8 array** as the forward pass, via a
  **software transpose-load**: load `Wi[i][j] = quant(W2[j][i])` into the existing `array_macc` and feed
  `δ` as the activation (`m7_w2t_delta` in `sw/m7_train/m7_kernel.h`). No new RTL — the hardware
  `TRAIN_CTRL[1]` row/col-swap load is deferred. Forward `W·x` is on the array too; loss/δ/outer-product/
  SGD stay in NEORV32 software (the M7.0 split).
- **Evidence**: host bit-exact to the oracle (`make -f Makefile.host check`), and on the EBAZ4205 the
  full loss curve is **bit-exact to the oracle at all 19 sampled epochs** (ep0=469 ep20=277 … ep180=4
  ep400..3600=0) ending **DONE `0x80040000` = XOR 4/4, final SSE=0**. Allowlisted settle build:
  full-static `14180df3…`, partial `1c813005…`.

#### ⚠️ The post-config settle gotcha (the hard part of M7.1) — and how it was diagnosed
Bringing M7.1 up on real silicon exposed a deterministic on-board failure that does **not** reproduce
in functional simulation. Documented here in full because it will bite any later milestone (M7.2+) that
starts compute immediately after `fpga loadb`.

- **Symptom.** Training that begins right after the PL is configured **diverges from epoch 0** with
  *deterministic, byte-identical* garbage (board ep0=5726, ep20=45343, …, never reaches XOR 4/4 — the
  loss "bounces" forever). Identical across independent rebuilds, so not a place-and-route lottery.
- **It is NOT an RTL bug.** `sim/tb_m7_transpose.v` drives `wb_tpu_accel` with the *exact* firmware
  `array_macc` bus sequence over 7 cases — dense, transpose, negative weights, three back-to-back calls,
  the exact zero-row pattern `[[5,6,7,8],0,0,0]·[1,1,1,1]→[26,0,0,0]`, and a worst-case *fill all four
  lanes = 400 then a zero-row* — and passes **7/7**. The `tpu_accel` `CTRL[4]` accumulator clear and the
  `!bulk_active` ready-gating (which stalls the bus through the 3-cycle weight bulk-load so no write is
  dropped) are both correct and have been in the bitstream since the Phase-2a port. So the array logic
  is sound.
- **It is NOT a stale/cold-array problem either.** A settle-diagnostic firmware re-ran a self-check macc
  *and* a mixed-sign/zero-row macc every ~5 s, comparing the hardware accumulators against an in-firmware
  plain-C recompute of the same matmul (no host golden needed) and publishing the match to the mailbox.
  Result: **isolated `array_macc` reads back correct from very early (a few seconds after config) all the
  way through** — there is no "garbage window" for standalone maccs.
- **The cure is wall-clock TIME, not warm-up count.** Two controlled rebuilds settled it:
  - a **pure-count** warm-up — 256 dummy maccs back-to-back (<10 ms), then train — still **diverged**
    (DONE = XOR 2/4);
  - the same/fewer maccs **spread over ~130 s** (the diagnostic) → training then ran **bit-exact**.

  256 maccs in 10 ms fails while ~60 maccs over ~130 s succeeds ⇒ elapsed time is the active ingredient.
  The predictor "is there a real pre-training delay?" matched **every** on-board build: the 5 with no
  delay (3 original + the clean no-probe + the 256-macc pure-count) all diverged; the 3 with a delay (the
  early probe build, the ~130 s diagnostic, and the shipped settle build) all converged — **8/8**.
  (Per-call `hw_flush`, a dummy zero-macc before every real one, does **not** help: it adds maccs, not
  time.) Mechanistically the first SGD step lands on a bad matmul, corrupts the Q8.8 master weights, and
  the run never recovers even once the array is "good" — which is why the settle must happen **before the
  first weight update**, not merely before the first matmul.
- **How small is the minimum? Measured ~1–2 s (a single-boot settle-time sweep).** A throwaway sweep
  firmware ran 64 trials in one boot, each = fresh `m7_init` + a START marker + a short 40-epoch probe
  train, publishing the probe's epoch-39 SSE; the host timestamps each trial's start (T since config) and
  compares the SSE to the oracle's `losses[39] = 285` (match ⇒ that trial was settled). Across two boots
  **every catchable trial converged** — the earliest caught (~5 s after config) and all later ones, zero
  divergence. Turn latency stopped me catching the very first trials (T≈0–4 s), so the exact floor isn't
  nailed, but since the *only* diverging builds had ~0 s pre-train delay and every sweep trial (incl. the
  first, with just a ~1 s pre-train hold) converged, the true minimum is **~1–2 s**. So the original
  45 s was ~20–40× conservative.
- **The fix (shipped).** `sw/m7_train/main.c` runs 16 warm-up maccs **plus an `M7_SETTLE_ITERS` (~10 s)
  busy-wait before the training loop** — a comfortable margin over the ~1–2 s measured minimum (reduced
  from 45 s after the sweep; re-verified that FULL 4000-epoch training stays bit-exact at 10 s). `hw_flush`
  is retained as harmless belt-and-suspenders.
- **Open root cause.** Why isolated maccs are correct within seconds but *training* needs a (small) settle
  before the first SGD step is still not understood. Candidates: FCLK0/PLL jitter settling, a config-time
  power-rail droop, or DFX decoupling release — all plausible for a ~1–2 s window. Pinning the mechanism
  (vs just the timing, now measured) would need a scope on FCLK0 or XADC on-die temperature/voltage.
- **Tooling gotcha worth keeping.** A background watcher whose own command line contains the string it
  greps for (`until ! pgrep -f uboot-fpga-load`) **matches itself**, so the wait-loop never exits and the
  watcher hangs producing no output. Match a more specific pattern or use a PID file.

### M7.2 — hardware loss / leaky' / weight-update units (the tiny-tpu trio) — ⚠️ LOGIC DONE & hw-verified (single-epoch); multi-epoch blocked by a build-dependent post-config array instability (2026-06-22)
- `rtl/train_unit.v`: MSE loss + `dL/dy`, leaky-ReLU derivative gate, and `grad_descent`
  (`W −= dW >>ₐ LR_SHIFT` on the master copy). Written from scratch to the math above; tiny-tpu
  `src/{loss,leaky_relu,gradient_descent}.sv` are the **reference only** (license caveat below).
- **Scope decision (made):** trio + the 2-4-1 XOR master weights (17 Q8.8 vals, a register file)
  in HW; the rank-1 outer products `δ⊗xᵀ` stay a 16-MAC NEORV32 sequence; the two matmuls stay on
  the 4×4 array (M7.1); forward requant+bias+leaky stays SW (no M7.1 regression). The DFX RM is
  `rtl/dfx/tpu_rp_rm_train.v` (array + train_unit, **no VPU** — the train↔infer time-mux counterpart
  of `rm_tpuvpu`). Key impl note: `leaky'(z)` is a power-of-two slope, so `qmul(x, leaky'(z))` is a
  rounding **shift**, not a multiply → train_unit needs only **1** DSP (the `err²` MSE term); total
  17/20 in `pblock_rp`, fits with margin (the original 64×64 `qmul` blew DSP to 52; also narrowed the
  clamp/loss datapath 64→32-bit to fit slices).
- **Verified bit-exact in simulation:** `sim/tb_train.v` (train_unit vs the oracle golden, 64 samples:
  LOSS + d2 + d1 + post-update master); `sim/tb_rm_train.v` (the wrapper bus path with a Wishbone
  master); `sw/m7_train/train_xor_hw.c` (the whole HW/SW split, modelled, runs 4000 epochs bit-exact:
  weight mism=0, loss-curve 0/4000, XOR 4/4, SSE=0). `oracle_train.py --dump-tu` emits the golden trace.
- **Verified on the EBAZ4205 (diag2 firmware, results via the PS mailbox):** train_unit master
  read/write ✓, `loss_d2` known-input → LOSS=256 ✓, leaky'+δ → D2=256 ✓, SGD-update → 999 ✓, array
  forward RES=14 ✓, and a **real full epoch-0** (`m7_epoch_hw`, all of forward + loss + δ + update in
  HW) → **loss = 469, bit-exact to the oracle**. So the trio, the forward, the update, and the master
  all work correctly on real silicon for a single training step.

#### ⚠️ OPEN: multi-epoch training diverges on `rm_train` — a build-dependent post-config array instability
The single-epoch result is correct, but the full multi-epoch loop **diverges** on hardware (loss
collapses to ~0 by ep20 instead of following the oracle 469→…→277).

> **UPDATE (2026-06-22) — TIMING DEFINITIVELY RULED OUT; root cause is a firmware-binary-sensitive
> CPU↔array access-timing interaction (a latent array handshake race), NOT timing closure or routing.**
> A 3-build verification settled it: the failing diag3 was re-place/routed two ways — RM-only (impl_8,
> `verify_reroute.tcl`) and full static (impl_1+impl_8, `static_reroute.tcl`), with timing-driven
> directives (ExtraTimingOpt + AggressiveExplore + phys_opt). **WNS improved 0.103 → 0.334 → 0.567 ns
> (5× range), WHS 0.024 → 0.041 ns, recovery/removal all MET — yet every build produced BIT-IDENTICAL
> wrong forward `{-5,-3,-8,-3}` and identical divergence.** A timing/routing marginality would give
> *different* failures per route, not identical ones across a 5× margin spread. Furthermore the forward
> **source AND compiled machine code** are byte-identical between the working diag2 and the failing
> diag3 (`objdump` diff of m7_forward/m7_matmul/array_macc/hw_flush = identical) — so the only remaining
> variable is the firmware **binary context** (diag3 has more surrounding code). Working hypothesis: the
> larger diag3 image shifts instruction addresses → different NEORV32 **icache** hit/evict pattern during
> the forward → the `array_macc` XBUS access sequence (notably the W_DATA4 bulk-load FSM that stalls the
> bus 3 cycles, vs the CTRL=0x01 compute-start, vs the STATUS.done/RES read) lands at different relative
> cycles → exposes a **latent race/fragility in the wb_tpu_accel handshake** → wrong RES → wrong forward.
> This matches the M7.1 "direct array_macc correct but kernel forward returns garbage" symptom (the
> wall-clock settle papered over it there; here on rm_train it surfaces and settle does not help). **So
> the next-session fix target is the array access protocol / icache, NOT clock↓ (which timing-ruled-out
> makes irrelevant).** Verification tooling kept: `vivado/dfx/{verify_reroute,static_reroute}.tcl`.
>
> **Redirected next-session plan:** (1) rebuild diag2's exact firmware → confirm reproducibly correct
> (isolate "binary context" as the variable); (2) bisect diag2→diag3 to find the code addition that flips
> the forward (likely a size/layout threshold tripping the icache); (3) **key experiment** — disable the
> NEORV32 icache and/or add explicit delays / extra STATUS polling / fences between the weight-load,
> compute-start, and RES-read in `array_macc`; if any cures it, the access-timing race is confirmed;
> (4) audit the `wb_tpu_accel`/`systolic_array_4x4` handshake for a window where fast back-to-back XBUS
> accesses can start compute before the bulk weight-load drains or read RES before done.

Earlier (now-superseded) diagnosis framing — a **post-config instability of the array in the `rm_train`
bitstream**, NOT a logic bug:
- The *identical* forward code that returns the oracle's `y[0]={19,2,10,-1}` in the **diag2** build
  returns wrong `{-5,-3,-8,-3}` in the **diag3** build — same RP netlist (`rm_train_synth_1` reused),
  different static (different firmware/IMEM → different full bitstream). So the array's post-config
  correctness is **build-dependent**.
- It is **deterministic per build**: two independent re-`fpga loadb` of the same diag3 bitstream both
  give the same wrong forward → not a per-load metastable lottery, but tied to the specific build.
- It is **NOT cured by settle time**: diag3 ran two trajectories, a 3 s and a 15 s post-config settle,
  and **both diverged identically**. (The M7.1 wall-clock-settle cure does not work here.)
- It is **NOT a logic bug**: `tb_train` is bit-exact through 16 epochs, the host twin through 4000, and
  diag2's single on-board epoch is exactly 469. A board divergence by ep20 with proven logic ⇒ a HW
  effect.
- This is the same *class* as the M7.1 "post-config settle" symptom (root cause left open there —
  FCLK0/PLL jitter, config-time rail droop, or DFX decoupling release), but worse on `rm_train` and not
  time-curable. The `rm_train` RP swaps the VPU for `train_unit` (master register file + a DSP); its
  routing/boundary context near the RP partition pins differs per static build, which plausibly tips a
  marginal config-time transient. Candidate next steps (untried): `loadbp`-reconfigure the RP after the
  full load; a more aggressive array re-init/clear before training; an explicit RP reset sequence in
  `dfx_top`; or a hardware-side check (Type-C supply margin, scope FCLK0/PLL lock, XADC rail/temp).
- **Diagnostic tooling kept** for the follow-up: `sw/m7_train/diag.c` (train_unit probe), `diag2.c`
  (forward + update + real-epoch), `diag3.c` (multi-epoch trajectory, two settle lengths). Build with
  `make APP_SRC=diag.c … install` then rebuild the static; results decode off mailbox `0x41200000`.
- **Status:** M7.2 RTL/firmware/sim are complete and committed; the headline "full multi-epoch training
  on `rm_train`, loss curve bit-exact" awaits resolving this hardware instability.

#### 🎯 ROOT-CAUSE CLASS FOUND (2026-06-23 session) — it is a binary-SIZE → bitstream-IMPLEMENTATION effect on the array, NOT firmware / icache / cadence / timing
A focused session of on-board experiments (icache OFF throughout most; board stayed at live U-Boot the
whole time — after `fpga loadb` the PS stays in U-Boot so each new build is just flush+`loadb`, no
power-cycle) **eliminated every CPU/firmware-side hypothesis and proved the fault is purely a function of
the firmware binary's SIZE, via the implemented bitstream**:

1. **icache disable — NEGATIVE.** `neorv32_soc_dfx.vhd ICACHE_EN=>false`, rebuilt the full `main.c`
   trainer → still diverges (ep0≈0, XOR 2/4). And `diag3`'s forward is **byte-identically wrong
   `{-5,-3,-8,-3}` with icache ON *and* OFF**. ⇒ the d732268 "icache cadence" hypothesis is **wrong**;
   icache is eliminated. (DFX rebuild measured ~4 min, not the ~30 min feared — synth_1+impl_1+impl_8
   reusing the `rm_train` OOC synth.)
2. **diag2 (SMALL binary, .text 4912 / .rodata 1348) — ALL CORRECT:** forward y[0]={19,2,10,-1} ✓,
   train_unit SGD=999 ✓, **real epoch-0 loss = 469 BIT-EXACT** ✓. So the RTL (array + train_unit) and
   the single-epoch path are perfect.
3. **diag3 (LARGE binary, .text 5404 / .rodata 5348 ≈ main.c class) — forward WRONG `{-5,-3,-8,-3}`,**
   epoch-0 loss 1, ep5/ep20→0; a 5× longer settle (run B) does NOT help. SGD=999 ✓. The wrong r0–3 are
   the *isolated cold forward* (no training, no loop, runs first, byte-identical code to diag2 per
   objdump) — so the bug is the array forward itself, build-dependent.
4. **Firmware serialize array_macc — NEGATIVE.** Rewrote diag3's `array_macc`/`hw_flush` to fully
   serialize every bus access (fence + dummy `TPU_STATUS` read [gated by `!bulk_active` → stalls past the
   W_DATA4 bulk-load drain] + SPIN slack between phases) → forward STILL `{-5,-3,-8,-3}`. ⇒ the
   handshake / access-cadence-race hypothesis is **also eliminated**. (Note: the W_DATA4 early-ACK window
   is already covered by tpu_accel's `!bulk_active` write-gating — no lost writes — so the firmware-visible
   protocol was robust all along.)
5. **Memory overflow — RULED OUT (host-side):** `riscv64-...-size -A` on all three ELFs: .text+.rodata
   ≪ 32 KB IMEM, .bss 256, stack ≪ 16 KB DMEM. No clobber.
6. **🎯 INERT-PADDING — DECISIVE.** `sw/m7_train/diag2pad.c` = the WORKING diag2 + ~4.6 KB of pure dead
   padding (`__attribute__((used)) const uint8_t PAD_RO[4400]` → .rodata + 3 dead `pad_fn*` → .text +
   a `pad_consume()` called ONLY *after* r0–3 are computed, so it cannot touch them). Sizes pushed into
   the failing class (.text 5180 / .rodata 5748). **The forward flipped from the correct {19,2,10,-1} to
   the SAME {-5,-3,-8,-3} failure** (train_unit still 999). ⇒ **Pure inert binary growth — zero
   forward-logic change — reproduces the bug.** It is a binary-size→bitstream-P&R effect.

**Mechanism:** the `rm_train` OOC synth is reused, so the array **logic + DSP-pipeline inference is
identical across builds**; the difference is purely impl-time **place+route** of that fixed netlist,
driven by the larger static (a larger firmware grows IMEM ≈6.3 KB→2 RAMB36 vs ≈11 KB→3 RAMB36, perturbing
the static placement/routing around the RP). A P&R-only change that flips function **with timing MET**
(consistent with d732268's 5×-WNS-spread / identical-failure result) points to an **unconstrained /
structural path** — a false/multicycle path, GSR/reset-release, or a static-side net rerouted through the
RP region — not a setup/hold violation. The systolic **array** miscomputes (returns ~0 → small requant →
{-5,-3,-8,-3}); **train_unit is always fine** (register file + 1 DSP, no cycle-aligned cascade).

**Tried and FAILED as a fix:** `set_property CONTAIN_ROUTING true [get_pblocks pblock_rp]` — rebuilt
main.c (routing succeeded, Unrouted=0) → still diverges identically. Likely because CONTAIN_ROUTING only
keeps the RP's *own* routing inside the pblock; it does not keep *static* routing/feeds (the XBUS into the
RP, or static nets crossing the region) out of the pblock area.

**NEXT (un-run; decreasing confidence — do the diagnostic before more blind fixes):**
- **(a) DCP DIFF (recommended diagnostic):** open the routed `impl_8` of a GOOD (diag2-size) vs BAD
  (main/diag2pad-size) build, report on the systolic-array nets (16 PE psum/x cascades + DSP48
  placement/cascade) to SEE exactly what shifts. No board; ~2 Vivado opens. This actually pins the
  mechanism instead of guessing.
- **(b) PIN THE ARRAY:** fixed LOC/DSP-site constraints (and/or lock a known-good RP route from the diag2
  DCP) so the array place+route is identical regardless of static size; rebuild at main.c size → if it
  converges, placement-sensitivity confirmed + fix in hand.
- **(c) Pragmatic pivot:** diag2 single-epoch on `rm_train` is perfect, so M7.3 (rm_train↔rm_infer DFX +
  gate) can be built on the verified single-step, documenting the full multi-epoch curve as a known issue.

**Repro/tooling kept:** `sw/m7_train/diag2pad.c` (inert-padding repro), the diag2/diag3 mailbox-tag
decoders (host scratchpad). All other experimental source (ICACHE=false, +CONTAIN_ROUTING, serialized
diag3) was **reverted to the d732268 baseline** after the session.

### M7.3 — DFX train↔infer split + measured-boot gate  ✅ DONE & HW-VERIFIED (2026-06-27, Tier-1 + Tier-2)
- Package **two** DFX reconfigurable modules on the **same `tpu_rp` interface**:
  `rtl/dfx/tpu_rp_rm_train.v` (array + training, no inference VPU) and the M6
  `rm_tpuvpu`/`rm_infer` (array + VPU, no train_unit). This is the **recommended structure** — it
  both tells the train-then-yield story **and** solves the LUT-pressure ⚠️ (peak = max not sum; see
  "Reducing M7 resource"). A monolithic mode-selected RM is the fallback only if the swap latency
  ever matters (it doesn't for XOR).
- `measured-load` gates **both** RMs (allowlist entries); the RoT authorizes loading the trainer,
  then authorizes the inference module. After convergence, `loadbp`-swap `rm_train → rm_infer`
  carrying the **just-learned weights** as initial BRAM contents — measure-then-yield (M6 Model B).
- **Evidence**: on-board — boot → RoT measured OK → `measured-load` trainer → XOR converges live
  (`LOSS` register decreasing over UART) → swap to `rm_infer` → inference on the learned weights →
  PS/NEORV32 heartbeat uninterrupted across both `loadbp`s; tampered partial rejected (M5 negative
  case, reused).

#### M7.3 status — DECISION (a) taken (2026-06-27)

**Path decision (deferred from M7.2 close):** take **(a) — build the swap+gate on the
verified single-step path**, NOT (b) hunt for a lucky-route multi-epoch bitstream. Rationale:
M7.2 proved live multi-epoch convergence on `rm_train` is a build-dependent 7-series-DFX
in-context-routing defect with no standard fix on XC7Z010; (b) is stochastic and unbounded.
(a) demonstrates the *whole* M7.3 mechanism with every on-fabric compute step being one that
M7.2 already proved bit-exact.

**Honest headline under (a) — the "converged-seed single-step" demo:** since a single SGD
step can't *reach* an XOR solution but *can* be made bit-exact, seed `rm_train`'s master with
the **already-converged** weights from `sim/oracle_train.py` (host-known), run **one verified
HW SGD step** on top (loss already ≈0, weights stay converged), publish the resulting Q8.8
master over the PS mailbox `0x41200000`, `loadbp`-swap to `rm_infer`, feed it the handed-over
weights, and show **XOR 4/4** on the *learned* weights. Every fabric op is single-shot/verified;
the full live LOSS-decreasing curve is documented as the known M7.2 limitation, not claimed.

**Two tiers, built bottom-up:**
- **Tier 1 — MECHANISM (no firmware rebuild; uses already-built bitstreams).** measured-load
  gates both RMs, `loadbp` swaps `rm_train ↔ rm_tpuvpu`, PS/NEORV32 heartbeat survives both,
  tampered partial refused. Driver: `scripts/m73-demo.py`. Needs only the allowlist entry
  (added 2026-06-27: `partial-RM_TRAIN-trio`, sha `c1c76feb…`, impl_8) + a board session.
- **Tier 2 — WEIGHT HANDOFF (needs new firmware + one IMEM-rebake).** `rm_train` firmware:
  seed converged master → 1 HW SGD step → publish master to mailbox → signal READY_TO_YIELD.
  `rm_infer` firmware (from `sw/tpu_vpu_firmware`): read the handed-over weights instead of the
  hardcoded `load_weights()`, run the XOR forward, publish XOR-score. Both IMEM images bake into
  the static via Vivado, then re-hash into the allowlist.

**Reused as-is:** M3 `loadbp`, M5 `measured-load.py` + allowlist, M6.4 measure-then-yield,
`rm_train`(cfg8/impl_8) + `rm_tpuvpu`(m6_out) bitstreams, `m7-watch-loss.py`,
`sim/oracle_train.py` (source of the converged seed). **New:** `scripts/m73-demo.py` (Tier 1,
done); Tier-2 firmware variants + handoff (next board session).

**Tier-1 HW-VERIFIED on EBAZ4205 (2026-06-27).** Live-silicon run, board stayed in U-Boot
across every `loadbp` (no PS reset):
1. `fpga loadb` today's `impl_8/dfx_top.bit` (full static + rm_train, built 13:21) →
   PS in U-Boot, mailbox `0x41200000` publishes `b0fffffb` → RP alive.
2. `measured-load` rm_train partial (`c1c76feb…`) → gate **PASS** (`partial-RM_TRAIN-trio`)
   → `loadbp` → RP alive.
3. NEGATIVE: 1-bit-flipped rm_train partial (`18579378…`) → gate **REJECT**
   ("Refusing to load an unmeasured/tampered bitstream") → fabric never touched.
4. `measured-load` today's rm1_tpu partial (`dfb7209b…`, same impl_1 static, loadbp-compatible)
   → gate **PASS** → `loadbp` **SWAP** rm_train→rm1_tpu → mailbox tags advanced
   `b0→b2→b3→b5` = static NEORV32 **heartbeat survived** the RM swap. Reverse swap back to
   rm_train also gated+OK. ⇒ the M5 gate + DFX measured-swap + heartbeat machinery is proven
   on hardware. (NOTE: today's impl_8 is a M7.2 *bad-class* build — its cold forward is the
   wrong `-5` signature — which is irrelevant to the mechanism tier; Tier-2's correct-compute
   demo needs a clean rebuild.) Allowlist += `partial-RM1-TPU-m73static` (`dfb7209b…`).

**Tier-2 HW-VERIFIED on EBAZ4205 (2026-06-27) — the full path-(a) headline.** Firmware
`sw/m7_train/m73_yield.c` (one static NEORV32 image, dual-phase), clean DFX rebuild
`build_dfx.tcl` (impl_1 static + impl_5 rm_tpuvpu + impl_8 rm_train, one consistent static),
host driver `scripts/m73-yield-demo.py`. Live run, PS/NEORV32 never reset:
1. gated `loadb` full `6b97e62e…` (`full-static+RM_TRAIN-M73yield`) → Phase 1 on rm_train:
   seed the train_unit master with the oracle's converged Q8.8 weights → ONE HW SGD step
   (forward W·x + backward Wᵀ·δ on the array, trio in train_unit) → publish the learned
   model. **Learned W2 row0 + b2 = `382 45 475 288 / -59` — BIT-EXACT to the oracle golden**
   (the array's single step is verified on silicon). → READY_TO_YIELD.
2. pre-yield inference on rm_train → **XOR 4/4** (preds 0110).
3. gated `loadbp` swap rm_train→rm_tpuvpu (`0dd009c0…`, `partial-RM_TPUVPU-M73yield`) — the
   measured yield. The learned weights live in static DMEM and survive the RP reconfig.
4. post-yield inference on **rm_tpuvpu** → **XOR 4/4 sustained** (12/12 mailbox reads over 14 s),
   PS `md` heartbeat responsive throughout. ⇒ train (1 verified step) → measured yield →
   infer XOR 4/4 on the learned model, computed by the swapped-in RM, no PS reset.

**Historical note, superseded by the 2026-07-02 root cause.** Build 1 of this firmware came up
with the old bad signature (array forward garbage → the 1 SGD step saturated the master to
`-32768`). Stripping dead `neorv32_uart0_printf` (NEORV32 uart0 is not pinned out — printf was
invisible and bloated IMEM; `.text` 7372→5988) made Build 2 (`m73_yield.c`, mailbox-only)
bit-exact. This was originally read as an informed P&R re-roll; the later `image_gen` finding
shows it was a firmware-layout dependency. Allowlist carries the build-2 hashes (`6b97e62e`
full / `3198d966` rm_train / `0dd009c0` rm_tpuvpu); build 1 superseded.

### M7.3+ — ICAP checkpoint-to-fabric + runtime attestation  ✅ DONE & HW-VERIFIED (2026-06-27)
"The chip trains, then writes its learned weights into its own logic, live." After M7
learns the XOR weights, **ICAP-bake a learned weight into the LUT-KCM inference fabric**
(M6.5 `rm_lutkcm`: the 16 INT8 weights are `dont_touch` LUT6 INIT[0]s — the logic *is*
the model) and attest the running fabric — reusing M4/M6.5/T2.2 ICAP with **zero new RP
resource**. Single-tile `rm_lutkcm` is one 4×4 layer, so this checkpoints ONE learned
weight end-to-end (the full 2-layer XOR can't fit one tile — the honest scope).

**Locate (the clean controlled-diff).** A param-rebuilt w45 RM does NOT give a clean diff:
changing the baked WEIGHT re-synths the KCM netlist → the whole RP re-places (≈147k bytes
differ). The fix: edit the INIT in the **routed checkpoint**, not the RTL — `open_checkpoint
impl_7/dfx_top_routed.dcp`, `set_property INIT 64'h1` on the PE[0][0] weight LUT6s for the
bits that change (1→45 = set bits 2,3,5; `vivado/dfx/m73p_edit_init.tcl`), `write_bitstream`.
Same placement, so the partial differs by **only the 3 INIT bits** (14 config bytes).
prjxray `bitread -y` of baseline vs edited → the exact changed bits:
`bit_004019a2_087_15/31` (bits 2,3) and `bit_00401a20_081_15` (bit 5) — 3 bits in 2 frames.

**Write (live ICAP, no reset).** One `writeseq` **per frame**, each a complete
sync..DESYNC 233-word envelope (`scripts/hwicap-build-frameseq.py`, == the M6.5.2 proven
size). **Hard-won lesson: do NOT put two FAR-sets in one envelope** — the buffered frame
mis-commits to the new FAR and corrupts the array (mailbox went all-saturated `0x7F7F7F7F`;
cleared by a full `loadb`). Two separate writes are clean.

**Evidence (live silicon, PS/NEORV32 never reset).** Board on the impl_7 LUT-KCM static
(`tpu_vpu_firmware`, mailbox `0x1019391F` = PE[0][0]=1). devcfg `PCAP_PR`←0; ICAP healthy
(SR=0x5, WFV=0x3f). `writeseq` frame 0x004019a2 then 0x00401a20 → PE[0][0] 1→45 (the learned
`W1[0][0]` INT8) → mailbox **`0x1019391F` → `0x1019397F`**: only POST0 (lane 0) changed
`0x1F→0x7F`, lanes 1–3 unchanged (`0x39/0x19/0x10`) = a SURGICAL single-weight edit
(`result[0]` 14→102 = 45·2+1·3+1·4+1·5, VPU-requant saturates lane 0). **Reverse** ICAP-write
the baseline frames → mailbox back to `0x1019391F` exactly = bidirectional, reversible.
**Attestation**: ICAP `readreg` IDCODE `0x13722093` + STAT `0x46106ffd` (read path alive,
config healthy) before/after — the register-level runtime attestation. (Full-frame CRAM
readback is **not** reliable here — the HWICAP RF-FIFO can't hold a 202-word frame; the
runtime check is register-level + the **functional** attestation that the mailbox reflects
the written weight + the M5 complement: the edited fabric ≠ any allowlisted partial.)

Artifacts: `rtl/dfx/lutkcm_array_w45.v` (locate variant), `vivado/dfx/m73p_edit_init.tcl`,
`scripts/hwicap-build-frameseq.py`, `vivado/dfx/m65_icap/m73p_*.seq.bin` (the four proven
write sequences: w45 + baseline, two frames each), build_dfx `build_m73plus` flag.

### M7.4 (stretch) — bigger workload
- Train a small **MNIST tile** classifier, multiple forward/backward passes. 4×4 array → tile/loop
  in firmware.
- **Evidence**: on-board accuracy climbing across epochs on a held-out tile; matches numpy oracle.

**Design locked (host convergence sweep, 2026-06-27).** Net **64(=8×8) → hidden 8 → 4** (digits
0–3); MSE on one-hot targets, leaky ReLU. Built on the **M7.1 path** (forward W·x AND backward Wᵀ·δ
both on the INT8 4×4 array via transpose-load, NEORV32 SW does loss/δ/outer-product/update) — NOT
the M7.2 `rm_train` HW-trio (its multi-epoch is the known 7-series-DFX in-context-routing break).

Key decisions from the sweep:
- **Mini/full batch is the enabler.** Per-sample SGD is *dead* in fixed point (single-sample
  `dW >> LR_SHIFT` underflows to 0 → stuck at chance 25%). **Full-batch GD** (accumulate all 128
  grads in INT32, one saturating master update/epoch: `W -= (ΣdW·LR_MUL) >> LR_SHIFT`) gives a
  smooth *monotonic* climb (last-10 test-acc std 0.000) and the simplest firmware (no shuffle, no
  baked order).
- **INT8 quant costs ~nothing** at full batch: forward+backward `int8`==`q88` to the bit in the
  sweep, so the whole matmul path stays on the fabric.
- **Per-layer activation scale.** Inputs stored 6-bit (`x_q88 = xi8<<2`, XSHIFT=2); the hidden
  layer spans a wider range so its INT8 view needs a bigger downshift (**XSHIFT_H=3**) to avoid
  saturating at 127 — this alone lifted the honest INT8 ceiling from ~80% to ~92%.
- Config: `K=2, WSHIFT=DSHIFT=2, XSHIFT=2, XSHIFT_H=3, LR_SHIFT=9, LR_MUL=1, seed=3, 60 epochs,
  train=128/test=40`. Dataset = MNIST 0–3 area-pooled 28×28→8×8, host-seeded subset baked into the
  header (~12 KB const, fits NEORV32 IMEM 32 KB).

**HOST DONE & bit-exact (2026-06-27).** `sim/oracle_mnist.py` (numpy fixed-point oracle, models the
array faithfully) trains test-acc **25% → 90% (peak 92.5%)**, SSE monotonic 33064→8136. The shared
kernel `sw/m7_train/m7_mnist_kernel.h` (tiled 4×4 matmul; `array_macc` the only HW call) + host twin
`mnist_host.c` reproduce it **bit-exact**: weight mism 0, loss 0/60, acc 0/60. `data/mnist/` fetched
via `scripts/fetch-mnist.sh` (OSSCI S3 mirror, gitignored); golden header committed so the build
needs no re-download. Run: `make -C sw/m7_train -f Makefile.host mnist`.

**ON-BOARD FOLLOW-UP (2026-07-02, EBAZ4205, rm_tpuvpu via `fpga loadb`): DONE after the
linker-RAM fix.** The earlier 2026-06-28 attempts were misdiagnosed as the same build-dependent
failure as M7.2. Re-reading the evidence after the `image_gen` fix found the real cause:
`neorv32.ld` defaulted `__neorv32_ram_size` to 8 KB although the RTL DMEM is 16 KB, so the full
MNIST firmware's `.bss` and stack collided inside `m7_epoch`. Firmware `sw/m7_train/main_mnist.c`
(XBUS `array_macc` + `m7_mnist_kernel.h`, per-epoch `(epoch, test_correct, SSE)` over the PS
mailbox; decoder `scripts/m7-watch-mnist.py`) now builds with
`--defsym,__neorv32_ram_size=16k`. The failed bring-up still usefully established, in order:
- NEORV32 boots (50 MHz core), the chunked post-config settle runs (a single ~30M busy loop hung on
  some builds — a codegen/placement quirk — so the settle was chunked with interleaved volatile MBOX
  writes, which is reliable), `m7_init` completes.
- the 4×4 array computes correctly: single MAC and a **200-MAC burst** both return the golden
  `RES=14`; i64 math, `m7_forward` (tiled `m7_mm` + quant + TRAIN_X rodata read) and the transpose
  matmul all pass in isolation.
- but entering the heavy `m7_epoch` loop **resets** the CPU with **no caught exception** on the
  build whose array was good; a later, smaller build's array instead **hung on the first MAC**.
  DMEM was raised 16→32 KB to rule out stack overflow — it did not change the outcome.

⇒ The 4×4 array was not the limiting factor. With the linker RAM size set to the actual 16 KB DMEM,
the original 64→8→4 MNIST build trains for 60 epochs on-board: peak 30/32 (93.8%), final 28/32,
and every sampled SSE / accuracy point matches the numpy oracle.

#### M7.4-tiny — the on-board run, DONE & HW-VERIFIED (2026-06-28)

Original strategy: step the net down from the ~14 KB MNIST firmware to
**16(=4×4) → hidden 4 → 2 classes** (MNIST digits 0 vs 1, area-pooled
28→4). This tiles onto the 4×4 array with no vertical tiling — L1 `W1[4][16]` = **4 horizontal passes**,
L2 `W2[2][4]` one tile. Same kernel, same Q8.8/INT8 math, same M7.1 path; only the dimensions and the
baked dataset (4× smaller: 16 vs 64 int8/sample) differ.

- **Host (bit-exact).** `sim/oracle_tiny.py` (`--sweep-lr` picked `LR_SHIFT=7`: monotonic SSE
  16066→1999, final test_acc 0.975 / peak 1.000). `tiny_host.c` reproduces it bit-exact (weight/loss/
  acc mism 0/0/0). Run: `make -C sw/m7_train -f Makefile.host tiny`.
- **Kernel fix.** `m7_mm`'s 4×4 tiling assumed every dim a multiple of 4 (true for 64-8-4). The tiny
  net's `NOUT=2` made the backward transpose matmul read `W2` cols 2,3 and `di8[2,3]` out of bounds,
  corrupting layer-1's gradient → now **zero-pads lanes beyond NR/NC** (a no-op for MNIST, regression
  re-checked 0/0/0).
- **Firmware.** `sw/m7_train/main_tiny.c` = `main_mnist.c` baking the tiny vectors. `.text` **8104 B**
  vs MNIST 13908 B (~42% smaller). This size distinction explained the old false lead, but the
  later M7.4-full result shows the real blocker was linker RAM sizing, not a good/bad route band.
- **On-board (EBAZ4205, rm_tpuvpu via `fpga loadb`, PS left in U-Boot).** Built one DFX
  (`build_dfx.tcl` impl_1 static + impl_5 rm_tpuvpu), loaded the full `dfx_top.bit`. The full multi-epoch curve, read
  per-epoch over the PS mailbox (`scripts/m7-watch-mnist.py --golden m7_tiny_vectors.h`), is
  **bit-exact to the oracle**: SSE 16066→1999 monotonic, test acc climbing 50%→97.5% (peak 100%),
  every sampled epoch SSE & ok-count == oracle, DONE = peak 40/40, final 39/40, SSE 1999
  (mbox `0xa82707cf`). (The per-epoch dwell is chunked + re-published so the slow `md` poller samples
  every epoch; ~13 s/epoch wall-clock.)

⇒ **M7.4 is HW-VERIFIED on-board.** The tiny classifier proved the first on-board MNIST training path;
the same-day full result above supersedes the old size-band interpretation and brings the original
64→8→4 classifier on-board too.

### M7.5.1 — checkpoint the TRAINED tile into the LUT fabric via ICAP  ✅ DONE & HW-VERIFIED (2026-06-28)
"The chip trains a classifier, then writes its learned weights into its own logic, live." Closes the
M7.4-tiny → M7.3+ loop: take the FIRST 4×4 tile of M7.4-tiny's converged layer-1 weights — the INT8
view of `W1[0:4][0:4]` = `[[3,11,16,12],[2,2,-4,-3],[2,13,13,15],[-4,16,15,12]]` — and ICAP-bake all
16 into the `rm_lutkcm` PE array (each weight = 8 `dont_touch` LUT6 INIT[0]s), live, **no reset**.
This scales M7.3+ from ONE synthetic-ish weight to a full tile of 16 genuinely-trained weights.

**Tooling (generalises M7.3+).**
- `sim/m75_predict.py`: derives the tile and predicts the on-board mailbox via the exact M6 VPU model
  (bias → leaky `y = z>=0 ? z : z-(z>>>α)` → requant). Reproduces baseline `0x1019391F`; the trained
  tile → **functional golden `0x7F7FE57F`** (POST=[127,-27,127,127]; lanes 0/2/3 saturate on the
  larger trained weights, lane 1 = -27 is the non-saturated signed proof).
- `vivado/dfx/m75_edit_tile.tcl`: sets all 16 PE weight-LUT6 INITs in the ROUTED impl_7 `rm_lutkcm`
  dcp → clean controlled-diff partial (readback-verified 16/16).
- `scripts/m75-build-frameseqs.py`: multi-frame generalisation of `hwicap-build-frameseq.py`. The
  16-weight edit flips ~48 INIT bits across **18 config frames**; this anchors each frame in the RAW
  config stream by the prjxray `(word,bit)` set (raw extraction keeps the real per-frame ECC; the
  frame data appears twice in the partial, so an exact bit-level match pins the right copy), emits one
  233-word sync..DESYNC envelope per frame (the one-FAR-per-envelope M7.3+ rule), self-checks each
  frame's bit-diff == prjxray. 18/18 OK; reverse (restore-baseline) seqs too.

**Evidence (live silicon, PS/NEORV32 never reset).** Board on impl_7 (rm_lutkcm baseline, rebuilt with
`tpu_vpu_firmware` static); baseline mailbox `0x1019391F`. devcfg `PCAP_PR`←0 (`mw 0xF8007000
0x4400e07f`); ICAP healthy (SR=0x5, WFV=0x3f), `readreg 12`=`0x13722093`. Stream the **18 forward
frames** (`hwicap-uart.py writeseq`, SR=0x5 throughout — clean, no corruption) → mailbox
**`0x1019391F` → `0x7F7FE57F`**, bit-exact to the corrected VPU model = the 16 trained weights now
physically compute in the fabric. **Attestation**: `readreg 12`=`0x13722093` + `readreg 7` STAT
=`0x46106ffd` (config healthy, read path alive). **Reverse**: stream the 18 baseline frames → mailbox
back to **`0x1019391F`** exactly = bidirectional, reversible. `PCAP_PR`←1 restored.

⇒ M7.5.1 HW-VERIFIED: a full tile of on-board-**trained** weights checkpointed into the running LUT
fabric, live, bit-exact and reversible, attested. (Single-tile `rm_lutkcm` holds one 4×4 layer — 16 of
the 72-weight net; baking the whole 16-4-2 net needs a larger LUT-KCM fabric = the M7.5.3 stretch.)

### M7.5.2 — single-session train → checkpoint-to-fabric → infer loop  ✅ DONE & HW-VERIFIED (2026-06-28)
The full autonomous loop in ONE power-on session, **PS/NEORV32 never reset**: the chip trains a
classifier, hands off its learned weights, reconfigures its own inference fabric, bakes those weights
into its LUT logic via ICAP, and computes with them — then attests. Unifies M7.4-tiny (train),
M7.3's dual-phase swap (m73_yield.c), and M7.5.1 (ICAP checkpoint) under ONE static.

**Why it's tractable / honest.** M7.4-tiny training is deterministic (host-seeded, full-batch, no
board RNG), so the converged tile is known a priori (= M7.5.1's) and the ICAP frames are
precomputable. The honesty: the firmware publishes the board's ACTUAL trained tile over the mailbox
and the host verifies it **== the oracle/the bytes being baked** BEFORE baking.

**Pieces.**
- `sw/m7_train/m752_loop.c`: ONE static firmware, `.text` 8048 B. Phase 1 (rm_tpuvpu):
  train the 16-4-2 net, publish a brief curve + the converged `W1[0:4][0:4]` INT8 view (16 values,
  tags 0xE0..0xEF) + `READY` (0x600D0000). Phase 2 (rm_lutkcm, post-swap): VPU path (no weight load —
  baked weights compute) publishing `{POST3..POST0}`.
- `vivado/dfx/build_dfx.tcl` `build_m752` flag: build impl_1 (m752 static) + impl_5 (rm_tpuvpu) +
  impl_7 (rm_lutkcm) — both RMs on the SAME static, so the loadbp swap is live.
- `scripts/m752-watch.py`: fast-polls the mailbox through phase 1, decodes the curve + 16 tile
  values + READY, verifies the board-trained tile == oracle.
- ICAP frames regenerated from THIS build's impl_7 routed dcp (`m75_edit_tile.tcl` +
  `m75-build-frameseqs.py`): **19 frames** this build (vs M7.5.1's 18 — P&R placement differs), all
  self-checked.

**Evidence (live silicon, one session, no reset).** ① loadb impl_5 (m752+rm_tpuvpu) → Phase 1 trains:
curve SSE 16066→1999, test acc 20/40→39/40, then publishes the tile. ② host reads the 16 weights =
`[3,11,16,12,2,2,-4,-3,2,13,13,15,-4,16,15,12]` = **oracle exactly** → READY → "safe to checkpoint".
③ loadbp impl_7 rm_lutkcm partial (live RP swap under the running NEORV32) → mailbox `0x1019391F`
(baseline baked weights, phase-2 VPU loop). ④ PCAP_PR←0, ICAP-bake the 19 trained frames →
mailbox **`0x1019391F` → `0x7F7FE57F`** (bit-exact to the VPU model = the board's learned weights now
compute in the LUT fabric). ⑤ attest IDCODE `0x13722093` + STAT `0x46106ffd`; PCAP_PR←1.

⇒ M7.5.2 HW-VERIFIED: train → extract(+verify) → live DFX swap → ICAP checkpoint → infer → attest, end
to end on the EBAZ4205 in a single session with no reset. (Still one tile = partial first layer; a
whole-net hardwired classifier is M7.5.3.)

### M7.5.3-lite — WHOLE net classified on one folded LUT-KCM tile  ✅ DONE & HW-VERIFIED (2026-06-29)
**Fit check first (why "lite").** A spatial whole-net LUT-KCM does NOT fit XC7Z010 — measured on the
routed impl_7 dcp: **one 4×4 LUT-KCM tile = 3557 LUTs = 80.8% of the RP pblock's 4400** (each PE is a
full editable 8×8 multiplier, ~180 LUTs; the weight can't be constant-folded or ICAP-editing it would
do nothing). The 16-4-2 net's 72 PEs would need ~3× the whole chip. So **time-fold** instead: shrink
the input to 2×2=4 px so L1 `W1[4][4]` and L2 `W2[2][4]` each = ONE tile, and run the forward as two
array passes over the SAME tile, ICAP-baking it to the trained W1 then W2. Every weight of the 2-layer
classifier is computed in hardwired, ICAP-editable LUT logic.

**Pieces.** `sim/oracle_m753.py` (4-4-2, 2×2-pool MNIST 0/1, test_acc 92.5%) + `m753_vectors.h` (test
set, biases, both INT8 tiles, golden classifications). `sw/m7_train/m753_infer.c` (.text 3.4 KB):
two-phase batched inference — wait for L1 bake, compute all hidden acts, A_DONE, wait for L2 bake,
classify, publish the 40-bit bitmap. `vivado/dfx/m753_edit_tile.tcl` (parameterised tile editor),
`scripts/m753-demo.py` (host orchestrator), built via `build_dfx.tcl` `build_m73plus` (impl_1 m753
static + impl_7 rm_lutkcm).

**Closed-loop handshake (no host→board channel, no RTL change).** The board can't be told when a bake
is done, and fixed-time windows are fragile (an early build deadlocked: `0xDEAD`). Instead the board
**probes the tile with x={1,1,1,1} and waits until the raw RES equals that layer's row-sums**
(L1→{-5,71,-7,-4}, L2→{30,18,0,0}; baseline→{4,10,8,2}, all distinct) — i.e. until the host's ICAP
bake has landed; the host waits for the board's `A_DONE` before baking L2. The wait heartbeat carries
an **incrementing low-16-bit counter** (`0x5A1Axxxx`/`0x5A2Axxxx`) so two reads prove the loop is live,
not hung.

**Two bugs found & fixed on silicon.**
1. *L2 must be the L1→L2 diff, not baseline→L2.* The tile holds L1 when L2 is baked; a baseline→L2
   frameseq leaves frames that L1 touched (but where L2==baseline) stuck at L1 → corrupt L1/L2 mix,
   probe never matches. Fix: bake L2 = diff(L1_partial, L2_partial).
2. *Bake before verifying ICAP.* `PCAP_PR`←0 then **verify `readreg 12`==`0x13722093`** before baking
   (a suppressed-error bake into PCAP-owned config silently does nothing).

**Evidence (live silicon, PS/NEORV32 never reset).** loadb impl_7 → board probes, waits. `PCAP_PR`←0,
IDCODE healthy → ICAP-bake L1 (20 frames) → board detects, computes layer 1, `A_DONE` with hi8[0]
spot-check `[1,6,0]` == oracle → ICAP-bake L1→L2 (19 frames) → board classifies all 40 test digits →
mailbox **`0xB12DC5B8` / `0xB2002D3E` == golden bitmap exactly (40/40 == oracle, bit-exact)**.
`PCAP_PR`←1. Fully automated end-to-end via `m753-demo.py` (PASS).

⇒ M7.5.3-lite HW-VERIFIED: the whole 2-layer classifier's weights all pass through hardwired,
ICAP-baked LUT logic, the layers time-folded onto a single tile, classifying a held-out test set
bit-exact to the oracle — the spatial whole-net being a documented XC7Z010 fit limit.

## Resource sizing (does it still fit the RP pblock?)

The 4×4 INT8 forward array (16 DSP) is unchanged. Training adds, in the RP:
- **Master-weight + activation BRAM** (Q8.8/INT16): a 2-layer XOR net is tiny (≤ a few hundred
  16-bit words) → well under 1 RAMB36.
- `train_unit` (loss/leaky'/update): a handful of adders/multipliers — the requant/update multiplies
  can be LUT or share the existing DSP column; **no extra DSP pressure** at 4×4.

| Config | DSP48 | LUT6 | BRAM | Fits `pblock_rp` (X1Y0: 20 DSP/≈4.4k LUT/~20 RAMB36)? |
|---|---|---|---|---|
| M6 rm_tpuvpu (4×4 + VPU) | ~16–20 | ~2.5–3k | ~1 | yes |
| M7 **monolithic** (4×4 + VPU + train_unit, all resident) | ~16–20 | ~3.5–4k | ~2 | tight on LUT — watch the impl report ⚠️ |
| **M7 split via DFX (recommended — see below)** | ~16–20 | **~2.5–3k peak** | ~2 | **yes, comfortable** ✅ |
| 8×8 trainer (future) | ~64 | >6k | — | no — re-floorplan across clock regions |

### Reducing M7 resource with **our DFX method** (the LUT-pressure fix)

The monolithic row is tight because it pays for **inference logic + training logic at the same
time**. They are never needed simultaneously, so use the project's core capability — **DFX
time-multiplexing of the RP** — to make peak resource = `max(train, infer)`, not their sum. This is
exactly the "measure-then-yield / area-reclaim" pattern (M6 Model B), now applied to train↔infer:

- **`rm_train`** (loaded while learning): 4×4 array + leaky + **leaky′ + loss + grad/update** +
  master BRAM. **No inference requant VPU** (POST0–3 path absent). 
- **`rm_infer`** (loaded after convergence): 4×4 array + **VPU requant → POST0–3** (the M6 path),
  initialized with the just-learned weights. **No train_unit.**
- Live-swap `rm_train → rm_infer` over PCAP `loadbp` once `LOSS` plateaus — PS/NEORV32 never reset.

Because each config drops the half it doesn't use, **each fits the existing `pblock_rp` with margin
and no re-floorplan** — the tight ⚠️ row above goes away. This is "our DFX method" used where it actually
saves area (time-multiplex two large mutually-exclusive datapaths), and it folds naturally into the
M7.3 train-then-yield story.

**Three more LUT-savers (cheapest first), all consistent with the staged plan:**
1. **Keep element-wise + weight-update in NEORV32 software** (loss, δ, outer-product, SGD) — the
   NEORV32 lives in the **static region, costs zero RP LUT**. For XOR (tiny) the speed hit is
   irrelevant. This shrinks/eliminates `train_unit` in the RP entirely; only the systolic array +
   minimal glue stay in `rm_train`. (This is already M7.0/M7.1 — keeping it through M7.3 is the
   resource-minimal option; move pieces to HW only if a workload needs the throughput.)
2. **Push all training state to BRAM, not FF/LUTRAM** — master weights, activations, δ, momentum.
   BRAM is abundant here (~20 RAMB36) while LUTs are the bottleneck. Trade the tight resource for
   the plentiful one.
3. **Share the DSP column for the update multiply** instead of LUT multipliers — DSP has headroom
   (16–20 of 20) while LUTs don't; time-share the array's DSPs for `lr·dW` when the array is idle
   between matmuls.

> **Note — why NOT LUT-bake the weights (LUT-KCM) here:** baking weights into LUT-INIT (the M4/ICAP
> trick) **trades DSP→LUT**, which makes the *tight* resource (LUT) **worse**, and per-step ICAP
> rewrites are far too slow for training. LUT-KCM is great for the M6 *inference* identity story
> (`m6_plan.md` §M6.5) but is the **wrong tool for shrinking M7's LUT footprint** — DFX time-mux +
> SW-offload + BRAM-state are the right levers.

Keep `RESET_AFTER_RECONFIG true` + `SNAPPING_MODE ON`. **Re-enable `BITSTREAM.GENERAL.CRC`** for M7
partials unless you still want M4 LUT-editing on this RP (training weights are in BRAM, not LUTs, so
CRC-disable is no longer needed for M7's own purpose).

## Open decisions / what still needs nailing down (the "what else to add" list)

These are flagged rather than silently defaulted — each can shift the RTL:

1. **Q-format**: Q8.8 (INT16) master vs INT32 accumulator master. *Recommend Q8.8* — smallest BRAM,
   enough range for XOR; revisit for MNIST (M7.4) where INT32 accumulation may be needed.
2. **Network topology for XOR**: 2-2-1 vs 2-4-1. *Recommend 2-4-1* — wider hidden layer trains far
   more reliably and still fits the 4×4 array (pad to 4).
3. **Gradient/overflow guards**: fixed-point training overflows silently. Need **saturating** adds on
   the master update and a sanity clamp on δ; define these in the M7.0 oracle so HW matches.
4. **Learning rate**: power-of-two `LR_SHIFT` (no divider) — confirm a single shift schedule
   converges XOR; if not, add a small mantissa-multiply lr.
5. **Weight init**: random INT8 init must be host-seeded (no on-chip RNG planned) — firmware writes
   an init vector; or a tiny LFSR in `train_unit` (decide in M7.2).
6. **Batch vs online SGD**: start **online** (per-sample update) — simplest, converges XOR; batched
   accumulation is an M7.4 add for MNIST.
7. **Determinism / oracle tolerance**: decide bit-exact vs ≤1-LSB tolerance for the HW-vs-numpy
   compare (fixed-point rounding order may differ across the SW/HW split).

## (Optional) ICAP/LUT live-edit hooks — where "our method" *does* help M7

ICAP per-step weight rewrite is too slow and LUT-baking weights worsens the LUT budget (see the
note in "Reducing M7 resource"), so it is **not** on the M7 critical path. But two ICAP uses fit
cleanly and strengthen the story without touching the resource budget:

- **M7.3+ checkpoint-to-fabric**: once training converges, instead of (or in addition to) loading
  the learned weights into `rm_infer`'s BRAM, **ICAP-bake them into the inference LUTs** (M4/T2.2
  path) — the literal "the chip trains, then writes its learned weights into its own logic." ICAP
  is used exactly where it's cheap: **once**, at convergence, not per SGD step.
- **Runtime attestation**: have the static-region RoT use ICAP **register/partial readback** (proven
  in T2.2/T2.3) to spot-check the loaded accelerator's CRAM after `loadbp` and periodically during
  training — extends the M5 *pre-load* hash gate with *post-load* fabric verification. (Bounded by
  the RF-FIFO readback limit → sample frames, not full-frame compare.)

These reuse `scripts/{hwicap-uart.py, lut-surgery.py, prjxray-fasm.sh}` as-is; no new RP resource.

## Milestone definition

**M7 (training):** the EBAZ4205 boots to a measured RoT, `measured-load`s a DFX training module, and
**trains a 2-layer leaky-MLP to solve XOR entirely on the fabric** — forward + `Wᵀ·δ` backward on the
systolic array, loss/δ/update via the train unit, master weights in BRAM in QAT hybrid precision —
with the host only feeding samples and reading a **decreasing `LOSS`** over UART. PS/NEORV32 are never
reset; a tampered training partial is refused (M5 gate). The final learned weights match a numpy
fixed-point oracle within tolerance.

## Key files (all inside `/home/test/zynq_xpart/`, zero changes to source projects)

- `rtl/train_unit.v` — MSE loss + `dL/dy`, leaky' gate, `grad_descent` weight update (master copy)
- `rtl/systolic_array_4x4.v`, `rtl/wb_tpu_accel.v` — extend with transpose-load + TRAIN_CTRL regs
- `rtl/dfx/tpu_rp_rm_train.v` — training RM on the `tpu_rp` interface (or fold into `rm_tpuvpu`)
- `vivado/dfx/build_dfx.tcl` — add `config_train`
- `scripts/train-xor.py` — host loop: seed init/data over UART, read `LOSS` curve, log convergence
- `sim/tb_train.v` + `sim/oracle_train.py` — numpy fixed-point training oracle (the golden ref)
- `board/allowlist.sha256` — add the training partial hash
- **Explicitly not modified**: any file under
  `/home/test/{xilinx,neorv32_tpu,neorv32_rot,riscv_tpu_demo,rot_tpu_handoff,EP4CE6}`

## Licensing / attribution (tiny-tpu is reference-only — same as M6)

`rtl/train_unit.v` is written from scratch to the math in this doc. Its loss / leaky-derivative /
gradient-descent algorithms are *referenced from* tiny-tpu-v2/tiny-tpu `src/{loss,leaky_relu,
gradient_descent}.sv`. **Confirm tiny-tpu's license before copying any code/constants** (the repo
page showed no LICENSE at plan time — re-derive from public math/docs if unclear). `rtl/` is tracked
and pushed to the public `github.com/14sea/zynq-xpart`, so add a header:
`// MSE-loss / leaky-deriv / SGD algorithm referenced from tiny-tpu-v2/tiny-tpu (<license>, <url>).`

## Relationship to existing milestones

| Reused as-is | New in M7 |
|---|---|
| M2 4×4 INT8 array (forward `W·x`) | reuse the **same array** for `Wᵀ·δ` (transpose-load) |
| M6 VPU (bias/leaky/requant) + `VPU_ALPHA` | leaky **derivative** reuses the same `k` |
| M3 DFX RP + PCAP `loadbp` | `rm_train` (or `rm_tpuvpu`+TRAIN_CTRL) as a new config |
| M5 `measured-load` gate | gates the training partial; RoT authorizes the trainer |
| M4 ICAP/LUT live-edit | not on the training loop (weights in BRAM); **optional** for checkpoint-to-fabric + runtime attestation (see ICAP hooks) |
| — | `train_unit.v`, master-weight BRAM, TRAIN_CTRL/LOSS/DELTA regs, numpy training oracle |

## References
- Backprop / training datapath reference: tiny-tpu-v2/tiny-tpu `src/{loss,leaky_relu,
  gradient_descent,vpu}.sv` + `jupyter/` notebooks, <https://github.com/tiny-tpu-v2/tiny-tpu>
  (**reference-only; verify license** — see Licensing). Note tiny-tpu trains in 16-bit fixed-point;
  M7 keeps INT8 forward + a Q8.8/INT16 master (QAT hybrid).
- QAT (quantization-aware training, master-weights pattern): standard practice; any QAT primer.
- DFX / partial bitstreams: UG909 <https://docs.amd.com/r/en-US/ug909-vivado-partial-reconfiguration>
- Existing milestone docs: `docs/m6_plan.md` (M6 VPU forward), `docs/dfx_design.md` (M3),
  `docs/measured_boot.md` (M5), `docs/lut_surgery.md` (M4), `docs/plan.md` (master plan)
