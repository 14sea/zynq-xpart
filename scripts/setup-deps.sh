#!/usr/bin/env bash
# Recreate the two gitignored upstream dependencies so the repo builds from a fresh
# clone (see README "Build / reproduce"). Idempotent — safe to re-run.
#   1. NEORV32 source  -> rtl_src/neorv32_tpu/neorv32   (+ picolibc-errno patch)
#   2. firmware build tree -> sw_src/neorv32_tpu_sw/tpu_test  (from sw/tpu_firmware/)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

# NEORV32 version this project was built against (rtl hw_version_c = 0x01120900).
# Override with NEORV32_REF=... if you need a different tag.
NEORV32_REF=${NEORV32_REF:-v1.12.9}
NEORV32_DIR=$root/rtl_src/neorv32_tpu/neorv32

if [ ! -d "$NEORV32_DIR/rtl/core" ]; then
  echo "[setup] cloning NEORV32 $NEORV32_REF -> $NEORV32_DIR"
  echo "[setup] (if it hangs on this box, IPv6 is broken — see reference_wsl_ipv6 notes)"
  mkdir -p "$(dirname "$NEORV32_DIR")"
  git clone --depth 1 --branch "$NEORV32_REF" https://github.com/stnolting/neorv32.git "$NEORV32_DIR"
else
  echo "[setup] NEORV32 already present: $NEORV32_DIR"
fi

# picolibc-errno guard (newlib-style errno clashes with picolibc's thread-local one)
nl=$NEORV32_DIR/sw/lib/source/neorv32_newlib.c
if [ -f "$nl" ] && ! grep -q '__PICOLIBC__' "$nl"; then
  echo "[setup] patching neorv32_newlib.c (picolibc-errno guard)"
  perl -0pi -e 's{#undef errno\nextern int errno;}{// zynq_xpart: picolibc declares errno thread-local; only redeclare for newlib.\n#ifndef __PICOLIBC__\n#undef errno\nextern int errno;\n#endif}' "$nl"
else
  echo "[setup] picolibc patch already applied (or file absent)"
fi

# image_gen LMA-gap fix: stock NEORV32 v1.12.9 concatenates .text/.rodata/.data
# and drops linker alignment gaps, corrupting IMEM constants for some picolibc
# layouts. Keep the local dependency copy deterministic until this is upstreamed.
ig_src=$root/sw/patches/image_gen_lma_fix/image_gen.c
ig_dst=$NEORV32_DIR/sw/image_gen/image_gen.c
if [ -f "$ig_src" ] && [ -f "$ig_dst" ]; then
  if ! cmp -s "$ig_src" "$ig_dst"; then
    echo "[setup] patching image_gen.c (LMA-gap fix)"
    cp "$ig_src" "$ig_dst"
  else
    echo "[setup] image_gen LMA-gap patch already applied"
  fi
else
  echo "[setup] WARNING: image_gen patch source or destination missing"
fi

# firmware build tree (canonical source lives in sw/tpu_firmware/)
ft=$root/sw_src/neorv32_tpu_sw/tpu_test
mkdir -p "$ft"
cp "$root/sw/tpu_firmware/main.c"   "$ft/main.c"
cp "$root/sw/tpu_firmware/Makefile" "$ft/Makefile"
echo "[setup] firmware build tree ready: $ft"

cat <<EOF

[setup] done. Next:
  # build firmware (RISCV_PREFIX may be riscv64-unknown-elf- or riscv-none-elf-)
  cd $ft && make NEORV32_HOME=$NEORV32_DIR \\
      RISCV_PREFIX=riscv64-unknown-elf- USER_FLAGS+="-specs=picolibc.specs" clean install
  # build the DFX bitstreams
  cd $root/vivado/dfx && vivado -mode batch -source build_dfx.tcl
EOF
