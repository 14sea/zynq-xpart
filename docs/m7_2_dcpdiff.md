> # ⚑ SUPERSEDED 2026-07-02 — ROOT CAUSE FOUND, AND IT IS NOT THE FPGA
> The "build-dependent 7-series-DFX in-context-routing limitation" conclusion below is
> **WRONG** (kept for the record). The real root cause is a **firmware image-generation
> bug**: NEORV32's `image_gen.c` concatenates `.text`/`.rodata`/`.data` ignoring LMA
> alignment gaps; with the picolibc linker script (`.rodata` ALIGN(8)), any firmware
> with `.text % 8 == 4` gets its whole `.rodata` shifted −4 bytes in the IMEM image, so
> all constant tables (weights, test vectors) read wrong at runtime while code executes
> normally. "Stochastic per build" was actually **deterministic per firmware layout**
> (`.text % 8`) — 9/9 predictions confirmed, incl. the diag2settle "lucky pass"
> (.text 5248 ≡ 0) and every failing build (.text ≡ 4). Fix + silicon QED (unchanged
> diag2pad firmware passes bit-exact; full multi-epoch `rm_train` training runs the
> oracle curve) in the **"ROOT CAUSE (2026-07-02)"** section at the end of this file.
> Vivado, DFX, routing, placement, and the XC7Z010 are all exonerated.

# M7.2 multi-epoch divergence — investigation summary (TL;DR)

**Symptom:** the HW train_unit trio works for a single epoch, but multi-epoch training on
`rm_train` diverges — the array forward returns ≈0 (`{-5,-3,-8,-3}`) instead of the oracle
`{19,2,10,-1}`, deterministically per build.

**Root cause (established):** a **build-dependent in-context-routing** effect on the XC7Z010
(7-series) DFX flow. The RM (array) is re-place&routed in-context against a static whose
footprint shifts with firmware size (IMEM 2→3 RAMB36); some routes compute correctly, some
don't. Every build is **100 % timing-clean** (setup+hold MET, 0 unconstrained, fully routed,
identical OOC netlist) yet some miscompute — i.e. a physical/routing reproducibility issue
STA does not model. It is **stochastic per build**, not monotonic in size (a WORKING bad-size
bitstream exists — see settle section).

**Fixes attempted — ALL fail (this doc is the evidence):**
| attempt | verdict |
|---|---|
| (a) DCP-diff good vs bad | only the whole array relocates; both timing-clean → not setup/hold |
| (b.1) freeze DSP placement | built clean, **board still fails** → not the DSP placement |
| (b.2) lock good RM route onto bad static | route conflicts (RM not isolated from static) |
| bounded `CONTAIN_ROUTING` | RM contained but static still routes through RP → no fix |
| (G2) freeze full RM placement + reroute | method-blocked (macros won't commit in bad static) |
| (G3) floorplan NEORV32 off the RP | built clean, **board still fails** → static-thru-RP not the (sole) cause |
| (G4) explicit array reset/clear | refuted by inspection (the clear already runs every compute) |
| settle before forward | **refuted by a same-bitstream control** — the one "pass" was routing luck |

**Baseline re-verified same-session/same-board:** the GOOD build computes `{19,2,10,-1}` +
loss 469, so the board/load path is sound and the negatives are real.

**Decision:** multi-epoch-correct `rm_train` is not achievable on this part by placement,
routing-isolation, reset, or settle. **Pivot to M7.3 on the verified single-epoch path**;
document multi-epoch-on-`rm_train` as a known 7-series-DFX in-context-routing limitation.

**Best untested future lead:** DCP-diff a WORKING bad-size build (`diag2settle`) vs a FAILING
bad-size build (`diag2pad`) at ~constant size to isolate the exact array net whose route flip
breaks the compute — more targeted than the good-vs-bad diff below.

**Methodological note:** single-build "fixes" are untrustworthy here because of routing
variance; only same-bitstream pre/post controls are reliable (the settle false-positive proves it).

---

# M7.2 — DCP-diff diagnostic (option a): what shifts good vs bad

Date: 2026-06-25. Goal: open the routed `impl_8` of a KNOWN-GOOD (diag2-size) build
and a KNOWN-BAD (diag2pad-size) build and see exactly what place+route shifts, to
pin the multi-epoch divergence mechanism instead of guessing.

## Method
- GOOD firmware = `diag2.c` (`.text` 6260 B) — on-board forward is correct `{19,2,10,-1}`.
- BAD firmware  = `diag2pad.c` (`.text` 10928 B) — diag2 + ~4.6 KB inert dead padding,
  **byte-identical forward machine code**, on-board forward wrong `{-5,-3,-8,-3}`.
- For each: `make APP_SRC=… clean install` to bake the IMEM, then
  `vivado -source rebuild_static_diag.tcl` (reset+run synth_1 → impl_1 → impl_8; the
  `rm_train` OOC synth is reused, so the RM/array **netlist is identical** between builds —
  only impl-time place+route of the fixed netlist changes).
- Fingerprinted each routed `dfx_top_routed.dcp` (`array_fingerprint.tcl`, `timing_check.tcl`).

## Result — both builds are 100 % timing-clean, only placement differs

| check | GOOD (diag2) | BAD (diag2pad) |
|---|---|---|
| fully routed / routing errors | yes / **0** | yes / **0** |
| setup WNS | **+0.859 ns** (in NEORV32) | **+0.567 ns** (in NEORV32) |
| hold WHS, worst overall | **+0.027 ns** (PS) | **+0.041 ns** (PS) |
| hold WHS into the array | **+0.181 ns** | **+0.167 ns** |
| unconstrained internal endpoints | **0** | **0** |
| register/latch pins with no clock | **0** | **0** |
| "all user-specified constraints met" | yes | yes |
| **17-DSP array placement** | DSP48_X1Y1…Y19 | **DSP48_X1Y0…Y17, scrambled** |

- All 17 array/train DSPs are **completely relocated** between builds, and (per
  `extract_array_loc.tcl`) all **6032** array leaf cells move. Pure firmware-size growth
  (larger IMEM → larger static placement footprint) drags the RP's array to a wholly
  different floorplan.
- The worst setup paths in **both** builds are inside the NEORV32 CPU, **not** the array —
  the array is nowhere near a timing edge.

## Conclusion
Static timing analysis **certifies both builds as fully correct** — setup MET, hold MET,
no unconstrained/async paths, fully routed, identical netlist — yet the BAD build
miscomputes deterministically on silicon (array returns ≈0 → requant → `{-5,-3,-8,-3}`).

⇒ The divergence is **NOT** a setup/hold/routing/constraint problem. It is a
**placement-dependent physical / config-time effect that STA does not model** — the same
*class* as the M7.1 "post-config settle" gremlin (GSR / reset-release / config-time
startup), but here it is placement-sensitive and so survives a wall-clock settle. A clean,
repeatable wrong value (not a per-load lottery) means the bad floorplan brings the array up
**not accumulating** (psum chain effectively held), deterministically for that build.

This directly validates **fix option (b): freeze the good array placement** so P&R is
invariant to firmware/static size. Artifact ready:
`scratchpad …/good_array_pin.xdc` (6032 LOC+BEL constraints from the diag2 build) — apply
before impl and rebuild at full-trainer (`main.c`) size; if the array then trains the full
multi-epoch curve, placement-sensitivity is confirmed and the fix is in hand. (Routing-lock
from the good RM DCP is the stronger fallback if LOC pinning alone is insufficient.)

Tooling kept: `vivado/dfx/{array_fingerprint,timing_check,extract_array_loc}.tcl`.

---

# M7.2 — fix (b) attempts: freeze the good placement (2026-06-25)

Tooling: `vivado/dfx/{rebuild_pinned,extract_array_anchors,apply_dsp_only,assemble_good_rm}.tcl`.

## (b.1) DSP-only pin — BUILT CLEAN, BOARD STILL FAILS
- Froze all 17 DSP48 to the good floorplan (DSP48_X1Y1–Y19) via a PLACE_DESIGN.TCL.PRE
  hook on impl_8, against the bad (diag2pad) static. (Full-cell and DSP+FF anchor replay
  both failed first: LUT-combine BEL conflicts, and CARRY4 macros "could not place all
  shapes" when FFs were pinned but carry-chains floated — so backed off to DSP-only.)
- Build: WNS +0.431, WHS +0.041, MET; fingerprint confirms all 17 DSP LOCs == good.
- **On board (diag2pad + DSP-pinned, `fpga loadb`, mailbox `md 0x41200000`, polled >12 s):
  forward tags B0/B1/B2 = −5/−3/−8 — the SAME bad `{-5,-3,-8,…}` failure; epoch loss
  B5 = 2 (collapsed, vs 469).** ⇒ **DSP multiply placement is NOT the sensitive element.**
  Since place_design still placed the fabric accumulate (psum CARRY4 chains + FFs + their
  routing) freely and differently from good, the sensitivity lives in the **fabric
  accumulate path**, not the DSPs.

## (b.2) Import the good RM place+route onto the bad static — BLOCKED by route conflicts
- `read_checkpoint -cell u_soc/wb_tpu_inst <good rm_train_routed.dcp>` onto the bad
  `dfx_top_routed_bb.dcp` → **157 partial route conflicts**, on BOTH `u_tu` (RM, inside RP)
  AND `u_soc/neorv32_inst/...` (static, OUTSIDE RP). Bitgen refused.
- ⇒ The RM routing is **not isolated to the pblock** — it shares boundary routing resources
  with the static. The bad-size static (larger NEORV32 firmware) routes those nets
  differently right at the RP boundary, so a good RM route cannot be dropped onto a
  different static. This is the same coupling the earlier CONTAIN_ROUTING attempt could not
  cure (CONTAIN_ROUTING keeps RM routing IN; it does not keep STATIC routing OUT of the RP).

## (b) conclusion
The multi-epoch divergence is a **placement/routing-dependent config-time physical effect**
whose true variable is **static (firmware-size-driven) routing in/near the RP boundary**,
NOT the array's own DSP placement. The standard knobs do not fix it:
- DSP/placement pinning — board-proven insufficient (b.1).
- CONTAIN_ROUTING — board-proven insufficient earlier (keeps RM in, not static out).
- Importing a locked good RM route — route-conflicts across statics (b.2).

A real fix needs **routing isolation of the RP** (a static-routing fence / guard band so the
RP boundary is identical regardless of firmware size) — a DFX floorplan redesign, not a
constraint tweak. Pragmatic alternative: **(c) build M7.3 on the verified single-epoch path**
and document multi-epoch-on-rm_train as a known DFX-floorplan limitation.

---

# M7.2 — bounded routing-isolation experiment (2026-06-25) — NEGATIVE, pivot justified

Question: can the RP be made routing-isolated so the RM bitstream is static-independent?
Test: add `CONTAIN_ROUTING true` to `pblock_rp`, rebuild GOOD (diag2) and BAD (diag2pad)
fully, then re-run the b.2 import (contained good RM → contained bad static) and count
route conflicts.

- GOOD contained build: impl_8 fully routed, 0 unrouted ⇒ `CONTAIN_ROUTING` succeeded, the
  RM routing IS contained in the pblock.
- Import test (contained good RM onto contained bad static): **STILL 161 partial route
  conflicts — but now almost entirely `u_soc/neorv32_inst/atomics…bus_req_i[data][*]`,
  i.e. STATIC NEORV32 nets routing THROUGH the RP region.** The RM-side conflicts are gone
  (containment worked); the static-through-RP conflicts remain.

Conclusion: `CONTAIN_ROUTING` contains the RM but does **not** keep the static out of the
RP. On XC7Z010 (7-series) DFX, a pblock reserves **logic sites** but **not the routing
fabric** — static signals (here the NEORV32 atomic-unit bus) freely route through the RP
region, and a larger firmware routes them differently, perturbing the RM at config time.
There is no standard 7-series constraint to fence static routing out of the RP (the
explicit routing-isolation / abstract-shell flow is UltraScale+ only).

⇒ Multi-epoch-correct `rm_train` cannot be made firmware-size-invariant by placement or
routing constraints on this part. **Pivot to (c): build M7.3 on the verified single-epoch
path; document multi-epoch-on-rm_train as a known 7-series-DFX routing-isolation limitation.**
(A heavier, out-of-scope alternative would be to floorplan the entire NEORV32 static into
its own pblock far from the RP so its routing never crosses the RP — a full static
floorplan redesign, not pursued.)

`pblock_rp.xdc` reverted to baseline (CONTAIN_ROUTING removed, note left in place).

---

# M7.2 — baseline re-confirmed on board, same session (2026-06-25, audit closure)

Audit gap found and closed: the (b.1) DSP-pin negative result relied on "good = correct"
from prior sessions; it was re-verified THIS session on THIS board to rule out a
board/load-path fault.

- RM netlist identical across good/bad builds: `rm_train_synth_1/tpu_rp.dcp` mtime is
  2026-06-21 (untouched by any 2026-06-25 rebuild) — the OOC RM synth is genuinely reused,
  so only impl-time P&R differs. (Confirms the (a) "identical netlist" premise.)
- GOOD diag2 build (good_c, with CONTAIN_ROUTING) loaded via `fpga loadb`, mailbox
  `md 0x41200000`: **B0..B3 = 19/2/10/−1 (forward CORRECT), B4 = 999 (train_unit SGD),
  B5 = 469 (epoch-0 loss, bit-exact to oracle).**
- Same board, same session, same load path that returned the DSP-pinned bad build's
  −5/−3/−8 + collapsed loss. ⇒ board/load path is sound; baseline good=correct holds in
  this build environment ⇒ the DSP-pin negative (b.1) is airtight: DSP placement is not the
  cause. The full causal chain (good→correct, bad→wrong, pinned-bad→still-wrong) is now
  verified end-to-end this session. No remaining material omissions; M7.2 closure stands.

---

# M7.2 — three deeper fix paths (2026-06-27): G2 / G3 / G4 all NEGATIVE

Audit of the "infeasible" conclusion found 3 untested avenues; all three were pursued.

## G2 — freeze the good RM placement, fresh route — METHOD-BLOCKED (suggestive negative)
- Import good RM + reroute: blocked — the imported good-RM boundary cells expect partition
  pins at GOOD locations; the bad static presents them elsewhere → boundary nets (e.g.
  `xbus_adr[1]`) unroutable. (`read_checkpoint -cell` can't be rerouted across statics.)
- Rebuild impl_8 with good placement as constraints: the full-cell / DSP+FF / DSP+CARRY4+FF
  replays all fail in the bad-static context — "Failed to commit N macros / could not place
  all shapes" (4 macros → 1 macro as more anchors added, never 0). The good placement's
  macros (carry chains) **cannot be committed in the bad static** — itself evidence that the
  placement is static-coupled, not independently freezable. The one freeze that DID build
  (DSP-only) failed on board. ⇒ not a pure-placement issue that's independently freezable.

## G3 — floorplan NEORV32 static off the RP — BUILT, BOARD-TESTED, NEGATIVE
- Geometry: NEORV32 already sits in CLOCKREGION_X0Y0; RP is X1Y0 (adjacent). Confined
  NEORV32 to the left column (CLOCKREGION_X0Y0:X0Y1) + CONTAIN_ROUTING so its internal
  routing can't stray into the RP. Both impls built clean.
- Verified: 0 static leaf cells in the RP region.
- **On board (diag2pad + NEORV32-confined): forward B0..B3 = −5/−3/−8/−3 — STILL the bad
  signature.** ⇒ "static NEORV32 routing through the RP" is NOT (or not solely) the
  mechanism. Keeping static logic/routing out of the RP does not fix it.

## G4 — explicit array reset/clear discipline — REFUTED BY INSPECTION
- The array already has a firmware-writable clear (`CTRL[4]`, "reset acc+done"), and the
  diag forward sequence ALREADY pulses it (`TPU_CTRL=0x10`) before and after every compute.
  A config-time array reset is already happening, yet the divergence persists. The wrong
  result is a datapath miscompute (RES≈0), not clearable stale FF state ⇒ a reset-discipline
  fix cannot address it. (train_unit SGD=999 is correct in the bad build, so NEORV32
  executes fine; the fault is specifically the array forward.)

## Net
All three deeper avenues fail — strengthening (not weakening) the closure: the divergence
is a fundamental 7-series DFX **in-context-routing reproducibility** effect — the RM's fresh
in-context route varies with firmware-size-driven static placement and yields a timing-clean
but functionally-wrong array, and it is fixable by neither placement freeze, static routing
isolation, nor reset discipline on this part. Confirmed pivot to M7.3 on the single-epoch path.

Remaining untested lead (different category, not pursued here): a **placement-dependent
post-config SETTLE before the forward** — the diag forward is computed at boot with no
settle; the good build happens to be correct without it, the bad build may need a longer
wall-clock settle (cf. the M7.1 settle gremlin). Worth a cheap test (add a multi-second
delay before the forward, rebuild, reload) before fully closing.

---

# M7.2 — settle lead TESTED and REFUTED by a same-bitstream control (2026-06-27)

The audit's remaining lead (placement-dependent post-config settle before the forward) was
tested — first a single build, then a rigorous control.

1. `diag2settle` (bad-class, .text 10996, baseline floorplan, a long settle + array warm-up
   BEFORE the forward) → board forward = **{19,2,10,-1} CORRECT**, epoch loss 469. Looked
   like settle was the cure (would overturn the closure).
2. **Rigorous control `diag2ctrl`** (bad-class, .text 11952, SAME bitstream computes the
   forward TWICE: immediately at boot = B0..B3, and again after the same long settle =
   B4..B7) → **B0..B3 = −5/−3/−8/−3 AND B4..B7 = −5/−3/−8/−3 — BOTH WRONG.**

⇒ On one and the same configured bitstream, a long wall-clock settle changes nothing. The
`diag2settle` "correct" result was **build-to-build routing luck** (that particular build
happened to get a working in-context route), NOT the settle. **The settle lead is refuted.**

Implications:
- The original closure stands and is strengthened: the divergence is a **build-dependent
  in-context-routing** effect (timing-clean but functionally-wrong, varies per build);
  settle, placement-freeze, routing-isolation, and reset-discipline all fail to fix it.
- New nuance: `diag2settle` proves a WORKING bad-class bitstream EXISTS — so correctness is
  NOT monotonic in firmware size; the in-context route is effectively stochastic per build
  (some bad-class builds route the array correctly, some don't).
- Methodological note: single-build "fixes" are unreliable here because of routing variance;
  only same-bitstream controls (pre/post on one config) are trustworthy.

Possible future lead (not pursued): DCP-diff a WORKING bad-class build (diag2settle) vs a
FAILING bad-class build (diag2pad) — size held ~constant — to isolate the exact array net
whose route flips correctness. More targeted than the good-vs-bad diff.

---

# M7.2 — flat non-DFX control: BUILT, board test PENDING (2026-07-02)

Purpose (external-review convergence): discriminate "DFX in-context-routing flow" from
"this part's P&R in general". Same design minus DFX, at bad-class firmware size.

## Build (done, no board available this session)
- Firmware: `diag2pad.c` re-baked into IMEM — `.text` 10928 B, the exact bad-class size
  that failed ~6/7 DFX rolls. (Side effect: `rtl_src/.../neorv32_imem_image.vhd` now holds
  diag2pad; re-bake before any future `vivado/dfx` rebuild.)
- `vivado/flat_m72/build_flat.tcl`: identical sources to the DFX build (dfx_top, ps BD
  incl. HWICAP, neorv32_soc_dfx, rm_train file set — `tpu_rp` linked as a plain flat cell),
  but **no PR_FLOW, no partition_def, no pblock**.
- Because correctness is a per-build route lottery, ONE flat pass would be weak evidence:
  built THREE rolls (impl_1/2/3 = place directives Default / AltSpreadLogic_medium /
  ExtraNetDelay_high). All three: `write_bitstream Complete!`, timing clean
  (WNS 2.09/1.87/2.04 ns, WHS +0.044/+0.024/+0.036 — far looser than the DFX builds'
  0.1–0.8 ns; no pblock squeeze). Netlist parity: 17 DSP48E1 (16 PE psum + 1 train_unit
  qmul), same as the DFX array. 3 distinct bitstreams (md5s differ; impl_1/3 share DSP
  macro LOCs but differ in fabric routing).
- Artifacts archived OUTSIDE `.runs` (lesson from the lost diag2settle/diag2pad DCPs):
  `vivado/flat_m72/artifacts/impl_N/{dfx_top.bit, dfx_top_routed.dcp, timing_summary.rpt,
  array_fingerprint.txt}` (local only — *.bit/*.dcp gitignored).

## Board procedure (next session, per roll ×3)
```
python scripts/uboot-fpga-load.py --op loadb vivado/flat_m72/artifacts/impl_N/dfx_top.bit
# poll mailbox 0x41200000 (U-Boot: md 0x41200000 1) — diag2pad cycles tags 0xB0..0xB5
```
Expected tags (same as diag2): B0..B3 = forward y[0] `{19,2,10,-1}` (0x13/0x02/0x0A/
0xFFFFFF in low 24 bits), B4 = SGD update 999 (0x3E7), B5 = epoch-0 loss 469 (0x1D5).

## Verdict table
- All 3 rolls correct ⇒ DFX in-context flow attribution CONFIRMED (flat P&R of the same
  netlist at the same firmware size is reliable; the lottery lives in the DFX flow).
- Any roll shows `{-5,-3,-8,-3}` (0xFFFFFB/FFFFFD/FFFFF8/FFFFFD) ⇒ attribution WEAKENED —
  reopen deeper P&R/floorplan suspicion (and the Vivado-version experiment gains priority).

---

# ROOT CAUSE (2026-07-02): NEORV32 image_gen drops LMA alignment gaps — NOT the FPGA

Board back online; ran the flat non-DFX control and followed the evidence. Full chain:

## 1. Flat non-DFX control REVERSES the attribution
- `vivado/flat_m72/build_flat.tcl`: the DFX design minus DFX (same sources, `tpu_rp` =
  `rm_train` linked flat, no PR_FLOW/partition/pblock), diag2pad firmware.
- **3/3 flat rolls (different place directives, WNS ~2 ns) fail with the byte-identical
  `{-5,-3,-8,-3}`**; 3/3 flat rolls with diag2 (small) firmware are correct.
- Deterministic with the firmware, independent of flow/placement/route ⇒ the entire
  route-lottery framing was wrong.

## 2. diag4 discriminator localizes to constant-data reads
`sw/m7_train/diag4.c` (bad-size class): IMEM-as-data checksum over the first 0x2800
bytes ✓ CORRECT; array with immediate-built weights ✓ RES = {14,40,28,6} exact; array
fed from `.rodata` ✗ ; INIT-forward ✗ −5. **The array and the CPU are healthy — only
`.rodata`-sourced constants are wrong.**

## 3. Host-side smoking gun: the image is layout-shifted
`objcopy -O binary` (LMA-true) vs the generated `neorv32_imem_image.vhd`: identical up
to `.text` end (0xDFC), then the VHD is **4 bytes short — the `.text`→`.rodata`
ALIGN(8) gap is missing, every `.rodata` byte sits at (linked address − 4)** in IMEM.
Code (addresses unshifted) runs fine; every constant table reads shifted garbage.
286/2733 words mismatched. (Also explains the "array ≈ 0" signature: it is simply the
deterministic forward of the shifted weight tables, identical in every build of the
same firmware.)

## 4. The bug, in `sw/image_gen/image_gen.c` (NEORV32, exposed by the picolibc port)
```c
memcpy(raw_image,                           text,   text_size);   // start with .text
memcpy(raw_image + text_size,               rodata, rodata_size); // append .rodata
memcpy(raw_image + text_size + rodata_size, data,   data_size);   // append .data
```
Naive concatenation. The picolibc linker script aligns `.rodata` to 8, so whenever
`.text % 8 == 4` the linker leaves a 4-byte LMA gap that the concatenation drops.
(Upstream NEORV32's own linker script never leaves a gap, so the bug is latent there;
our M2 picolibc port exposed it. It also silently mislays `.data`'s LMA — latent until
diag4, the first of our firmwares with initialized data.)

## 5. The `.text % 8` law — 9/9 board results predicted
| firmware | .text | %8 | board |
|---|---|---|---|
| diag2 | 4912 | 0 | ✅ correct (always was) |
| diag2settle | 5248 | **0** | ✅ **the "lucky" pass — no luck involved** |
| diag3 | 5404 | 4 | ❌ |
| main.c | 5372 | 4 | ❌ |
| diag2pad | 5180 | 4 | ❌ (every rebuild: baseline, DSP-pin, G3, reroute×3, icache-off, serialize, flat×3) |
| diag2ctrl | 3636 | 4 | ❌ (both halves — why "settle" showed nothing) |
| diag4 | 3580 | 4 | ❌ (B5) |
So: same-firmware rebuilds never flipped (deterministic ✓); the only "flip" ever
observed was between *different firmwares* (settle vs pad) — misread as route lottery.

## 6. Fix + silicon QED
Fix: `image_gen.c` now places `.rodata` at its linked offset (`sh_addr` delta) and
`.data` after it, in a zero-filled image (fixed copy tracked at
`sw/patches/image_gen_lma_fix/image_gen.c`; rtl_src is gitignored).
- Host: fixed VHD == `objcopy -O binary` — 0 mismatches.
- **Silicon QED 1**: byte-identical diag2pad + fixed image, flat build →
  **B0–B5 = 19/2/10/−1/999/469 — all six bit-exact to oracle.**
- **Silicon QED 2 (the original milestone)**: `main.c` full HW-trio multi-epoch trainer
  (.text 5372 ≡ 4, the previously-fatal class) + fixed image, REAL DFX `rm_train`
  build (impl_8) → **on-board loss curve follows the oracle: ep0 SSE=469, ep20
  SSE=277 (previously collapsed to ~0 by ep20), continuing to convergence.**

## 7. What this rewrites
- M7.2 multi-epoch on `rm_train` is **UNBLOCKED and hardware-verified** — the trio-in-HW
  trainer works as designed.
- All "in-context-routing reproducibility limitation" language (this doc, README, plan,
  m7_plan) is retracted; the negative fix attempts (a/b.1/b.2/G2/G3/G4/CONTAIN_ROUTING/
  settle-control) were all real experiments but chased a nonexistent physical effect.
- The M7.1 "post-config settle" and M7.4 "good size band" narratives deserve a re-read
  under the same lens (settle "cures" that coincided with firmware-size changes are
  suspect; the M7.4 pass was a `.text % 8 == 0` roll).
- Methodological lesson (2nd order): the earlier "only same-bitstream controls are
  trustworthy" note was right but incomplete — the missing control was **same firmware
  bytes, different flow** (the flat control), which is what broke the case open. And a
  checksum golden must come from the linker's view (ELF), never from the artifact
  being tested (the VHD) — B0's original golden was self-referential and blind to the
  shift.

---

# FOLLOW-UP (2026-07-02, same session): M7.1 "settle" and M7.4 "size band" re-examined — both narratives fall

With the image_gen fix in hand, the two sibling gremlins were re-tested on silicon.

## M7.4 MNIST: SOLVED — second independent bug found (linker RAM default)
- Re-read under the new lens: the current `main_mnist.c` is actually **layout-safe even
  under the old image_gen** (its `.rodata` holds only int8/int → ALIGN(4) → no gap; the
  trio family's ALIGN(8) came from the i64 `M7_XP`). And indeed the fixed image alone did
  NOT cure it — the board still crash-looped (settle heartbeats 0x7C cycling ~1 s).
- **Real cause: `neorv32.ld` defaults `__neorv32_ram_size` to 8K when no defsym is passed
  — and none ever was.** The linker laid out .bss + stack in 8 KB regardless of the RTL's
  16 KB DMEM. MNIST needs ~9.2 KB (`m7_epoch`'s static i64 accumulators = 4.7 KB .bss +
  main()'s i64 W1 stack frame = 4.4 KB) → **.bss/stack collision**: entering `m7_epoch`
  zeroes the accumulators straight through main's stack frame → wild return → silent CPU
  reset, exactly the recorded symptom ("resets with no caught exception"). The XOR
  trainers' 128 B weight frames fit 8 KB — that's the whole "good size band".
- The historical "DMEM raised 16→32 KB, didn't help" was a **false negative**: only the
  RTL generic was raised; the linker still placed the stack top at 8 KB.
- Fix: `USER_FLAGS+="-Wl,--defsym,__neorv32_ram_size=16384"` (verified
  `__crt0_ram_last=0x80003FFF`). **Board result: the full 64→8→4 MNIST trains 60 epochs,
  DONE peak 30/32 (93.8%) / final 28/32 (87.5%) / SSE 5503, and the watcher's per-epoch
  compare is bit-exact to the numpy oracle: SSE mismatch 0, acc mismatch 0 over 53
  sampled epochs.** M7.4-full is COMPLETE on the very fabric the "band" narrative blamed.

## M7.1 "wall-clock settle": BUSTED — no settle exists on a correct image
- Re-read: all 8 builds in the 8/8 delay-predicts-convergence table were *different
  firmwares* (adding/removing delay code changes `.text`), i.e. fully confounded with the
  image-layout coin flip; the "isolated maccs are fine" diagnostic compared HW against an
  in-firmware C recompute — **both sides read the same (possibly shifted) constants, so
  it was blind to the actual fault**; the single-boot sweep (one firmware, 64 trials, all
  converged) actually showed that THAT firmware needed no settle at all.
- **Test: `main.c` with `M7_SETTLE_ITERS=0` AND the 16 warm-up maccs removed — training
  starts milliseconds after `fpga loadb`.** Board: **ep0 SSE=469 bit-exact, ep20=277,
  ep40=280, ep60=264, ep80=240 … — value-identical to the 10 s-settle run, straight down
  the oracle curve to DONE.** (Corroborating: the MNIST run above ships only a ~0.6 s
  chunked settle and is bit-exact.) The "post-config settle" requirement does not exist;
  the shipped 10 s busy-wait can be deleted.

## Scoreboard for the whole affair
Three real bugs, zero FPGA bugs:
1. `image_gen` drops LMA alignment gaps (.rodata −4 B when `.text%8==4`) — M7.2's entire
   "in-context-routing limitation", M7.1's "settle", and part of M7.4's history.
2. Linker RAM size defaulted to 8 K (never defsym'd) — M7.4's crash/hang, the "size band".
3. (Minor, latent) `image_gen` also mislaid `.data`'s LMA — first exercised by diag4.
