# Phase 7 — M7: on-chip training (backprop) — the chip learns by itself

> **STATUS: M7.0 + M7.1 DONE & hardware-verified (2026-06-21); M7.2–M7.4 planned.** Builds on M2
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
- This is the same *class* as the M7.1 "post-config settle" gremlin (root cause left open there —
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

### M7.3 — DFX train↔infer split + measured-boot gate (the project-consistent headline + the LUT fix)
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

### M7.4 (stretch) — bigger workload
- Train a small **MNIST tile** classifier (reuse the M2 MNIST vectors / tiny-tpu's MNIST demo as
  reference), batched over multiple forward/backward passes. 4×4 array → tile/loop in firmware.
- **Evidence**: on-board accuracy climbing across epochs on a held-out tile; matches numpy oracle.

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
