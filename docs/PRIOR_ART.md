# Prior art — what in this project was already done or documented by others

Added 2026-11-03 after a full-text literature review and a check against AMD
documentation (UG470 v1.17, UG585 v1.15, PG134 v3.0, DS187 v1.21).

**Bottom line:** live single-frame LUT-INIT editing over ICAP, driven by an on-chip
processor, was published from 2003 on (Xilinx's own XPART/HWICAP work is the namesake of
this repo). The Zynq ICAP hand-off details this repo "solved" are in AMD's documentation.
What this repo adds is a working, open reproduction on the XC7Z010/EBAZ4205 with prjxray as
the bit-location layer, plus a written record of the pitfalls. It is a reproduction and a
lab notebook, not a discovery.

## 1. Mechanisms

| What we do | Prior work | Similarity | Our actual difference |
|---|---|---|---|
| Embedded processor rewrites configuration frames through ICAP at run time | Blodget, McMillan, Lysaght, "A lightweight approach for embedded reconfiguration of FPGAs", DATE 2003 (XPART / HWICAP); Blodget et al., "A self-reconfiguring platform", FPL 2003 | Same mechanism; XPART even had a LUT-level API (never released) | Zynq-7000, open tooling |
| Read-modify-write of the frames holding one LUT, from a soft-core | Hübner, Schuck, Becker, IPDPS 2006 RAW (MicroBlaze, Virtex-II: "Readback-Modify-Writeback" of the frames that hold a LUT or routing resource); Glette & Kaufmann, CEC 2014 (MicroBlaze + XPS HWICAP `SetClbBits`, Virtex-5: reads the frame, changes one LUT, writes it back) | They keep the rest of the frame | **We overwrite whole frames** from a build-time snapshot (prior work is ahead here) |
| Single-LUT edit on Zynq-7000 | Sultana et al., VR-ZyCAP, Electronics 2021 (PL FSM, 10.87 µs/LUT); García et al., Electronics 2020 (IMPRESS, open source, LUT constants via ICAP, 41.7 µs per configuration) | Same chip family | prjxray bit location; a PS-driven and a NEORV32-driven flavour |
| Bitstream-level LUT location by controlled diff | Moraitis & Dubrova 2022 (iterative LUT modification, 7-series); Puschner et al., PatchingFPGAs 2024 (prjxray + RapidWright); ZyEHW (XAPP290-style diff of one LUT) | Same idea | — |
| DFX module hot-swap over PCAP (Track A) | Vendor-supported flow (Vivado DFX) | Standard | — |

## 2. Pitfalls this repo recorded — and where AMD documents them

| Pitfall (our wording) | Vendor documentation | Status |
|---|---|---|
| ICAP only works after `devcfg.CTRL[PCAP_PR]=0` ("the one missing piece") | UG585 v1.15, *PL Configuration Paths* (printed p.125): "To enable the ICAP path … set the [PCAP_MODE] bit = 1 and the [PCAP_PR] bit = 0. The ICAP path is used when a MicroBlaze processor is controlling the PL reconfiguration" | **Documented**; we missed it at first |
| Do not send GRESTORE / GTS during a live edit | UG470 v1.17 p.103: GRESTORE "sets/resets … IOB and CLB flip-flops" | **Follows from the documented definition** |
| A frame write needs a pad frame; two non-contiguous FAR sets in one envelope mis-commit | UG470 v1.17 p.102: FAR "can be auto-incremented at the end of each frame"; frame data is buffered (pad frames in the bitstream examples) | Consistent with the documented frame buffer. Contiguous frames can share one FDRI write via auto-increment; **MFW is unrelated** (UG470 p.103: it writes one frame's data to several addresses) |
| HWICAP read FIFO (~128) too shallow for a 202-word frame readback; "not a parameter on the stock IP" | PG134 (2025-01-30), printed p.26: Read FIFO depth selectable **128 or 256** (actual depth one less) | **Our statement was wrong** — 256 fits one frame plus the readback pad |
| Frame without the ECC word (word 50) "silently does nothing" | UG470 does not say frame writes check ECC (ECC syndrome calibration is described only for readback CRC, p.143) | **Not re-tested in isolation**; may have been confounded with the PCAP_PR hand-off |
| ICAP clock | DS187 v1.21 p.69: F<sub>ICAPCK</sub> max 100 MHz | FCLK0 left at 125 MHz by the miner FSBL is out of spec; the flow pins 50 MHz |
| ICAP read/write turnaround | UG470 v1.17 p.38/43/120: toggling RDWR_B while CSI_B is low triggers ABORT; deassert CSI_B, toggle, reassert | `rtl/xbus_icap.v` (first-attempt artifact) does not follow this for reads |

## 3. References

- Blodget, McMillan, Lysaght. DATE 2003, doi:10.1109/DATE.2003.1253642. — Blodget et al. FPL 2003, LNCS 2778, doi:10.1007/978-3-540-45234-8_55.
- Hübner, Schuck, Becker. Elementary block based 2-dimensional dynamic and partial reconfiguration for Virtex-II FPGAs. IPDPS 2006 (RAW).
- Glette, Kaufmann. CEC 2014, doi:10.1109/CEC.2014.6900503.
- Sultana et al. VR-ZYCAP. Electronics 2021. Code: github.com/bushra-sultana/VR-ZyCAP.
- García, Zamacola, Otero, de la Torre. Electronics 9(5):803, 2020, doi:10.3390/electronics9050803.
- Moraitis, Dubrova. FPGA design deobfuscation by iterative LUT modification at bitstream level. IACR ePrint 2022/325.
- Puschner et al. Patching FPGAs. arXiv:2411.11060, 2024.
- AMD UG470 v1.17, UG585 v1.15, PG134 v3.0, DS187 v1.21.
