# tpu_firmware — NEORV32 demo firmware (canonical source)

This is the project's NEORV32 firmware that drives every on-board demo: it loads the
4×4 INT8 TPU weights, runs the systolic matmul (or reads the LUT lookup table in the
LUT-RP), and **publishes the result to the mailbox** at `0xF1000000` (which the PS reads
over AXI-GPIO at `0x41200000`). Publishing continuously is what makes a live DFX swap
(M3) or a live LUT-INIT edit (M4) observable from the PS with no CPU reset.

Expected mailbox values:
- RM1 (real TPU):  `0x001E0046`   (RES0=30, RES1=70)
- RM2 (alt accel): `0x00BB00CC`
- RM_LUT (X=1):    `0x005A004D` → `0x005B004D` after the live LUT edit

## Build
The build runs inside a NEORV32 source tree (NEORV32 is an external dependency — see
the repo root README "Build / reproduce"). With the local NEORV32 at
`$NEORV32_HOME` and the picolibc-errno patch applied (`docs/firmware_build.md`):

```bash
make NEORV32_HOME=$NEORV32_HOME RISCV_PREFIX=riscv64-unknown-elf- \
     USER_FLAGS+="-specs=picolibc.specs" clean install
```

`make install` regenerates `neorv32_imem_image.vhd` in the NEORV32 RTL tree;
`BOOT_MODE_SELECT=2` in `rtl/neorv32_soc_dfx.vhd` auto-runs this image on PL config.
