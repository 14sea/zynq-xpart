# Quartus → Vivado porting checklist (Phase 2 pre-study)

Offline analysis done before Vivado was available. Conclusion: **the porting surface is much
smaller than expected** — the NEORV32 core is vendor-neutral and ships an official Vivado IP flow,
and the only Altera-specific constructs that actually need changing are a handful.

Sources (read-only copies): `rtl_src/neorv32_tpu/` (NEORV32 core + TPU, the chosen route),
`rtl_src/riscv_tpu_demo/` (PicoRV32 fallback). File census: 70 VHDL, 18 Verilog, 0 SV,
0 `.mif/.hex` (in-repo), 0 `.qsf/.qip`.

## 1. NEORV32 soft-core — near-zero cost

- The core `.vhd` files contain **no** real `altsyncram / altera_mf / lpm_* / altpll`
  instantiations (grep came back empty); the hits were only in comments/docs.
- **Ships official Vivado integration**: `rtl_src/neorv32_tpu/neorv32/rtl/system_integration/neorv32_vivado_ip.tcl`
  + `neorv32_vivado_ip.vhd` + `docs/userguide/packaging_vivado.adoc` → use the vendor-supported
  flow to package the core as a Vivado IP.
- RAM/ROM init uses `neorv32_imem_image.vhd` / `neorv32_bootrom_image.vhd` (VHDL arrays); Vivado
  infers BRAM automatically.
- **Action**: package with `neorv32_vivado_ip.tcl`; enable `CPU_FAST_MUL_EN=true` (DSPs are
  plentiful on Zynq; this was off on the EP4CE6).

## 2. TPU (systolic + LUT mem) — plain Verilog, one attribute change

Files: `rtl_src/neorv32_tpu/rtl/{tpu_accel.v, systolic_array_4x4.v, pe.v, wb_tpu_accel.v}`.

- **`pe.v` multiplier** (the only unambiguous Altera→Xilinx code change):
  the source uses `(* multstyle = "logic" *)` (comment says outright: "DSP placement fails with 16
  PEs + 26 M9K" — LUT multiply forced by EP4CE6 resource pressure). The Zynq has 80 DSP48E1, so do
  the opposite and **use DSP**: `(* multstyle="logic" *)` → `(* use_dsp = "yes" *)` (the signed 8×8
  `w_reg*x_in` maps cleanly to DSP48E1). Ported version is in `rtl/pe.v`.
- **TPU LUT memory** (`tpu_accel.v` 0x040–0x43F, a 256×32b register array indexed by `lut_idx`):
  Vivado infers BRAM / distributed RAM from the generic Verilog array, **no rewrite needed**. Note:
  in the source the weights live in *RAM*; the real Track-B XPART moves weights into *LUT-INIT*
  (logic), which is a **new** capability added in Phase 4, not present in the source design.
- **Bus**: `wb_tpu_accel.v` is a Wishbone B.3 subset (XBUS), vendor-neutral. On the Zynq side use
  AXI4 — add an **AXI-Lite ↔ Wishbone bridge** (or re-wrap the TPU directly as an AXI-Lite slave)
  hung off a PS GP port.

## 3. To delete (replaced by the PS on Zynq)

- **SDRAM controller** `sdram_ctrl.v` / `wb_sdram_ctrl.v`: delete. Soft-core memory uses the **PS
  DDR3** instead (accessed over AXI, or the soft-core uses PL BRAM for IMEM/DMEM and bulk data goes
  to PS DDR).
- **EPCS / `altasmi` / ALTREMOTE_UPDATE**: delete if present in the NEORV32 route — boot/config is
  taken over by the Zynq PS (PCAP/QSPI).
- **PicoRV32 route** (`riscv_tpu_demo/`): kept as a fallback reference, not in the main line.

## 4. Constraints and clocking

- No critical `.qsf`/SDC content to translate (0 in repo). Write a new **`vivado/constraints/ebaz4205.xdc`**:
  - The PS part (DDR3/MIO/FCLK) comes from the existing EBAZ4205 board config (the FSBL's
    `ps7_init` / community board files) — **do not recreate it**.
  - PL clock from PS **FCLK_CLK0** (start at 50 MHz to match the original design; can be raised later).
  - PL pins: minimal for Phase 1 (AXI-GPIO); add as needed.

## 5. Porting order (maps to plan Phases 1→2)

1. Phase 1: PS + AXI-GPIO only Hello-PL (no soft-core/TPU) — prove the A-route on-board loop first (M1).
2. Phase 2a: package NEORV32 with `neorv32_vivado_ip.tcl`; bring up PS+NEORV32 running firmware (UART).
3. Phase 2b: port the TPU (`pe.v` now uses DSP; LUT mem → BRAM), attach AXI to the PS, run one MNIST tile (M2).
4. Optional: widen the systolic array 4×4 → 8×8 (plenty of Zynq resources).

## 6. Risks / items to confirm once Vivado is in

- The EBAZ4205 PS7 config (DDR model/timing, MIO mapping) must be extracted from the on-board FSBL
  or taken from community `.xdc`/board files — the first thing to do once Vivado is installed is to
  pair the PS7.
- The AXI↔Wishbone bridge handshake details need simulation.
- `neorv32_vivado_ip.tcl` may assume a newer Vivado version; 2025.2 should be compatible — verify
  right after install.
