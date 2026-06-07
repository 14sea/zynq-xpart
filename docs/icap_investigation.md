# Task #8 part 1 — ICAP self-reconfiguration: investigation & findings

> **STATUS: investigated exhaustively; not achieved on this board.** Live LUT-INIT
> editing is already proven via PCAP/`fpga loadbp` (see [lut_surgery.md](lut_surgery.md))
> and independently validated by prjxray (task #8 part 2). Doing the *same* edit over
> **ICAP from inside the fabric** hit a hard Zynq-7 wall on this XC7Z010/EBAZ4205 +
> miner-FSBL/U-Boot setup. This file records what was tried and what was found, so the
> work is reusable. The active DFX build is the proven M4 state (no ICAP in the static);
> the ICAP artifacts (`rtl/xbus_icap.v`, `scripts/icap-build-frame.py`) are kept for reference.

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

## Conclusion
ICAP-from-inside is a hard wall on this specific board across **both** a hand-rolled
ICAPE2 controller and the vendor AXI HWICAP IP, and across **both** PS- and PL-driven
paths. The miner FSBL/U-Boot config-engine state (fixed boot, no eFUSE, JTAG-only) is
the most likely root cause for the HWICAP non-response; the custom-controller result
shows the ICAP itself is reachable but the config handshake isn't cleanly satisfied by
a hand-rolled feeder. The plan flagged Phase-4 ICAP as the high-risk item — confirmed.

## Future work (if revisited)
- Bring up AXI HWICAP standalone on a **clean (non-miner) FSBL/BOOT.BIN** that enables
  the PL-AXI write path and a known-good end-of-startup, then retry the single-frame write.
- Try the other ICAP site (`ICAP_X0Y0`) and an explicit STARTUPE2/EOS wiring.
- Cross-check the single-frame write sequence against a full prjxray `fasm2frames`
  reconstruction of the frame to rule out any sequence-encoding residue.

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
