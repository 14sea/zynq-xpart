// main_mnist.c — NEORV32 bare-metal firmware: on-board MNIST-tile TRAINING (M7.4).
//
// The bigger-workload sibling of main.c (XOR). The board trains a 64(=8x8)->8->4
// leaky-MLP to classify MNIST digits 0-3 end-to-end: forward W·x AND backward Wᵀ·δ
// run on the 4x4 INT8 systolic array (tiled), NEORV32 software does loss / δ /
// outer-product / full-batch SGD update. This is the M7.1 path (rm_tpuvpu / rm1_tpu
// array + SW backprop), which is HW-verified multi-epoch — NOT the M7.2 rm_train
// HW-trio path.
//
// The shared kernel (m7_mnist_kernel.h) is proven bit-exact against the numpy oracle
// on the host (mnist_host.c: weight/loss/acc mism=0, test acc 25%->90%). This file
// adds only the XBUS array_macc leaf accessor so the board reproduces that curve.
//
// ON-BOARD STATUS (2026-07-02, EBAZ4205, rm_tpuvpu via fpga loadb): DONE. The
// earlier 2026-06-28 failures were not a DFX/build-band effect; the linker had left
// NEORV32 RAM at its 8 KB default while the RTL DMEM is 16 KB, causing .bss/stack
// collision in the heavy m7_epoch loop. With the Makefile's 16 KB defsym and the
// image_gen LMA-gap fix, this 64->8->4 firmware trains for 60 epochs on-board and
// matches the numpy oracle at every sampled checkpoint. See docs/m7_plan.md §M7.4.
//
// Build (bakes neorv32_imem_image.vhd; then rebuild the static via build_dfx.tcl):
//   make APP_SRC=main_mnist.c NEORV32_HOME=../../rtl_src/neorv32_tpu/neorv32 \
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

// Mailbox MNIST curve protocol (PS / host polls 0x41200000 via `md`):
//   bit31=0 checkpoint: [30:24]=epoch  [23:16]=test_correct(0..NTEST)  [15:0]=SSE
//   bit31=1 DONE:       [30:24]=peak_correct  [23:16]=final_correct    [15:0]=final SSE
#define MB_CKPT(ep, cor, sse)  (((uint32_t)(ep) << 24) | ((uint32_t)(cor) << 16) | ((uint32_t)(sse) & 0xFFFF))
#define MB_DONE(pk, fin, sse)  (0x80000000u | ((uint32_t)(pk) << 24) | ((uint32_t)(fin) << 16) | ((uint32_t)(sse) & 0xFFFF))

#define M7_HOLD_ITERS   500000u      // brief per-epoch pause so the UART `md` poller samples

#define M7_BOARD            // exclude the golden self-check arrays from the build

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
// mailbox and SPIN (so a fault doesn't look like a silent reboot). Cycles three frames
// so the slow UART poller reads each: 0xDEAD|cause, 0xBADC|epc_lo, 0xBAD1|epc_hi.
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
    // Master weights stack-local; the 4 KB gradient accumulator is static in m7_epoch
    // (m7_mnist_kernel.h) so the two never pile up on the 16 KB board DMEM stack.
    i64 W1[M7M_NH][M7M_NIN], b1[M7M_NH], W2[M7M_NOUT][M7M_NH], b2[M7M_NOUT];
    neorv32_rte_setup();
    // Report a CPU exception over the mailbox instead of a silent reboot.
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

    // Short chunked heartbeat/pacing window before the long training loop. This is
    // retained for host-side visibility only; no hardware settle requirement remains.
    for (uint32_t kk = 0; kk < 20; kk++) {
        MBOX = 0x7C000000u | kk;
        for (volatile uint32_t d = 0; d < 500000u; d++) { }
    }
    MBOX = 0x7C0000FFu;          // settle done

    m7_init(W1, b1, W2, b2);
    MBOX = 0x7D002000u;          // init done

    // Full-batch training: each epoch runs m7_epoch (forward + backward on the array,
    // SW accumulate + one SGD update) then evaluates the held-out test tile, and
    // publishes (epoch, test_correct, SSE) over the mailbox for scripts/m7-watch-mnist.py.
    i64 sse = 0;
    int peak = 0, cor = 0;
    for (int ep = 0; ep < M7M_EPOCHS; ep++) {
        sse = m7_epoch(W1, b1, W2, b2);
        cor = m7_test_correct(W1, b1, W2, b2);
        if (cor > peak) peak = cor;
        MBOX = MB_CKPT(ep, cor, (uint32_t)sse);
        for (volatile uint32_t d = 0; d < M7_HOLD_ITERS; d++) { }   // brief pause so the poller samples
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
