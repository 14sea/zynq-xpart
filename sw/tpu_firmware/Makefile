# tpu_firmware/Makefile — zynq_xpart demo firmware (NEORV32 + 4x4 INT8 TPU)

# RV32IMC + Zicsr/Zifencei
MARCH = rv32imc_zicsr_zifencei

# Toolchain (override on the command line, e.g. RISCV_PREFIX=riscv64-unknown-elf-)
RISCV_PREFIX ?= riscv-none-elf-

# Optimization
EFFORT = -Os

# IMEM/DMEM sizes must match the RTL (neorv32_soc_dfx generics: 32k / 16k)
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=32k
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=16k

# UART port for 'make upload'
UART_TTY ?= /dev/ttyUSB0

# Path to NEORV32 root
NEORV32_HOME ?= ../../neorv32

include $(NEORV32_HOME)/sw/common/common.mk
