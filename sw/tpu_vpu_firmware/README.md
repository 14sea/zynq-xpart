# tpu_vpu_firmware — NEORV32 firmware for the M6 full-version RM (TPU + VPU)

Drives the `rm_tpuvpu` Reconfigurable Partition: loads weights/inputs, programs the
VPU (bias → Leaky ReLU → INT8 requant via regs `0x30`–`0x50`), runs one matmul+VPU
pass, reads back **POST0-3** (INT8 post-activation), and publishes the packed result
to the mailbox at `0xF1000000` (PS reads `0x41200000`).

Reference tile (matches `sim/tb_rm_tpuvpu.v` T1, bit-exact):

| | values |
|---|---|
| W | `[[1,1,1,1],[1,2,3,4],[2,2,2,2],[1,0,1,0]]` |
| X | `[2,3,4,5]` → RES `[14,40,28,6]` |
| VPU | bias `[8,0,-10,5]`, scale `181`, shift `7`, alpha `4`, leaky+bias on |
| → POST | `[31,57,25,16]` |
| → **mailbox** | **`0x1019391F`** (`{POST3,POST2,POST1,POST0}` bytes) |

A live DFX swap to this RM (e.g. from rm2 → `0x00BB00CC`) flips the mailbox to
`0x1019391F` with no CPU reset — the headline M6.3 observable.

## Build (M6.3)
Same flow as `../tpu_firmware` — `make install` bakes `neorv32_imem_image.vhd` into
the NEORV32 RTL (`BOOT_MODE_SELECT=2` auto-runs on PL config), so the **static
bitstream must be rebuilt** (`vivado/dfx/build_dfx.tcl`) after changing this firmware,
and the rm_tpuvpu partial re-implemented against the new locked static. The new
static-full + partial sha256 then replace the M6.2 entries in `board/allowlist.sha256`.

```bash
make NEORV32_HOME=$NEORV32_HOME RISCV_PREFIX=riscv64-unknown-elf- \
     USER_FLAGS+="-specs=picolibc.specs" clean install
```
