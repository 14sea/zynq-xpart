# NEORV32 firmware build (M2 and later)

The **canonical firmware source is committed at `sw/tpu_firmware/`**; the NEORV32 core
copy and the build working-tree live under the gitignored `rtl_src/` and `sw_src/`. Run
**`scripts/setup-deps.sh`** to recreate both (clone NEORV32 + apply the patch below +
scaffold the build tree). This records the recipe so it is reproducible.

## Toolchain
- `riscv64-unknown-elf-gcc` (Ubuntu `gcc-riscv64-unknown-elf`, 13.2) — compiler only.
- C library: **picolibc** (`sudo apt install picolibc-riscv64-unknown-elf`); build
  with `-specs=picolibc.specs`. (Real newlib is not apt-available for this triple.)

## One local patch to the NEORV32 copy
`rtl_src/neorv32_tpu/neorv32/sw/lib/source/neorv32_newlib.c` declares `errno`
non-thread-local (newlib style), which clashes with picolibc's thread-local
`errno`. Guarded it:
```c
#include <errno.h>
#ifndef __PICOLIBC__
#undef errno
extern int errno;
#endif
```

## Build + install the IMEM image
```bash
cd sw_src/neorv32_tpu_sw/tpu_test
NHOME=$PWD/../../../rtl_src/neorv32_tpu/neorv32      # the core copy
make NEORV32_HOME=$NHOME RISCV_PREFIX=riscv64-unknown-elf- \
     USER_FLAGS+="-specs=picolibc.specs" clean install
```
`install` writes `neorv32_imem_image.vhd` into `$NHOME/rtl/core/`. The Vivado
build (`vivado/m2/build_m2.tcl`) reads that via `file_list_soc.f`, so the firmware
is baked into IMEM and (with `BOOT_MODE_SELECT=2`) runs automatically on config.
Rebuild the bitstream after every firmware change.

## M2 mailbox protocol
`tpu_test/main.c` runs the TPU self-tests, then re-runs the general 4x4 matmul
`W*[1,2,3,4]` and writes `((RES0 & 0xFFFF) << 16) | (RES1 & 0xFFFF)` to the
mailbox at `0xF1000000` (XBUS). `neorv32_soc` brings that out as `mbox_o` →
AXI-GPIO → the PS reads it at `0x41200000`. Expected value: **`0x001E0046`**
(RES0=30, RES1=70) — proof the PS sees a real TPU result computed by NEORV32.
