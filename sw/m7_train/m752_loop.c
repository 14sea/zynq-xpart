// m752_loop.c — M7.5.2 single-session train -> checkpoint-to-fabric -> infer loop.
//
// ONE static-region NEORV32 image drives the WHOLE loop across a host DFX swap +
// ICAP weight-bake, PS/NEORV32 NEVER reset (the M7.3 m73_yield.c dual-phase pattern
// + the M7.5.1 ICAP checkpoint):
//
// Phase 1 (rm_tpuvpu loaded at boot): train the 16-4-2 tiny net (M7.4-tiny: forward
//   W·x AND backward Wᵀ·δ on the 4x4 INT8 array, SW full-batch SGD) to convergence,
//   publish a brief loss curve, then publish the converged FIRST L1 tile W1[0:4][0:4]
//   in its INT8 (baked) view — 16 values, tags 0xE0..0xEF — so the host can READ the
//   board's learned weights and verify them == the oracle BEFORE baking. Then READY.
//
// [host, no reset:  read+verify the 16 weights == oracle tile;  loadbp swap
//  rm_tpuvpu -> rm_lutkcm;  ICAP-bake the 18 trained-tile frames (PCAP_PR=0).]
//
// Phase 2 (rm_lutkcm loaded after the swap; weights baked in LUTs, ICAP-edited to the
//   trained values): run the M6 VPU path (feed x={2,3,4,5}, bias/leaky/requant) and
//   publish {POST3..POST0}. rm_lutkcm ignores weight loads (weights ARE the LUTs), so
//   no load_weights — the baked (now trained) weights compute: mailbox baseline
//   0x1019391F -> after the host's ICAP bake -> 0x7F7FE57F (= the trained tile, the
//   M7.5.1 functional golden). => the chip trained, handed off, reconfigured its
//   inference fabric, baked its learned weights in, and computed — all one session.
//
// Mailbox protocol (PS polls 0x41200000):
//   bit31=0, [30:24]=ep [23:16]=test_correct [15:0]=SSE : phase-1 loss-curve checkpoint
//   0xE0..0xEF in [31:24], [7:0]=signed INT8           : converged W1 tile value #idx
//   0x600D0000                                          : READY (host may swap+bake)
//   else (e.g. 0x1019391F / 0x7F7FE57F)                : phase-2 packed {POST3..POST0}
//
// Build (then rebuild the unified static via build_dfx.tcl):
//   make APP_SRC=m752_loop.c NEORV32_HOME=../../rtl_src/neorv32_tpu/neorv32 \
//        RISCV_PREFIX=riscv64-unknown-elf- USER_FLAGS+="-specs=picolibc.specs" clean install

#include <neorv32.h>

#define BAUD_RATE 115200
#define TPU_BASE  0xF0000000U

#define TPU_CTRL    (*(volatile uint32_t *)(TPU_BASE + 0x00))
#define TPU_STATUS  (*(volatile uint32_t *)(TPU_BASE + 0x04))
#define TPU_W_ADDR  (*(volatile uint32_t *)(TPU_BASE + 0x08))
#define TPU_W_DATA4 (*(volatile uint32_t *)(TPU_BASE + 0x14))
#define TPU_X_IN    (*(volatile uint32_t *)(TPU_BASE + 0x10))
#define TPU_RES(r)  (*(volatile uint32_t *)(TPU_BASE + 0x20 + (r)*4))
// M6 VPU window (present in rm_tpuvpu and rm_lutkcm)
#define VPU_CTRL    (*(volatile uint32_t *)(TPU_BASE + 0x30))
#define VPU_BIAS    (*(volatile uint32_t *)(TPU_BASE + 0x34))
#define VPU_SCALE   (*(volatile uint32_t *)(TPU_BASE + 0x38))
#define VPU_SHIFT   (*(volatile uint32_t *)(TPU_BASE + 0x3C))
#define VPU_POST(r) (*(volatile uint32_t *)(TPU_BASE + 0x40 + (r)*4))
#define VPU_ALPHA   (*(volatile uint32_t *)(TPU_BASE + 0x50))
#define MBOX        (*(volatile uint32_t *)0xF1000000U)

#define VPU_EN 0x1
#define VPU_ACT 0x2
#define VPU_BIAS_EN 0x4

#define M752_READY   0x600D0000u
#define M752_HOLD    1200000u        // per phase-1 checkpoint / weight word (md poll window)

#define M7_BOARD
#define M7M_VECTORS_H "m7_tiny_vectors.h"

#include <stdint.h>
typedef int64_t i64;

// ── 4x4 array over XBUS (phase-1 training: forward W·x and transpose Wᵀ·δ) ──────────
static void hw_flush(void) {
    for (int r = 0; r < 4; r++) { TPU_W_ADDR = (uint32_t)(r << 2); TPU_W_DATA4 = 0; }
    TPU_CTRL = 0x10;
    TPU_X_IN = 0;
    __asm__ volatile("fence" ::: "memory");
    TPU_CTRL = 0x01;
    while (!(TPU_STATUS & 1)) { }
    TPU_CTRL = 0x10;
}
void array_macc(const signed char Wi[4][4], const signed char xi[4], int32_t acc[4]) {
    hw_flush();
    for (int r = 0; r < 4; r++) {
        TPU_W_ADDR  = (uint32_t)(r << 2);
        TPU_W_DATA4 = ((uint32_t)(uint8_t)Wi[r][3] << 24) | ((uint32_t)(uint8_t)Wi[r][2] << 16) |
                      ((uint32_t)(uint8_t)Wi[r][1] <<  8) |  (uint32_t)(uint8_t)Wi[r][0];
    }
    TPU_CTRL = 0x10;
    TPU_X_IN = ((uint32_t)(uint8_t)xi[3] << 24) | ((uint32_t)(uint8_t)xi[2] << 16) |
               ((uint32_t)(uint8_t)xi[1] <<  8) |  (uint32_t)(uint8_t)xi[0];
    __asm__ volatile("fence" ::: "memory");
    TPU_CTRL = 0x01;
    while (!(TPU_STATUS & 1)) { }
    for (int i = 0; i < 4; i++) acc[i] = (int32_t)TPU_RES(i);
}

#include "m7_mnist_kernel.h"

static void pub(uint32_t w) {
    __asm__ volatile("fence" ::: "memory");
    MBOX = w;
    for (volatile uint32_t d = 0; d < M752_HOLD; d++) { }
}

// Phase-2 VPU inference (M6 path; rm_lutkcm ignores weight loads -> baked weights compute).
static uint32_t run_vpu(void) {
    VPU_SCALE = 181; VPU_SHIFT = 7; VPU_ALPHA = 4;
    TPU_W_ADDR = 0; VPU_BIAS = (uint32_t)8;        // wrapper snoops W_ADDR[1:0]=lane
    TPU_W_ADDR = 1; VPU_BIAS = (uint32_t)0;
    TPU_W_ADDR = 2; VPU_BIAS = (uint32_t)(int32_t)-10;
    TPU_W_ADDR = 3; VPU_BIAS = (uint32_t)5;
    VPU_CTRL = VPU_EN | VPU_ACT | VPU_BIAS_EN;
    TPU_CTRL = 0x10;                               // clear accumulators
    TPU_X_IN = (5u << 24) | (4u << 16) | (3u << 8) | 2u;   // x={x0..x3}={2,3,4,5}
    __asm__ volatile("fence" ::: "memory");
    TPU_CTRL = 0x01;
    while (!(TPU_STATUS & 1)) { }
    return (((uint32_t)VPU_POST(3) & 0xFF) << 24) | (((uint32_t)VPU_POST(2) & 0xFF) << 16) |
           (((uint32_t)VPU_POST(1) & 0xFF) <<  8) |  ((uint32_t)VPU_POST(0) & 0xFF);
}

int main(void) {
    MBOX = 0x7A000000u;
    i64 W1[M7M_NH][M7M_NIN], b1[M7M_NH], W2[M7M_NOUT][M7M_NH], b2[M7M_NOUT];
    neorv32_rte_setup();

    // post-config settle before any compute (M7.1), chunked w/ heartbeat.
    for (uint32_t kk = 0; kk < 20; kk++) { MBOX = 0x7C000000u | kk;
        for (volatile uint32_t d = 0; d < 500000u; d++) { } }

    // ── PHASE 1: train the tiny net on rm_tpuvpu (M7.4-tiny). ──
    m7_init(W1, b1, W2, b2);
    i64 sse = 0; int peak = 0, cor = 0;
    for (int ep = 0; ep < M7M_EPOCHS; ep++) {
        sse = m7_epoch(W1, b1, W2, b2);
        cor = m7_test_correct(W1, b1, W2, b2);
        if (cor > peak) peak = cor;
        if (ep % 10 == 0 || ep == M7M_EPOCHS - 1) {      // brief curve (every 10th + last)
            MBOX = ((uint32_t)ep << 24) | ((uint32_t)cor << 16) | ((uint32_t)sse & 0xFFFF);
            for (volatile uint32_t d = 0; d < M752_HOLD; d++) { }
        }
    }

    // publish the converged FIRST L1 tile in its INT8 (baked) view: W1[r][0..3], r=0..3.
    // tags 0xE0..0xEF, value = signed INT8 in the low byte. Host verifies == oracle tile.
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++) {
            int idx = r * 4 + c;
            int8_t wi8 = (int8_t)m7_q8(W1[r][c], M7M_WSHIFT);
            pub(((uint32_t)(0xE0 + idx) << 24) | ((uint32_t)(uint8_t)wi8));
        }
    pub(M752_READY);

    // ── PHASE 2: infer on rm_lutkcm (host has swapped + ICAP-baked by now). ──
    // baked weights compute via the VPU: baseline 0x1019391F -> trained 0x7F7FE57F.
    uint32_t led = 0xF;
    while (1) {
        MBOX = run_vpu();
        neorv32_gpio_port_set(led);
        led ^= 0xF;
        for (volatile uint32_t d = 0; d < 1500000u; d++) { }
    }
    return 0;
}
