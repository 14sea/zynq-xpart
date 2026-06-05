# EP4CE6 → Zynq-7010 迁移：实现真·Xilinx-XPART demo

## Context（为什么做这件事）

**"XPART" = Xilinx Partial Reconfiguration Toolkit**（源自 JBits、走 ICAP 的 runtime 细粒度
LUT/CRAM 手术，含晶片内自我重构）。这不是公开产品名——结论来自本项目自己的文档
（`/home/test/rot_tpu_handoff/docs/notes/cyclone_cram_mapper_modeH_reply_2026_05_31.txt`、
`docs/plan.md`）。

`rot_tpu_handoff` 想在 **Altera Cyclone IV EP4CE6** 上实现两条 XPART 能力：
- **Track A**：运行中切换到另一个预编译 bitstream（SD 选一个 → 换上）。
- **Track B**：晶片内直接改 base bitstream 的 **LUT 真值表**（把量化 NN 权重烤进 LUT，免重编译）
  —— 这是 JBits/XPART 的招牌用例（constant folding / 自我重构）。

**EP4CE6 的物理天花板**：Cyclone IV E **没有 ICAP、不支持 partial reconfig**（Intel 硬件事实）。
所以 live-fabric XPART 物理不可能；项目只能做 `mode H`＝`.rbf` LUT 手术 + EPCS 暂存 + **冷启动**
（"XPART 减去 live 特性"），已于 2026-05-21 在单 LE (X22,Y12,N4) 0x0000→0xFFFF 硅级验证。
同时 LE 资源也到顶（`riscv_tpu_demo` 83% / `neorv32_tpu` 87%，逻辑密度先饱和）。

**为什么 Zynq-7010 解锁这件事**：XC7Z010（EBAZ4205）的 PL 是 Artix-7 fabric，**原生 ICAP + PCAP +
官方 Partial Reconfiguration / DFX**。于是 EP4CE6 做不到的"真·live XPART"第一次可行：
- Track A → **DFX 模块热插拔**（partial bitstream，静态区不停机）
- Track B → **prjxray + ICAP** 单 frame LUT-INIT live 编辑（格式已被公开逆向，重构可 live）
- 资源：~17,600 LUT6 / 35,200 FF / 80 DSP48E1 / 2.1 Mb BRAM —— 对 EP4CE6（6,272 LE / 30 mult9
  / 276 Kb M9K）是 DSP ~2.7×、BRAM ~7.6×、逻辑 ~2–3× 的余量，足够把 4×4 systolic 放大到 8×8/16×16。

**已锁定的方向（用户决策）**：
1. **范围＝两者分层**：DFX 打底（可重构分区 RP 作载体）＋ prjxray/ICAP LUT 手术做头条（RP 内的细粒度编辑）。
2. **宿主＝混合**：Zynq PS（ARM Linux，复用现有 EBAZ4205 bring-up）负责载入/编排；NEORV32 软核保留在
   PL 内作"被 measured 的 RoT 元件"。信任锚＝软件 measured-boot（**不动 BOOT.BIN/FSBL、不烧 eFUSE**，
   保留 JTAG 可恢复）。
3. **工具链＝本地装 Vivado ML Standard（免费）**：已确认 XC7Z010 + DFX 在免费版支持范围内。

**目标产物**：EBAZ4205 上一个端到端 demo —— ARM Linux 启动 → A-route 载入"自制 full bitstream"
（PS + 软核 RoT + 含 TPU 的可重构分区）→ measured-boot 验证软核 → (A) 经 PCAP 热插拔 RP 内的加速器
partial bit → (B) 经 ICAP 把新 NN 权重 live 烤进 RP 内 LUT-INIT，免冷启动、无停机。

---

## 工作目录与隔离原则（硬约束）

- 全部新工作落在**全新独立目录** `/home/test/zynq_xpart/`（自有 git repo，与既有项目完全独立）。
- 现有项目 `/home/test/xilinx`、`/home/test/neorv32_tpu`、`/home/test/neorv32_rot`、
  `/home/test/riscv_tpu_demo`、`/home/test/rot_tpu_handoff`、`/home/test/EP4CE6` 一律 **只读引用**：
  需要的文件 **拷贝**进 `zynq_xpart/` 后在副本上改，**绝不修改原项目任何文件**。
- 一次性拷入（之后只动副本）：
  - 板级 bring-up（来自 `/home/test/xilinx`）：`ebaz4205.cfg`、`scripts/{program-pl.sh,nand-flash.py,
    jtag-scan.sh,uart-poke.py,uboot-intercept.py}`、`buildroot-config/ebaz4205_defconfig` →
    `zynq_xpart/board/`、`zynq_xpart/scripts/`。
  - 待移植 RTL/固件：`neorv32_tpu/rtl/`、`riscv_tpu_demo/rtl/`、`rot_tpu_handoff/sw/stage2_loader/`
    → `zynq_xpart/rtl_src/`、`zynq_xpart/sw_src/`（仅作移植起点的副本）。
- 系统级工具（Vivado ML、prjxray）装在项目目录外（如 `/home/test/Xilinx`、`/home/test/prjxray`），不属于任何项目。
- 目录骨架：`zynq_xpart/{board,scripts,rtl,rtl_src,sw,sw_src,vivado,partial,docs}`。

---

## 目标硬件与现有资产

| 资产 | 路径 | 状态 |
|---|---|---|
| EBAZ4205 bring-up（Linux/NAND/fpgautil A-route，已验证） | `/home/test/xilinx` | ✅ 可直接复用 |
| Buildroot（含 `BR2_PACKAGE_XILINX_FPGAUTIL`） | `/home/test/xilinx/buildroot-config/ebaz4205_defconfig` | ✅ |
| JTAG 载入 / OpenOCD | `/home/test/xilinx/ebaz4205.cfg`、`scripts/program-pl.sh`、`scripts/jtag-scan.sh` | ✅ |
| NAND 烧录（含 mtd5 bitstream 槽） | `/home/test/xilinx/scripts/nand-flash.py` | ✅ |
| 待移植 RTL：PicoRV32+TPU | `/home/test/riscv_tpu_demo/rtl/`（soc_top.v, picorv32.v, tpu_accel.v, systolic_array_4x4.v, pe.v） | 🔁 Quartus→Vivado |
| 待移植 RTL：NEORV32（VHDL，含 RoT）+TPU | `/home/test/neorv32_tpu/rtl/`、`/home/test/neorv32_rot/` | 🔁 |
| CRTM 软件（modes g/G/c/H、lutcodec、measured-boot） | `/home/test/rot_tpu_handoff/`（patches + `sw/stage2_loader/`） | 🔁 重新接地到 Zynq |
| Vivado / Vitis | —— | ❌ 未装（Step 0） |

**EBAZ4205 约束**（来自 `/home/test/xilinx/CLAUDE.md`）：以太网坏（只能走 UART）；无 DIP、NAND 固定启动；
BOOT.BIN/FSBL/U-Boot 保持不动；自制 bitstream 经 **A-route**（`fpgautil -b` 或 `program-pl.sh`）在运行时载入，
不碰原厂启动链 → 与 DFX「先载静态 full、再热插拔 partial」完全兼容。

---

## 分阶段计划

### Step 0 — 工具链落地（前置，门槛）
- 腾出磁盘（Vivado ML + 7 系列器件支持约 80–120 GB）。先 `df -h`，必要时清 `/home/test/buildroot`、
  旧 `output/`、`tmp/` 等。
- 安装 **Vivado ML Standard（免费）**，安装时**只勾 7-series / Zynq-7000 器件支持**（省一半空间），
  并装 `Cable Drivers`。
- 在 WSL 下能跑 `vivado -mode batch`；确认 license 不需购买（DFX 在免费版已含）。
- 装 **prjxray**（`/home/test` 下 clone f4pga/prjxray + 7-series DB），跑通 `clb-lutinit` 相关工具的
  读取链，确认能从一个已知 frame 提取/写回 LUT-INIT 位。
- 产物：可用的 `vivado` + `prjxray` 环境；写一份 `xilinx/CLAUDE.md` 补丁记录环境路径与 `settings64.sh`。

### Phase 1 — "Hello PL"：先把自制 bitstream 的整条回路跑通（去风险）
*目的：在碰 DFX/ICAP 之前，先证明"我自己综合的 .bit 能在 EBAZ4205 上跑起来并被观察到"。*
- 新建最小 Vivado 工程（XC7Z010-1CLG400I）：Zynq PS（DDR3/UART1 按 EBAZ4205 引脚）+ 一个 AXI-GPIO 点灯/
  计数器 in PL。写 **EBAZ4205 XDC**（PS DDR/MIO 来自 board 既有配置；PL 侧引脚先最小化）。
- 综合出 `system.bit`，经 **A-route** 载入：`zynq_xpart/scripts/program-pl.sh system.bit`（JTAG，
  本地副本）或 Linux 内 `fpgautil -b system.bit`。用 `/dev/ebaz-uart` 观察 PS↔PL AXI 读写成功。
- 关键文件：`zynq_xpart/vivado/hello_pl/`（新建工程，全在独立目录内）。
- **里程碑 M1**：自制全比特流在板上 live 运行、PS 经 AXI 能读 PL 寄存器。

### Phase 2 — 移植 NEORV32 + TPU 到 Vivado，AXI 挂到 PS
*目的：把 EP4CE6 上的计算+RoT 核心搬到 Zynq PL，作为 DFX 的静态地基里的"被测元件"。*
- 选 **NEORV32（VHDL，vendor-neutral）** 作软核（移植成本最低；`riscv_tpu_demo` 的 PicoRV32 备选）。
  源码从 `zynq_xpart/rtl_src/`（拷自原项目的副本）移植到 `zynq_xpart/rtl/`，原项目不动。
- Quartus→Vivado 移植清单（逐项）：
  - `.qsf`/SDC → **`.xdc`** 约束。
  - Altera 推断 BRAM（`altsyncram`/M9K + `.mif/.hex` init）→ Xilinx **BRAM（RAMB36E1）**，
    init 用 `.mem`/`$readmemh`（IMEM ROM/DMEM/TPU LUT 全部）。
  - `(* multstyle="dsp" *)` 8×8 乘法 → **DSP48E1**（`(* use_dsp="yes" *)`；Zynq 有 80 块，无需像 EP4CE6 那样
    被迫把某个 PE 退回 LUT）。
  - **EPCS/`altasmi`/ALTREMOTE_UPDATE** 全部删除——Zynq 启动与配置由 PS 接管（见 Phase 3/5）。
  - SDRAM 控制器删除——改用 PS 的 **DDR3**（软核内存映射经 AXI 到 PS DDR，或软核用 PL BRAM + 经 AXI 访问 PS）。
- 把软核 + TPU 封成一个 **AXI4 从设备 / 或 AXI-Lite 控制 + AXI-master DMA**，挂到 Zynq PS 的 GP/HP 口。
- 顺手把 systolic 从 4×4 放大到 **8×8**（资源充裕，作为"Zynq 才做得到"的亮点之一）。
- **里程碑 M2**：PL 内 NEORV32 跑一段固件、TPU 算一次 MNIST tile、PS 经 AXI 读到结果。

### Phase 3 — Track A：DFX 打底（可重构分区 + PCAP 热插拔）
*这是 EP4CE6 物理做不到、Zynq 第一次拿到的"live partial reconfig"。*
- 在 Vivado DFX 流程里把 **加速器划为可重构分区（RP）**；静态区＝Zynq PS 接口 + NEORV32 RoT + AXI 互联。
- 为 RP 构建 ≥2 个 **Reconfigurable Module**（如 `rm_tpu_8x8`、`rm_alt_accel`/`rm_debug`），产出
  full bitstream + 每个 RM 的 **partial bitstream**。
- 运行时热插拔走 **PCAP**：Linux 内 `fpgautil -b rm_xxx.bit -f Partial`（FPGA Manager 的 partial 流程；
  静态区与 PS 不停机）。把这条对接进现有 `nand-flash.py`/mtd 持久化（partial bits 可放新 mtd 槽或 rootfs）。
- **里程碑 M3（对应 EP4CE6 的 Track A）**：板子运行中，TPU 分区从 8×8 热切换成另一个加速器，PS 侧业务不中断。

### Phase 4 — Track B：prjxray + ICAP 的 live LUT 真值表手术（头条）
*这是字面意义的 JBits/XPART——把 NN 权重烤进 LUT-INIT，并在晶片内 live 改它。*
- 在 RP 内放一块**权重以 LUT-INIT 承载**的小计算（延续 EP4CE6 mode B 的"权重→LUT TT"思路；先做
  constant-folding 风格的单/少数 LUT，验证可观察的功能变化）。
- 工具链：用 **prjxray 7-series DB** 定位该 LUT 的 INIT 位在 partial frame 中的位置（`clb-lutinit` 知识），
  host 侧改 INIT → 重组该 frame 的 partial bitstream（含 frame ECC/CRC 处理）。
- 注入走 **ICAP**：在 PL 内例化 **AXI HWICAP**（或自写轻量 ICAP 控制器），由 NEORV32/PS 把改好的单帧
  partial 推进 ICAP → **live、免冷启动、无停机**地改 LUT 真值表。可参考 VR-ZYCAP 式资源级 ICAP 控制器。
- 这一步把 EP4CE6 的 `lutcodec`/σ⁻¹/canon 那套逆向工程**整体替换**为 prjxray（7 系列格式已公开，
  不需要再自己 fuzz CRAM），是最大的工程减负点。
- **里程碑 M4（对应 EP4CE6 的 Track B，且首次 live）**：不重综合、不冷启动，改一个 LUT-INIT（如某权重位）
  后 TPU 输出按预期改变，ICAP 回读该帧 = host oracle 字节一致。

### Phase 5 — 信任锚 / CRTM 在 Zynq 上重新接地
*保留 rot_tpu_handoff 的安全叙事，但接到 Zynq 现实，不做不可逆硬件动作。*
- **measured-boot（软件锚，推荐）**：PS（U-Boot/Linux）在载入 full/partial bitstream 与软核固件前做
  hash 度量并比对白名单（沿用 `rot_tpu_handoff` 的 modes g/G/c 的"CRC/whitelist→载入"管线，移植成 PS 侧
  C 程序 + 现有 `nand-flash.py`/`fpgautil` 钩子）。软核作为"被 measured 的 RoT 元件"——其 IMEM ROM 镜像的
  hash 锚在 PS 的度量记录里。
- **Track B 的信任门**：任何 ICAP LUT 编辑前，先按 EP4CE6 的"editable-LE allowlist + 完整性门"思路，
  在 PS/软核侧对 partial frame 做白名单与回读校验，再放行 ICAP。
- **明确不做**：不烧 eFUSE、不开 Zynq 硬件 secure boot（RSA/AES）、不动原厂 BOOT.BIN/FSBL —— EBAZ4205
  要保 JTAG 可恢复，硬件 RoT 不可逆且对二手矿板有砖机风险。（如要 hardware-anchored，作为独立后续题目。）
- **里程碑 M5**：未通过度量的软核镜像 / 未在白名单的 partial frame 被拒载；通过的正常 live 生效。

---

## 哪些"可能能做到"（务实评估，回应用户问题）

| 能力 | 在 Zynq 上的可行性 | 备注 |
|---|---|---|
| 自制 full bitstream 在 EBAZ4205 live 跑（A-route） | **高**（基础设施已验证） | M1，先做 |
| NEORV32+TPU 移植、systolic 放大到 8×8/16×16 | **高** | 资源充裕；VHDL 软核移植友好 |
| **Track A：DFX 模块 live 热插拔（PCAP）** | **高** | 官方支持、免费版可用；EP4CE6 物理做不到的第一胜利 |
| **Track B：ICAP 单帧 LUT-INIT live 编辑** | **中**（有研究先例 + prjxray 格式已公开） | 主要风险：partial frame 的 ECC/CRC 重算、ICAP 控制器细节、单帧边界。建议先在 RP 内最小 LUT 上打通 |
| measured-boot 软件信任锚 + allowlist 门 | **高** | 复用现有 modes 管线，移到 PS 侧 |
| 硬件 RoT（eFUSE/RSA/AES secure boot） | **不在范围**（刻意） | 不可逆 + 砖机风险；独立题目 |

**整体判断**：用户的迁移直觉正确。EP4CE6 上"XPART 减去 live"的两条 track，在 Zynq 上都能升级为
**真·live**，且 Track B 不再需要自己逆向 bitstream 格式（prjxray 已做完）。最大不确定性集中在 Phase 4 的
ICAP 单帧注入工程细节——计划用 Phase 1–3 的稳健里程碑铺垫，把风险隔离在最后一步。

---

## 关键文件（全部在 `/home/test/zynq_xpart/` 内，原项目零改动）

- `zynq_xpart/vivado/hello_pl/`（M1 最小工程）、`zynq_xpart/vivado/zynq_xpart/`（主工程，DFX）
- `zynq_xpart/vivado/zynq_xpart/constraints/ebaz4205.xdc`（PS + PL 引脚约束，新建）
- `zynq_xpart/rtl/`（从 `rtl_src/` 副本移植的 NEORV32 + TPU；`rtl_src/` 是原项目只读拷贝）
- `zynq_xpart/scripts/load-partial.sh`（封装 `fpgautil -b … -f Partial`，PCAP 热插拔）
- `zynq_xpart/scripts/icap-lut-edit.py`（host：prjxray 定位 INIT 位 → 重组单帧 partial → 经 UART/AXI 交板上 ICAP 注入器）
- `zynq_xpart/sw/measured_boot/`（PS 侧 measured-boot，从 `sw_src/stage2_loader/` 的 modes g/G/c 副本移植）
- 板级脚本本地副本（拷自 `/home/test/xilinx`，仅动副本）：`zynq_xpart/board/ebaz4205.cfg`、
  `zynq_xpart/scripts/{program-pl.sh,nand-flash.py,jtag-scan.sh,uart-poke.py}`、
  `zynq_xpart/board/ebaz4205_defconfig`
- **明确不修改**：`/home/test/{xilinx,neorv32_tpu,neorv32_rot,riscv_tpu_demo,rot_tpu_handoff,EP4CE6}` 下任何文件

## 验证（端到端）
- 所有脚本均用 `zynq_xpart/` 内的本地副本运行（不调用原项目）。
- **M1**：`zynq_xpart/scripts/program-pl.sh hello.bit` → UART 内 PS 读 AXI-GPIO 计数器递增。
- **M2**：板上 NEORV32 固件经 UART 打印 + TPU 单 tile MNIST 结果，PS 经 AXI 读回一致。
- **M3（Track A）**：`load-partial.sh rm_alt.bit` 运行中切换分区，PS 业务/UART 心跳不中断；`fpgautil` 返回成功。
- **M4（Track B）**：`icap-lut-edit.py` 改一个权重 LUT-INIT → 不冷启动、TPU 输出按预期变化；ICAP 回读该帧
  hash = host oracle。
- **M5**：篡改/未白名单的镜像或 partial frame 被 measured-boot/allowlist 门拒载（负向用例）。
- 全程不碰 BOOT.BIN/FSBL；任何砖机经 JTAG（`zynq_xpart/scripts/jtag-scan.sh` + `program-pl.sh`）恢复。

## 参考来源
- Vivado ML Standard（免费）+ DFX + Zynq-7000 支持：
  <https://www.xilinx.com/products/design-tools/vivado/dynamic-function-exchange.html> ·
  <https://www.xilinx.com/products/design-tools/vivado/vivado-ml.html>
- DFX 用户指南 UG909：
  <https://www.xilinx.com/content/dam/xilinx/support/documents/sw_manuals/xilinx2020_2/ug909-vivado-partial-reconfiguration.pdf>
- Project X-Ray（7 系列 bitstream / LUT-INIT）：<https://github.com/f4pga/prjxray> ·
  <https://f4pga.readthedocs.io/projects/prjxray/en/latest/index.html>
- VR-ZYCAP：Zynq 资源级 ICAP 细粒度重构控制器：<https://www.mdpi.com/2079-9292/10/8/899>
- 内部依据：`/home/test/rot_tpu_handoff/docs/notes/cyclone_cram_mapper_modeH_reply_2026_05_31.txt`、
  `docs/plan.md`、`/home/test/xilinx/CLAUDE.md`
