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
