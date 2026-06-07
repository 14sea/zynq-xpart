// main.c — NEORV32 firmware: fabric self-modifies via ICAP (zynq_xpart T2.3).
//
// CANONICAL SOURCE (the build working-tree under sw_src/ is gitignored). Build it the
// same way as sw/tpu_firmware (see docs/firmware_build.md): copy over the build tree's
// main.c, then `make ... install` to bake neorv32_imem_image.vhd.
//
// The soft-core streams a single-frame configuration write to the in-fabric xbus_icap
// controller -> ICAPE2, rewriting one CRAM frame (a LUT6 truth table) live. The frame
// payload is staged by the PS into a shared AXI-Lite framebuf (read here at 0xF5000000);
// the reconfiguration EXECUTION (read framebuf -> drive ICAP -> write CRAM) is 100% in
// fabric. The PS only stages the payload, grants ICAP (devcfg PCAP_PR=0), and observes.
// Verified on EBAZ4205: lut_o flips 0->1, mbox reports winning swap mode 1.
//
// XBUS map (neorv32_soc_icap):
//   0xF1000000 MBOX     status -> PS (AXI-GPIO ch2 @ 0x41200008)
//   0xF3000000 xbus_icap controller (0x00 fill, 0x04 wptr=0, 0x08 burst N, 0x0C swmode)
//   0xF4000000 LUT readback -> lut_probe output bit0 (the edit, NEORV32-visible)
//   0xF5000000 frame framebuf: [0]=length N (PS writes last = ready flag), [1..N]=seq

#include <neorv32.h>

#define ICAP_BASE   0xF3000000U
#define ICAP_DATA   (*(volatile uint32_t *)(ICAP_BASE + 0x00))
#define ICAP_WPTR0  (*(volatile uint32_t *)(ICAP_BASE + 0x04))
#define ICAP_BURST  (*(volatile uint32_t *)(ICAP_BASE + 0x08))
#define ICAP_SWMODE (*(volatile uint32_t *)(ICAP_BASE + 0x0C))
#define MBOX        (*(volatile uint32_t *)0xF1000000U)
#define LUT_RB      (*(volatile uint32_t *)0xF4000000U)
#define FB          ((volatile uint32_t *)0xF5000000U)   // [0]=len, [1..len]=seq

// Stream FB[1..n] to the ICAP controller using swap mode `mode`.
static void icap_write(uint32_t n, uint32_t mode) {
    ICAP_SWMODE = mode;
    ICAP_WPTR0  = 0;
    for (uint32_t i = 0; i < n; i++)
        ICAP_DATA = FB[1 + i];
    ICAP_BURST = n;                                  // trigger the write burst
    for (volatile uint32_t d = 0; d < 4000; d++) { }
}

int main(void) {
    uint32_t hb = 0, good_mode = 0xFFu;
    const uint32_t modes[4] = {1u, 0u, 2u, 3u};      // ICAPE2 wants per-byte bit-reverse

    while (1) {
        uint32_t n = FB[0];                          // length staged by the PS (0 = not ready)
        if (n > 0u && n <= 255u && (LUT_RB & 1u) == 0u) {
            for (int k = 0; k < 4; k++) {
                icap_write(n, modes[k]);
                if ((LUT_RB & 1u) == 1u) { good_mode = modes[k]; break; }
            }
        }
        // status: tag 0xC3 | heartbeat | winning swap mode | live LUT bit
        MBOX = 0xC3000000u | ((hb & 0xFFu) << 16) | ((good_mode & 0xFFu) << 8) | (LUT_RB & 1u);
        hb++;
        for (volatile uint32_t d = 0; d < 300000; d++) { }
    }
    return 0;
}
