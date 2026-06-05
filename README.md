# zynq_xpart — 真·live Xilinx-XPART demo on Zynq-7010 (EBAZ4205)

把在 Altera **EP4CE6** 上做到天花板的 `rot_tpu_handoff`（"XPART 减去 live 特性"：mode-H = EPCS 暂存 +
**冷启动** LUT 手术）迁移到 **Xilinx XC7Z010**，利用 Zynq 原生的 **ICAP + PCAP + Partial
Reconfiguration (DFX)**，第一次实现 **live**（不停机、免冷启动）的 partial reconfiguration。

- **Track A（打底）**：DFX 模块热插拔 —— `fpgautil -b rm.bit -f Partial`（PCAP），静态区/PS 不停机。
- **Track B（头条）**：prjxray + ICAP 单帧 **LUT-INIT** live 编辑 —— 把量化 NN 权重烤进 LUT 真值表，
  免重综合、免冷启动改它。
- **宿主＝混合**：Zynq PS（ARM Linux）载入/编排；NEORV32 软核在 PL 内作"被 measured 的 RoT 元件"。
- **信任锚＝软件 measured-boot**；不烧 eFUSE、不开硬件 secure boot、不动原厂 BOOT.BIN/FSBL（保 JTAG 可恢复）。

完整计划见 `docs/plan.md`。目标板硬件细节见 `board/`（拷自 EBAZ4205 bring-up）。

## 隔离原则（硬约束）
本目录是**独立项目**。`rtl_src/`、`sw_src/`、`board/`、`scripts/` 里的内容是从其他项目
（`/home/test/{xilinx,neorv32_tpu,neorv32_rot,riscv_tpu_demo,rot_tpu_handoff}`）**拷贝**来的只读起点。
所有修改只在本目录内进行——**绝不修改那些源项目的任何文件**。

## 目录
- `board/` — EBAZ4205 板级配置副本（`ebaz4205.cfg`、`ebaz4205_defconfig`）
- `scripts/` — bring-up 脚本副本（`program-pl.sh`、`nand-flash.py`、`jtag-scan.sh`、`uart-poke.py`、`uboot-intercept.py`）
- `rtl_src/` — 待移植 RTL 起点（NEORV32+TPU、PicoRV32+TPU 的只读副本）
- `rtl/` — 移植/新建的 Vivado RTL（本项目产物）
- `sw_src/` — 待移植固件起点（`stage2_loader` 的只读副本）
- `sw/` — PS 侧 measured-boot 等本项目固件
- `vivado/` — Vivado 工程（`hello_pl/`、`zynq_xpart/`）
- `partial/` — 生成的 full/partial bitstream 与 ICAP 单帧产物
- `docs/` — 计划与笔记
