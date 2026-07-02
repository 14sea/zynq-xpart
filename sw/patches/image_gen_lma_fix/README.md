# image_gen LMA-gap fix (M7.2 root cause, 2026-07-02)

NEORV32's stock `sw/image_gen/image_gen.c` builds the IMEM image by naively
concatenating `.text` + `.rodata` + `.data`, ignoring LMA alignment gaps. With the
picolibc linker script (`.rodata` ALIGN(8)), any firmware whose `.text % 8 == 4`
gets a 4-byte linker gap that the concatenation drops — shifting the entire
`.rodata` by −4 bytes in IMEM. Constants (weight tables, test vectors) then read
wrong at runtime while code executes normally. This masqueraded for 10 days as a
"7-series DFX in-context-routing limitation" (see docs/m7_2_dcpdiff.md, ROOT CAUSE
section, incl. the 9/9 `.text % 8` prediction table and the silicon QED).

This directory holds the FIXED image_gen.c (rtl_src/ is gitignored). To apply:

    cp sw/patches/image_gen_lma_fix/image_gen.c \
       rtl_src/neorv32_tpu/neorv32/sw/image_gen/image_gen.c
    # common.mk rebuilds the image_gen binary automatically on next make

Fix: `.rodata` is placed at its linked offset (sh_addr delta from `.text`), `.data`
right after (4-aligned), in a zero-filled (calloc) image so gaps read as 0.
