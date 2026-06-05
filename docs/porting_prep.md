# Quartus → Vivado 移植准备清单（Phase 2 预研）

在 Vivado 到位前完成的离线分析。结论：**移植面比预想小得多**——NEORV32 核 vendor-neutral 且自带
官方 Vivado IP 流程，真正要改的 Altera 专属构造只有寥寥几处。

来源（只读副本）：`rtl_src/neorv32_tpu/`（NEORV32 核 + TPU，选定路线）、`rtl_src/riscv_tpu_demo/`（PicoRV32 备选）。
文件普查：VHDL 70、Verilog 18、SV 0、`.mif/.hex` 0（仓库内）、`.qsf/.qip` 0。

## 1. NEORV32 软核 —— 几乎零成本

- core `.vhd` 内**无** `altsyncram / altera_mf / lpm_* / altpll` 真例化（grep 实测为空）；命中只在注释/文档。
- **自带官方 Vivado 集成**：`rtl_src/neorv32_tpu/neorv32/rtl/system_integration/neorv32_vivado_ip.tcl`
  + `neorv32_vivado_ip.vhd` + `docs/userguide/packaging_vivado.adoc`。→ 直接用厂商支持的流程把核打成 Vivado IP。
- RAM/ROM init 走 `neorv32_imem_image.vhd` / `neorv32_bootrom_image.vhd`（VHDL 数组），Vivado 自动推断 BRAM。
- **动作**：用 `neorv32_vivado_ip.tcl` 打包；启用 `CPU_FAST_MUL_EN=true`（Zynq DSP 充裕，EP4CE6 上是关的）。

## 2. TPU（systolic + LUT mem）—— 普通 Verilog，一处属性改动

文件：`rtl_src/neorv32_tpu/rtl/{tpu_accel.v, systolic_array_4x4.v, pe.v, wb_tpu_accel.v}`。

- **`pe.v` 乘法器**（唯一明确的 Altera→Xilinx 代码改动）：
  源用 `(* multstyle = "logic" *)`（注释直言："DSP placement fails with 16 PEs + 26 M9K" —— EP4CE6 资源
  逼出来的 LUT 乘法）。Zynq 有 80 个 DSP48E1，应反过来**用 DSP**：
  `(* multstyle="logic" *)` → `(* use_dsp = "yes" *)`（signed 8×8 `w_reg*x_in` 干净映射 DSP48E1）。
  已移植版见 `rtl/pe.v`。
- **TPU LUT 内存**（`tpu_accel.v` 0x040–0x43F，256×32b 寄存器数组按 `lut_idx` 索引）：Vivado 从通用
  Verilog 数组推断 BRAM/分布式 RAM，**无需改写**。注意：源里权重存在 *RAM* 里；Track-B 真·XPART 要把权重
  搬进 *LUT-INIT*（逻辑），那是 Phase 4 **新增**能力，不在源设计内。
- **总线**：`wb_tpu_accel.v` 是 Wishbone B.3 子集（XBUS），vendor-neutral。Zynq 侧用 AXI4——
  做一个 **AXI-Lite ↔ Wishbone 桥**（或把 TPU 直接重封 AXI-Lite 从设备）挂到 PS GP 口。

## 3. 要删除的（Zynq 上由 PS 取代）

- **SDRAM 控制器** `sdram_ctrl.v` / `wb_sdram_ctrl.v`：删。软核内存改用 **PS 的 DDR3**（经 AXI 访问，
  或软核用 PL BRAM 作 IMEM/DMEM、大数据走 PS DDR）。
- **EPCS / altasmi / ALTREMOTE_UPDATE**：源 NEORV32 路线里若有则删——配置/启动由 Zynq PS（PCAP/QSPI）接管。
- **PicoRV32 路线**（`riscv_tpu_demo/`）：作为备选保留参考，不进主线。

## 4. 约束与时钟

- 无 `.qsf`/SDC 需转译的关键内容（仓库内 0 个）。新写 **`vivado/constraints/ebaz4205.xdc`**：
  - PS 部分（DDR3/MIO/FCLK）来自 EBAZ4205 既有板配置（FSBL 的 `ps7_init` / 社区 board files），**不要重造**。
  - PL 时钟用 PS **FCLK_CLK0**（先 50 MHz 对齐原设计，后续可拉高）。
  - PL 引脚：Phase 1 先最小化（AXI-GPIO），后续按需加。

## 5. 移植顺序（对应计划 Phase 1→2）

1. Phase 1：纯 PS + AXI-GPIO 的 Hello-PL（不含软核/TPU），先打通 A-route 上板回路（M1）。
2. Phase 2a：用 `neorv32_vivado_ip.tcl` 打包 NEORV32，PS+NEORV32 跑通固件（UART）。
3. Phase 2b：移植 TPU（`pe.v` 已改 DSP；LUT mem→BRAM），AXI 挂 PS，跑一次 MNIST tile（M2）。
4. 可选：systolic 4×4 → 8×8（Zynq 资源足）。

## 6. 风险/待 Vivado 确认项

- EBAZ4205 的 PS7 配置（DDR 型号/时序、MIO 映射）需从板上 FSBL 提取或用社区 `.xdc`/board files——
  Vivado 装好后第一件事就是把 PS7 配对。
- AXI↔Wishbone 桥的握手细节需仿真验证。
- `neorv32_vivado_ip.tcl` 可能假设较新 Vivado 版本；2025.2 应兼容，装好即验。
