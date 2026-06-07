# Task #8 part 1 — ICAP self-reconfiguration: investigation & findings

> **STATUS: SOLVED on this board (2026-06-07).** A clean, deterministic, reversible
> live LUT-INIT edit now runs over **ICAP from inside the fabric** on this exact
> XC7Z010/EBAZ4205 + miner-FSBL/U-Boot setup — no reset, no PCAP/`loadbp`. Both a
> PS-driven (AXI HWICAP) flavour AND the headline soft-core-driven flavour (in-PL
> NEORV32 → ICAPE2, no PS in the reconfiguration loop, T2.3) are hardware-verified.
> See **[RESOLUTION](#resolution-2026-06-07--icap-from-inside-works)** below for the
> full working recipe and the one missing piece (`devcfg.CTRL[PCAP_PR]`) that defeated
> all earlier attempts. The sections below the resolution are the original (pre-solution)
> investigation, kept verbatim as the historical record of what was tried and why it
> looked like a wall.
>
> The original DFX build remains the proven M4 state; `rtl/xbus_icap.v` /
> `scripts/icap-build-frame.py` are kept as the first-attempt artifacts. The solved path
> uses `vivado/hwicap_lut/`, `scripts/hwicap-uart.py`, `scripts/hwicap-make-framewrite.py`.

## RESOLUTION (2026-06-07) — ICAP-from-inside WORKS

The "hard Zynq-7 wall" was over-pessimistic. A staged retry (T1 → T2.1 → T2.2), all
hardware-verified on the EBAZ4205 under the **unchanged miner U-Boot**, broke it.

### The two original blockers, refuted
- **(a) "PS→PL AXI writes don't land under this U-Boot."** REFUTED (T1). A loopback test
  bitstream (`vivado/axi_wtest/`: AXI-GPIO ch1 OUTPUT with `C_TRI_DEFAULT=0` so it drives
  at reset without a TRI write, looped internally to ch2 INPUT) showed `mw 0x41200000
  0xa5a5a5a5` read back on ch2 @0x41200008 as `0xa5a5a5a5` — the write physically drove a
  PL net. PS→PL AXI writes work fine under miner U-Boot.
- **(b) "AXI HWICAP slave never responds / regs read 0."** REFUTED (T2.1). Two integration
  bugs caused it: (1) `axi_hwicap` has a **separate `icap_clk` port that is easy to leave
  unconnected** (Vivado errors `BD 41-758` if so) — must be tied to FCLK0; (2) **wrong
  register offsets** were read. At the correct offsets (WF=0x100 RF=0x104 SZ=0x108 CR=0x10C
  SR=0x110 WFV=0x114 RFO=0x118 ASR=0x11C — NOT shifted by 0x10) a healthy HWICAP reads
  **SR=0x5 (DONE,EOS), WFV=0x3f (FIFO depth 64)**. The vendor IP's internal config FSM
  (EOS=1) cleanly satisfies the ICAP sync handshake that the hand-rolled `xbus_icap.v`
  could not.

### THE missing piece (why every prior write "perturbed but didn't take")
On Zynq-7000 the configuration engine is reached through a MUX owned, after boot, by
**PCAP**. ICAPE2's output is blocked until you hand the MUX to ICAP by clearing
**`devcfg.CTRL[PCAP_PR]` = bit 27 (0x08000000)** at `0xF8007000`:

```
mw 0xF8007000 0x4400e07f    # was 0x4c00e07f; clears bit27 -> ICAP owns the config engine
... do the ICAP frame write ...
mw 0xF8007000 0x4c00e07f    # restore PCAP ownership (the edit persists)
```

Without this, the HWICAP write streams perfectly (SR=5, ASR=0, WFV cycles) but the data
never reaches CRAM — exactly the "ICAP electrically alive, perturbs but won't take"
symptom from approach #1. (Note: it is **`PCAP_PR` bit 27**, not `PCAP_MODE` bit 26.)

### Working recipe (T2.2, `vivado/hwicap_lut/`)
1. **Design** with AXI HWICAP @0x41400000 (**`icap_clk` tied to FCLK0**) + the target
   logic. Demonstrator: a `DONT_TOUCH` LUT6, all 6 inputs tied 0 so its output = INIT[0],
   feeding an AXI-GPIO input bit the PS can read. Build with `BITSTREAM.GENERAL.CRC
   Disable`; write `lut_A.bit` (INIT[0]=0) and `lut_B.bit` (INIT[0]=1) from the *same*
   routed design (so they differ by exactly that one CRAM bit).
2. **Locate the frame** with prjxray bitread controlled-diff:
   `bitread --part_file <clg400 part.yaml> -o X.bits -z -y X.bit`, then `diff` →
   `bit_00400d9a_073_15` = FAR **0x00400d9a**, word 73, bit 15.
3. **Extract the frame from the RAW .bit FDRI word stream** (`hwicap-make-framewrite.py`),
   NOT from prjxray `.bits` — the `.bits` model omits the per-frame **ECC word (word 50)**,
   so a reconstructed frame writes wrong data and silently does nothing. The raw extractor
   self-validates: the single-bit-xor word is INIT (frame word 73), a second multi-bit
   word is the ECC (frame word 50), exactly 23 words apart.
4. **Build a minimal write sequence**: dummy×8, sync, RCRC, IDCODE(0x03722093), WCFG, FAR,
   FDRI type2 = target frame + real neighbour frame as pad (202 words), CRC=0, DESYNC.
   **NO GRESTORE/GTS** (they pulse global set/reset and perturb the running design — the
   likely source of approach #1's non-determinism).
5. **Drive HWICAP** (`hwicap-uart.py writeseq`): stream into WF@0x100 in ≤63-word chunks,
   `CR=0x1` per chunk, poll `CR`→0. **Send one `mw` per word** — the board UART has no flow
   control and bursting commands overruns its RX FIFO. Do **not** use `CR=0x4` (Abort): it
   wedges the write path.
6. **Set PCAP_PR=0** (above), run the write, restore PCAP_PR=1.

### Result (hardware)
With PCAP_PR=0 and lut_A loaded (GPIO bit0 = 0): stream the B-frame → GPIO bit0 = **1**;
stream the A-frame → **0**; B again → **1** — deterministic, reversible, the PS/design
never reset. Live LUT truth-table surgery over ICAP from inside the fabric. The config
engine was driven by PL logic (HWICAP→ICAPE2); the PS only fed the word stream over AXI.

### T2.3 — NEORV32 soft-core self-modifies via ICAP, no PS in the reconfig loop (DONE)
The headline "purity" step is also achieved on hardware. The in-PL **NEORV32** soft-core
streams the single-frame write to a custom **`rtl/xbus_icap.v`** controller → **ICAPE2**,
rewriting the LUT6's CRAM frame itself. The PS is never in the reconfiguration loop: it
only (a) stages the frame payload into a shared AXI-Lite framebuf and (b) grants ICAP the
config engine (`PCAP_PR=0`) and observes. (Staging-then-fabric-executes is the external
review's DDR-staging pattern; it also sidesteps the non-convergence below.)
- **Build/RTL:** `vivado/t23/build_t23b.tcl` → `rtl/neorv32_soc_icap.vhd` (NEORV32 +
  `xbus_icap`@0xF3000000 + `lut_probe` readback@0xF4000000 + mailbox@0xF1000000 +
  framebuf read@0xF5000000) + `rtl/axil_framebuf.vhd` (AXI-Lite slave + 256×32 RAM, PS
  writes @0x40000000, NEORV32 reads). Firmware: `sw/icap_firmware/main.c`.
- **Recipe:** load `lut_A.bit` (CRC-disabled, INIT[0]=0) → confirm mbox heartbeat →
  `scripts/framebuf-load.py <seq.bin> 0x40000000` (PS stages the host-extracted seq;
  word[0]=length last = ready flag) → `mw 0xF8007000 0x4400e07f` (PCAP_PR=0).
- **Result (hardware):** lut_o@0x41200000 → **1**; mbox@0x41200008 = `0xC3<hb>0101`
  (winning **swap mode 1** = per-byte bit-reverse, lut bit = 1). NEORV32 read the payload
  from BRAM, drove ICAPE2, flipped the LUT — the fabric rewrote its own configuration.
- **`xbus_icap` is deterministic here** (approach #1's non-determinism was GRESTORE in the
  sequence + the config MUX never handed to ICAP). The proven sequence has NO GRESTORE and
  runs with `PCAP_PR=0`; swap mode 1 hits the LUT cleanly on the first try.
- **Non-convergence note (why payload is PS-staged, not baked in IMEM):** baking the frame
  into the NEORV32 IMEM image does NOT converge — the target LUT frame shares its CLB
  column's INT routing bits, and any firmware-only IMEM change shifts that routing, so the
  baked frame goes stale every build (verified: even with the LUT LOC-pinned, two builds
  differing only in IMEM content gave 203 differing frame bytes). PROHIBITing the column's
  slices doesn't help (the bits are interconnect routing, not slice config). Staging the
  payload from the PS at runtime (extracted from the loaded bitstream) decouples it.

- **T3 (clean non-miner FSBL pivot) is UNNECESSARY** — its entire premise (that the miner
  U-Boot blocked PL-AXI writes / HWICAP) is disproven.

### HWICAP readback (mechanism solved; full-frame capture is RF-FIFO-limited)
Revisited 2026-06-07 (`scripts/hwicap-uart.py readreg|readback`). The earlier "readback
returns garbage `0xffffffd9`" was **two bugs, both fixed**: (1) readback also needs ICAP to
own the config engine — it only works with **`PCAP_PR=0`**, same as writes; (2) a single
`CR.Read` of more words than the **read FIFO depth (~128)** overruns it (the controller does
**not** back-pressure ICAP), so the tail is garbage.
- **Config-register readback now works cleanly and deterministically:** `readreg 12` (IDCODE)
  = **`0x13722093`** (xc7z010), `readreg 7` (STAT) = `0x46107ffc` — correct, repeatable. So the
  ICAP read path is proven (the FDRO/sync handshake is satisfied; this is the real correction
  to the old "garbage" conclusion).
- **Frame readback is RF-FIFO-bound:** the addressed frame comes out behind a ~101-word
  readback pad, so a full frame (pad + 101 = 202 words) exceeds the ~128-deep RF. Draining in
  small `CR.Read` chunks reaches past the FIFO and **does** return real frame data (the edited
  LUT-INIT word was recovered), but the chunked-FDRO boundary **drifts run-to-run** (two
  back-to-back reads differed by ~18 words), so a clean automated before/after frame compare
  isn't reliable. The single-frame **write is verified observably via GPIO** regardless. A
  clean fix would need a deeper HWICAP read FIFO (not a parameter on the stock IP) or a
  bench-side concurrent RFO drain faster than the ICAP stream.

---

## (Original investigation — historical, pre-solution)

## Goal
Have the in-fabric NEORV32 soft-core rewrite one configuration frame (the LUT holding
the table) through the **ICAP** (Internal Configuration Access Port) — vs PCAP, which
the PS uses for `loadbp` — so the fabric modifies itself live, no reset, no PS config.
Target frame `0x0040149B` (prjxray: tile `CLBLM_R_X17Y21` base `0x00401480` + INIT
segbit offset 27), word 42 bit 15; single-frame write sequence built by
`scripts/icap-build-frame.py` from the patched partial.

## Approaches tried (all on hardware)

### 1. Custom XBUS→ICAPE2 controller, NEORV32-driven (`rtl/xbus_icap.v`)
A hand-rolled controller instantiating `ICAPE2`, fed by NEORV32 over XBUS.
- v1 pulsed `CSIB` per word → no effect. **Finding:** a `CSIB` de-assert mid-stream
  aborts config. Fixed with a buffered burst (fill a BRAM, then stream with `CSIB`
  held low). The firmware then completed without hanging (a done-flag confirmed it).
- Swept all 4 I[] byte/bit-swap conventions; set `devcfg.CTRL.PCAP_PR=0` to route PR
  to ICAP (confirmed it switches — it then *blocks* PCAP `loadbp`); added a long dummy
  flush + `GRESTORE`/`START` finalization.
- **Result:** with the fat-sync preamble the ICAP *does* act — the LUT output changed
  live (`0x5A`→`0x52`/`0x76`) — but **not deterministically** and **not** to the
  intended `0x5B`. ICAP frame **readback** (added to the wrapper) returned structured
  but non-frame data (`0xFFFFFF__`), i.e. the engine is clocked and responds but does
  **not** cleanly sync/process the frame stream. So: ICAP electrically alive, can
  *perturb* the fabric from inside, but no clean/deterministic single-frame write.

### 2. Xilinx AXI HWICAP IP, PS-driven
Added `axi_hwicap` to the PS block design on the GP0 interconnect @ `0x41400000`.
- **Result:** the HWICAP AXI slave does **not respond** to the PS — all registers read
  `0`, and a `GIER` write does not stick, even though the AXI-GPIO mailbox on the same
  interconnect reads fine. (Note: only PL-AXI *reads* had ever been exercised before;
  PL-AXI *writes* from this U-Boot may not reach the PL.)

### 3. Xilinx AXI HWICAP IP, NEORV32-driven (XBUS→AXI4 bridge)
Wired NEORV32's XBUS through `xbus2axi4_bridge` to the HWICAP `S_AXI_LITE` entirely in
`neorv32_soc_dfx` (no PS path). Builds clean.
- **Result:** NEORV32's first HWICAP access (the `WFV` read) **never acknowledges** →
  the core stalls at the bus/instruction level (software timeouts cannot recover a
  stalled bus access, so the register-state diagnostic could not even be captured).

## Conclusion (SUPERSEDED — see RESOLUTION at top)
> This conclusion was WRONG. ICAP-from-inside works on this board; see the resolution.
> The post-mortem below now reads as: the HWICAP non-response was an `icap_clk`/offset
> integration bug (not the miner FSBL), and the custom controller "perturbed but didn't
> take" because the config-engine MUX was never handed to ICAP (`PCAP_PR` still 1).

ICAP-from-inside is a hard wall on this specific board across **both** a hand-rolled
ICAPE2 controller and the vendor AXI HWICAP IP, and across **both** PS- and PL-driven
paths. The miner FSBL/U-Boot config-engine state (fixed boot, no eFUSE, JTAG-only) is
the most likely root cause for the HWICAP non-response; the custom-controller result
shows the ICAP itself is reachable but the config handshake isn't cleanly satisfied by
a hand-rolled feeder. The plan flagged Phase-4 ICAP as the high-risk item — confirmed.

## Future work (SUPERSEDED — most items resolved)
- ~~Bring up AXI HWICAP standalone on a clean (non-miner) FSBL/BOOT.BIN~~ — NOT needed;
  it came up healthy under the miner U-Boot once `icap_clk` was connected.
- ~~Try the other ICAP site / explicit STARTUPE2/EOS~~ — not needed; HWICAP's EOS=1.
- ~~Cross-check the sequence against prjxray~~ — done; prjxray bitread located the frame and
  the raw-FDRI extraction was the fix (the `.bits` ECC-word omission was the residue).
- Still open (optional): T2.3 NEORV32-driven no-PS HWICAP (see resolution).

## External review (2026-06-07): "free the config MUX" proposal — evaluated, partial value

An external LLM proposed that the wall is the Linux `xilinx-devcfg.c` driver holding
`DEVCFG.CTRL[PCAP_MODE]=1` so the config MUX stays owned by PCAP and ICAPE2 never gets
ready, with two fixes: (1) a kernel module (LKM) that `ioremap(0xF8007000)`s DEVCFG and
clears the PCAP-route bit to hand off to ICAP, then restores it; (2) `&devcfg { status =
"disabled"; }` in the DTS so Linux never grabs the config bus. Verdict: **right
neighborhood, wrong diagnosis for this board, and it misses the two blockers we actually
found.** Keep only the parts marked "useful" below.

- **Frame mismatch (undercuts the whole premise):** all three attempts above ran from the
  **miner U-Boot**, bare-metal NEORV32 in PL — **no Linux, no `xilinx-devcfg` driver in
  play**. The "Linux driver locks PCAP_MODE" mechanism does not map to our test bench.
- **The routing handoff was already done:** approach #1 already set **`PCAP_PR=0`** (the
  bit that actually selects ICAP for PR) and confirmed the MUX switched (PCAP `loadbp`
  then stopped working). That was *not* the blocker. Also note the bit numbers: routing
  select is **`PCAP_PR` = bit 27 (`0x08000000`)**, not `PCAP_MODE` = bit 26 (`0x04000000`,
  merely "PCAP interface enable") — the proposal cleared the wrong bit.
- **"ICAP is default-open without PS" is wrong for Zynq-7000:** post-reset `PCAP_PR`
  defaults to 1 (PCAP); the FSBL loads the PL over PCAP. ICAP is never the default owner —
  you must clear `PCAP_PR` explicitly. So DTS-disabling devcfg stops Linux from *re-grabbing*
  the bus but does **not** *grant* ICAP; the boot chain already left `PCAP_PR=1`.
- **It misses our real two blockers:** (a) the HWICAP **AXI slave never acks / writes don't
  land** under this U-Boot (a PL-AXI-write / IP-out-of-reset problem, independent of the
  config MUX — the HWICAP register file should ack regardless of ICAP grant); (b) the
  custom controller proved ICAP can *perturb* the fabric but **won't cleanly sync a single
  frame** (readback `0xFFFFFF__`), which points at **EOS / STARTUPE2 + the sync-word/dummy-
  pad/single-frame command sequence** — the proposal never addresses startup state at all.
- **Useful part (only under a clean-Linux pivot):** *if* we move off the miner U-Boot to our
  own clean FSBL/Linux (our top future-work item), the LKM handshake *pattern* (PS frees the
  config path → signals PL → restores after) is sound, and the DDR3-staging architecture
  (Linux DMAs the `.bit` to a fixed phys addr, hands the address to PL) fits our
  "keep PS able to read partials" stance. To use it, apply three corrections: clear
  **`PCAP_PR` (bit 27)** not bit 26; add **explicit EOS/STARTUPE2 wait + the ICAP sync
  sequence**; and **bring HWICAP up standalone first** (confirm PL-AXI writes land) before
  attempting the single-frame write. It does not, on its own, unblock the wall we hit.

### Retrospective on this review (after the 2026-06-07 solution)
Crediting where due: the review's **core intuition — "free the config MUX so ICAP gets the
engine, by `mw`-ing DEVCFG@0xF8007000 to hand off the PCAP-route bit, then restoring it" —
was exactly the fix.** T2.2 succeeded precisely by clearing `PCAP_PR` (bit 27) at
`0xF8007000` before the write and restoring it after. Several of *our own* rebuttals above
were wrong and are corrected by the result:
- "Approach #1 already set PCAP_PR=0, so the MUX wasn't the blocker" — misleading. The
  **HWICAP** attempts (#2/#3), and our first T2.2 writes, did **not** clear PCAP_PR, and that
  omission *was* the blocker for the write reaching CRAM. The MUX handoff is essential and
  had been silently dropped after approach #1.
- "(a) HWICAP never acks = a PL-AXI-write problem" — **wrong**. PL-AXI writes work fine
  (T1); the HWICAP non-response was the unconnected `icap_clk` + wrong register offsets.
- The "clean-Linux pivot" we held as the top future item was **unnecessary**.
Where the review was off was only its *framing* (it blamed the Linux `xilinx-devcfg` driver
and `PCAP_MODE` bit 26; our bench had no Linux, and the bit is `PCAP_PR` 27) — but its
mechanism and its DEVCFG-handoff prescription were right. Net: a good reminder that the
right *mechanism* can hide under a wrong *diagnosis* — evaluate per-item (see the iterative
LLM-review practice), and update the record when the hardware proves a rebuttal wrong.
