// main_tiny.c — NEORV32 bare-metal firmware: on-board TINY training (M7.4-tiny).
//
// The SMALL-firmware sibling of main_mnist.c, sized to fit the EBAZ4205 "good
// build band" so the multi-epoch training actually runs ON-BOARD. Trains a
// 16(=4x4)->4->2 leaky-MLP to classify MNIST digits 0 vs 1: forward W·x AND
// backward Wᵀ·δ on the 4x4 INT8 systolic array (tiled), NEORV32 SW does loss /
// δ / outer-product / full-batch SGD update. M7.1 path (rm_tpuvpu array + SW
// backprop, HW-verified multi-epoch) — NOT the M7.2 rm_train HW-trio.
//
// Why tiny: the 64-8-4 MNIST firmware (main_mnist.c) is host-bit-exact but its
// ~6 KB baked dataset pushed IMEM into the M7.2-class 7-series-DFX "bad band"
// (array miscompute/reset). The tiny net bakes 4x less data (16 vs 64 int8 per
// sample), shrinking IMEM toward the XOR trainers' verified-good size band.
//
// The shared kernel (m7_mnist_kernel.h) is proven bit-exact vs sim/oracle_tiny.py
// on the host (tiny_host.c: weight/loss/acc mism=0, test acc 50%->97.5%, peak
// 100%). This file differs from main_mnist.c ONLY in the vectors header it bakes.
//
// Mailbox curve protocol + watcher (scripts/m7-watch-mnist.py) are unchanged.
//
// Build (bakes neorv32_imem_image.vhd; then rebuild the static via build_dfx.tcl):
//   make APP_SRC=main_tiny.c NEORV32_HOME=../../rtl_src/neorv32_tpu/neorv32 \
//        RISCV_PREFIX=riscv64-unknown-elf- USER_FLAGS+="-specs=picolibc.specs" clean install

#include <neorv32.h>

#define BAUD_RATE 115200
#define TPU_BASE  0xF0000000U

// --- 4x4 array (wb_tpu_accel) registers ---
#define TPU_CTRL    (*(volatile uint32_t *)(TPU_BASE + 0x00))
#define TPU_STATUS  (*(volatile uint32_t *)(TPU_BASE + 0x04))
#define TPU_W_ADDR  (*(volatile uint32_t *)(TPU_BASE + 0x08))
#define TPU_W_DATA4 (*(volatile uint32_t *)(TPU_BASE + 0x14))
#define TPU_X_IN    (*(volatile uint32_t *)(TPU_BASE + 0x10))
#define TPU_RES(r)  (*(volatile uint32_t *)(TPU_BASE + 0x20 + (r)*4))
#define MBOX        (*(volatile uint32_t *)0xF1000000U)

// Mailbox curve protocol (PS / host polls 0x41200000 via `md`):
//   bit31=0 checkpoint: [30:24]=epoch  [23:16]=test_correct(0..NTEST)  [15:0]=SSE
//   bit31=1 DONE:       [30:24]=peak_correct  [23:16]=final_correct    [15:0]=final SSE
#define MB_CKPT(ep, cor, sse)  (((uint32_t)(ep) << 24) | ((uint32_t)(cor) << 16) | ((uint32_t)(sse) & 0xFFFF))
#define MB_DONE(pk, fin, sse)  (0x80000000u | ((uint32_t)(pk) << 24) | ((uint32_t)(fin) << 16) | ((uint32_t)(sse) & 0xFFFF))

#define M7_HOLD_ITERS   500000u      // brief per-epoch pause so the UART `md` poller samples

#define M7_BOARD            // exclude the golden self-check arrays from the build
#define M7M_VECTORS_H "m7_tiny_vectors.h"   // <-- the only difference vs main_mnist.c

#include <stdint.h>
typedef int64_t i64;

// ── 4x4 array over XBUS (forward W·x and transpose Wᵀ·δ; raw INT32 acc) ──────────
// hw_flush: empirical post-config scrub before each matmul (see M7.1 main.c note).
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

// Trap reporter: on any CPU exception, publish mcause + faulting PC (mepc) over the
// mailbox and SPIN (so a fault doesn't look like a silent reboot).
static void m7_trap_report(void) {
    uint32_t cause = neorv32_cpu_csr_read(CSR_MCAUSE);
    uint32_t epc   = neorv32_cpu_csr_read(CSR_MEPC);
    while (1) {
        MBOX = 0xDEAD0000u | (cause & 0xFFFF);
        for (volatile uint32_t d = 0; d < 4000000u; d++) { }
        MBOX = 0xBADC0000u | (epc & 0xFFFF);
        for (volatile uint32_t d = 0; d < 4000000u; d++) { }
        MBOX = 0xBAD10000u | ((epc >> 16) & 0xFFFF);
        for (volatile uint32_t d = 0; d < 4000000u; d++) { }
    }
}

int main(void) {
    MBOX = 0x7A000000u;          // heartbeat: NEORV32 reached main()
    i64 W1[M7M_NH][M7M_NIN], b1[M7M_NH], W2[M7M_NOUT][M7M_NH], b2[M7M_NOUT];
    neorv32_rte_setup();
    neorv32_rte_handler_install(TRAP_CODE_I_MISALIGNED, m7_trap_report);
    neorv32_rte_handler_install(TRAP_CODE_I_ACCESS,     m7_trap_report);
    neorv32_rte_handler_install(TRAP_CODE_I_ILLEGAL,    m7_trap_report);
    neorv32_rte_handler_install(TRAP_CODE_L_MISALIGNED, m7_trap_report);
    neorv32_rte_handler_install(TRAP_CODE_L_ACCESS,     m7_trap_report);
    neorv32_rte_handler_install(TRAP_CODE_S_MISALIGNED, m7_trap_report);
    neorv32_rte_handler_install(TRAP_CODE_S_ACCESS,     m7_trap_report);
    neorv32_uart0_setup(BAUD_RATE, 0);

    // self-check the array boundary once (tb_rm_tpuvpu T1: RES=14,40,28,6).
    {
        const signed char W[4][4] = {{1,1,1,1},{1,2,3,4},{2,2,2,2},{1,0,1,0}};
        const signed char X[4] = {2,3,4,5};
        int32_t acc[4];
        array_macc(W, X, acc);
        MBOX = 0x7B000000u | ((uint32_t)acc[0] & 0xFFFF);   // array OK (expect ..0x0E)
    }

    // M7.1 post-config SETTLE — chunked busy loop with per-chunk heartbeat 0x7C0000kk.
    for (uint32_t kk = 0; kk < 20; kk++) {
        MBOX = 0x7C000000u | kk;
        for (volatile uint32_t d = 0; d < 500000u; d++) { }
    }
    MBOX = 0x7C0000FFu;          // settle done

    m7_init(W1, b1, W2, b2);
    MBOX = 0x7D002000u;          // init done

    // Full-batch training: m7_epoch (forward+backward on array, SW SGD), then eval
    // the held-out test tile, publishing (epoch, test_correct, SSE) over the mailbox.
    i64 sse = 0;
    int peak = 0, cor = 0;
    for (int ep = 0; ep < M7M_EPOCHS; ep++) {
        sse = m7_epoch(W1, b1, W2, b2);
        cor = m7_test_correct(W1, b1, W2, b2);
        if (cor > peak) peak = cor;
        MBOX = MB_CKPT(ep, cor, (uint32_t)sse);
        for (volatile uint32_t d = 0; d < M7_HOLD_ITERS; d++) { }
    }

    uint32_t done = MB_DONE(peak, cor, (uint32_t)sse);
    uint32_t led = 0xF;
    while (1) {
        MBOX = done;
        neorv32_gpio_port_set(led);
        led ^= 0xF;
        for (volatile uint32_t d = 0; d < 400000; d++) { }
    }
    return 0;
}
