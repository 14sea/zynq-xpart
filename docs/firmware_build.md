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

## ⚠️ MANDATORY: image_gen LMA fix (2026-07-02)

The stock NEORV32 `sw/image_gen/image_gen.c` concatenates `.text`+`.rodata`+`.data`
and DROPS LMA alignment gaps. With picolibc's `.rodata` ALIGN(8), any firmware with
`.text % 8 == 4` gets its whole `.rodata` shifted −4 bytes in the IMEM image —
constants read wrong at runtime while code runs fine (this was the entire M7.2
"multi-epoch divergence", see docs/m7_2_dcpdiff.md ROOT CAUSE). The fixed image_gen
lives at `sw/patches/image_gen_lma_fix/image_gen.c`; `scripts/setup-deps.sh` copies it
over `rtl_src/neorv32_tpu/neorv32/sw/image_gen/image_gen.c` after cloning NEORV32.
Re-run setup after any fresh rtl_src checkout BEFORE baking an IMEM image (common.mk
rebuilds the image_gen binary automatically). Sanity check for any suspicious image:
`riscv64-unknown-elf-objcopy -O binary main.elf x.bin` and word-compare x.bin against
the generated `neorv32_imem_image.vhd` — must be identical.

## ⚠️ MANDATORY #2: linker RAM size defsym (2026-07-02)

`sw/common/neorv32.ld` defaults `__neorv32_ram_size` to **8 K** when not defsym'd —
half the RTL's 16 KB DMEM, and the stack top lands at 0x80002000. Any firmware whose
.bss + peak stack exceeds 8 KB (e.g. main_mnist.c: 4.7 KB static accumulators +
4.4 KB i64 stack frames) silently collides .bss into the stack → wild jump → CPU
reset with no exception (this was the whole M7.4 "size band"). Always link with:

    USER_FLAGS+="-specs=picolibc.specs -Wl,--defsym,__neorv32_ram_size=16384"

and sanity-check `riscv64-unknown-elf-nm main.elf | grep __crt0_ram_last`
(must be 0x80003fff for 16 KB). If DMEM_SIZE in neorv32_soc*.vhd is ever raised,
raise the defsym too — the RTL generic alone does NOT move the linker's stack.
