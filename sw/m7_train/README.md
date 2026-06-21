# m7_train — on-chip XOR training (M7.0b)

The board trains a 2-4-1 leaky-MLP to solve XOR end-to-end: forward `W·x` on the
4×4 INT8 systolic array (M6/M2 datapath, VPU bypassed so we get the raw INT32
accumulator), and loss / δ / outer-product / SGD update on the NEORV32 in
software — the hybrid-QAT split (Q8.8/INT16 master weights in BRAM, INT8 forward
view) from `docs/m7_plan.md`. The host only watches the `LOSS` curve fall over
UART.

## Files
- `m7_kernel.h` — the **shared** fixed-point backprop kernel. Included verbatim by
  both the host validator and the board firmware; the only thing that differs is
  `array_macc()` (plain C on host, XBUS on board). This is the M7.0/M7.1 SW/HW
  split made literal.
- `m7_vectors.h` — **auto-generated** by `sim/oracle_train.py --dump-header`:
  host-seeded init master weights + packed per-epoch sample order (no on-board
  RNG, per plan #5/#6) + the oracle's golden final weights/loss (host self-check
  only; excluded from the board build via `-DM7_BOARD`).
- `train_xor.c` — HOST validator: plain-C `array_macc`, runs the kernel, bit-exact
  compares final weights + full loss curve against the numpy oracle.
- `main.c` — NEORV32 board firmware: XBUS `array_macc` + the same kernel. NEORV32
  `uart0` is not pinned out on this board (`dfx_top.v` leaves `uart0_txd_o` open),
  so the loss curve is published progressively through the PS mailbox 0x41200000
  (bit31=0 → checkpoint `(idx<<24)|SSE`; bit31=1 → DONE `0x80000000|(XOR<<16)|SSE`),
  each checkpoint held ~2 s for host sampling.
- `../../scripts/m7-watch-loss.py` — host watcher: polls the mailbox over U-Boot
  `md` and decodes the live loss curve. Run right after `fpga loadb`.

## Host validation (do this first — no board, no Vivado)
```bash
make -f Makefile.host header   # regenerate m7_vectors.h from the oracle
make -f Makefile.host check    # build + run; expect "PASS: bit-exact match"
```
Current result: weight mism=0, loss-curve 4000/4000, XOR 4/4, final SSE=0.

## Board firmware build (bakes IMEM → requires an M6 static rebuild)
`make install` bakes `neorv32_imem_image.vhd` into the NEORV32 RTL
(`BOOT_MODE_SELECT=2` auto-runs on PL config), so the M6 static bitstream
(`vivado/dfx/build_dfx.tcl`) must be rebuilt and `rm_tpuvpu` re-implemented
against the new locked static; the new sha256 then replace the M6 entries in
`board/allowlist.sha256`. No new RTL — M7.0b reuses the M6 `rm_tpuvpu` RM with
the VPU disabled.
```bash
make NEORV32_HOME=../../rtl_src/neorv32_tpu/neorv32 \
     RISCV_PREFIX=riscv64-unknown-elf- \
     USER_FLAGS+="-specs=picolibc.specs" clean install
```
ELF size (current): ~10.6 KB ROM / 256 B BSS — fits the 32 KB IMEM.
