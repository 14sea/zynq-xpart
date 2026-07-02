# DRAFT — GitHub issue for stnolting/neorv32 (NOT posted yet)

**Title:** Heads-up: pre-2026-04-28 `image_gen` silently corrupts `.rodata` with
custom linker scripts (ELF section concatenation drops LMA alignment gaps)

---

This is a heads-up for users of NEORV32 releases **before the 2026-04-28
`image_gen` restructuring** (b53853d4 "remove ELF parsing" / 7ba83c34 "read flat
binary instead of ELF") — current `main` is **not affected**; the new
flat-binary flow (`objcopy -O binary` → `image_gen`) is correct by construction.
Since older releases are widely vendored, this may save someone the debugging
marathon it cost us.

## The bug (ELF-parsing-era image_gen, e.g. v1.12.9)

The old `image_gen.c` built the ROM image by concatenating sections:

```c
memcpy(raw_image,                           text,   text_size);   // start with .text
memcpy(raw_image + text_size,               rodata, rodata_size); // append .rodata
memcpy(raw_image + text_size + rodata_size, data,   data_size);   // append .data
```

This ignores LMA alignment gaps. With the stock `neorv32.ld` the sections happen
to pack contiguously, so the bug is **latent**. But with a custom linker script
(in our case picolibc's, where `.rodata` is `ALIGN(8)`), any firmware whose
`.text % 8 == 4` gets a 4-byte linker gap that the concatenation drops — **the
entire `.rodata` lands 4 bytes below its linked address in the IMEM image**.
Code executes normally (`.text` is unshifted); every constant table reads
shifted garbage. `.data`'s LMA is mishandled the same way.

## Why it is nasty

The symptom is a program that runs fine but computes wrong results (or takes
wild jumps through shifted `.rodata` jump tables), *deterministically per
firmware*, flipping apparently at random as code size changes (`.text % 8`).
On our Zynq-7010 project it masqueraded for ten days as a "build-dependent
FPGA routing problem" — timing-clean bitstreams, identical netlists, wrong
math — until a flat-implementation control isolated the firmware image.
Full forensic write-up (flat-flow control, discriminator firmware,
`objcopy`-vs-image diff, `.text % 8` prediction table 9/9, silicon re-test):
https://github.com/14sea/zynq-xpart/blob/main/docs/m7_2_dcpdiff.md

## Repro (any affected release)

1. Custom ld script with `.rodata : ALIGN(8)`; make `.text` size ≡ 4 (mod 8).
2. `riscv64-unknown-elf-objcopy -O binary main.elf ref.bin`
3. Compare `ref.bin` word-by-word against the generated
   `neorv32_imem_image.vhd` — everything after `.text` is shifted by −4.

## Fix options for pinned old versions

- Upgrade past 2026-04-28 (best), or
- patch the old `image_gen.c` to build the image from **PT_LOAD program
  headers** (place each segment at `p_paddr − base` in a zero-filled buffer,
  copy `p_filesz` bytes only). A drop-in fixed version we regression-tested
  (byte-identical to `objcopy -O binary` across 9 firmwares) is here:
  https://github.com/14sea/zynq-xpart/tree/main/sw/patches/image_gen_lma_fix
  (When porting, also validate `ELFCLASS32` / `ELFDATA2LSB` /
  `e_phentsize == sizeof(Elf32_Phdr)` so the parser fails loudly on
  unexpected ELFs.)
- Cheap tripwire for any setup: after every build, `cmp` the objcopy binary
  against the image the toolflow actually consumed.

No action needed on current `main` — filing this as a searchable record.
Happy to close immediately if you prefer.

---

PS — context, since the bug was found the hard way: NEORV32 is the resident
soft-core in two little open boards-and-bitstreams projects of ours on a $20
EBAZ4205 (Zynq-7010): **zynq-xpart** (github.com/14sea/zynq-xpart) — live
partial reconfiguration experiments: DFX hot-swap, prjxray-guided live
LUT-INIT surgery through ICAP, and on-chip NN training on a NEORV32 + 4×4
INT8 systolic-array SoC; and **zynq-ehw** (github.com/14sea/zynq-ehw) —
Thompson-style intrinsic evolvable hardware, a GA evolving circuits with
per-evaluation on-chip ICAPE2 bitstream rewrites, NEORV32 again doing the
on-board orchestration. Thanks for the processor — it has survived an
unreasonable amount of abuse.
