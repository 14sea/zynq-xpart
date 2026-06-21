# Makefile — zynq_xpart M7.0b on-board training firmware (NEORV32 + 4x4 TPU).
#
# Builds ONLY main.c (the board trainer). train_xor.c is the HOST validator and
# is built separately via `make -f Makefile.host check` — APP_SRC is pinned to
# main.c so common.mk's ./*.c glob does not pull the host main in too.
#
# Build (bakes neorv32_imem_image.vhd; then rebuild the M6 static bitstream):
#   make NEORV32_HOME=../../rtl_src/neorv32_tpu/neorv32 \
#        RISCV_PREFIX=riscv64-unknown-elf- \
#        USER_FLAGS+="-specs=picolibc.specs" clean install

APP_SRC = main.c

MARCH = rv32imc_zicsr_zifencei
RISCV_PREFIX ?= riscv64-unknown-elf-
EFFORT = -Os

# IMEM/DMEM sizes must match the RTL (neorv32_soc_dfx generics: 32k / 16k)
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=32k
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=16k

UART_TTY ?= /dev/ttyUSB0
NEORV32_HOME ?= ../../rtl_src/neorv32_tpu/neorv32

include $(NEORV32_HOME)/sw/common/common.mk
