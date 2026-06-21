// main.c — NEORV32 bare-metal firmware: on-board XOR TRAINING (M7.0b).
//
// The board trains a 2-4-1 leaky-MLP to solve XOR end-to-end: forward W·x on the
// 4x4 INT8 systolic array (the M6/M2 datapath), and loss / δ / outer-product /
// SGD update on the NEORV32 in software — the hybrid-QAT split from m7_plan.md
// (master weights Q8.8 in BRAM, INT8 forward view). The host only watches the
// LOSS curve fall over UART; no host does the math.
//
// The training math is the SHARED kernel (m7_kernel.h) already proven bit-exact
// against the numpy oracle on the host (sw/m7_train/train_xor.c). The ONLY thing
// this file adds is array_macc() implemented over the XBUS instead of plain C,
// so the board reproduces the oracle's final weights exactly (≤0 LSB by design).
//
// Forward path note: we use the array's RAW INT32 accumulator (RES0-3) and keep
// the VPU DISABLED (VPU_CTRL=0). The VPU's bias/leaky/requant is the *inference*
// path; training needs the unrequantized acc so the C kernel can apply its own
// Q8.8 requant + master-precision backward. So this runs on the M6 rm_tpuvpu RM
// with the VPU simply bypassed — no new RTL for M7.0b.

#include <neorv32.h>

#define BAUD_RATE 115200
#define TPU_BASE  0xF0000000U

#define TPU_CTRL    (*(volatile uint32_t *)(TPU_BASE + 0x00))
#define TPU_STATUS  (*(volatile uint32_t *)(TPU_BASE + 0x04))
#define TPU_W_ADDR  (*(volatile uint32_t *)(TPU_BASE + 0x08))
#define TPU_W_DATA4 (*(volatile uint32_t *)(TPU_BASE + 0x14))
#define TPU_X_IN    (*(volatile uint32_t *)(TPU_BASE + 0x10))
#define TPU_RES(r)  (*(volatile uint32_t *)(TPU_BASE + 0x20 + (r)*4))
#define VPU_CTRL    (*(volatile uint32_t *)(TPU_BASE + 0x30))
#define MBOX        (*(volatile uint32_t *)0xF1000000U)

// Mailbox loss-curve protocol (the PS / host polls 0x41200000 via `md`):
//   bit31=0  -> TRAINING checkpoint: bits[30:16]=epoch (<=3999), [15:0]=SSE
//   bit31=1  -> DONE: 0x80000000 | (XOR_score<<16) | (final_SSE & 0xFFFF)
// Checkpoints are dense over the first 200 epochs (every 20 — that is where the
// loss actually falls, ~469 -> ~0) then sparse (every 400) for the flat tail.
// Each checkpoint is HELD (busy loop) so a host md-poll at a few hundred ms can
// sample it; the epoch-0 peak is held 4x longer so watcher-start latency can't
// miss it (it did last time). NEORV32 uart0 is not pinned out on this board
// (dfx_top.v leaves uart0_txd_o open), so the mailbox is the only PS-visible
// channel — hence the loss curve goes through it, not printf.
#define M7_HOLD_ITERS  60000000u    // ~3-5 s/checkpoint depending on FCLK0

#define M7_BOARD            // exclude the golden self-check arrays from the build

// array_macc() over the XBUS: load 4 INT8 weight rows, run one matmul, read the
// signed INT32 accumulators RES0-3. Bound by m7_kernel.h's forward path.
static void array_macc_impl(const signed char Wi[4][4], const signed char xi[4], int32_t acc[4]) {
    for (int r = 0; r < 4; r++) {
        TPU_W_ADDR  = (uint32_t)(r << 2);
        TPU_W_DATA4 = ((uint32_t)(uint8_t)Wi[r][3] << 24) | ((uint32_t)(uint8_t)Wi[r][2] << 16) |
                      ((uint32_t)(uint8_t)Wi[r][1] <<  8) |  (uint32_t)(uint8_t)Wi[r][0];
    }
    TPU_CTRL = 0x10;        // clear accumulators (and done)
    TPU_X_IN = ((uint32_t)(uint8_t)xi[3] << 24) | ((uint32_t)(uint8_t)xi[2] << 16) |
               ((uint32_t)(uint8_t)xi[1] <<  8) |  (uint32_t)(uint8_t)xi[0];
    TPU_CTRL = 0x01;        // start matmul; STATUS.done fires when acc is ready
    while (!(TPU_STATUS & 1)) { }
    for (int i = 0; i < 4; i++) acc[i] = (int32_t)TPU_RES(i);
}

// the symbol m7_kernel.h expects:
void array_macc(const signed char Wi[4][4], const signed char xi[4], int32_t acc[4]) {
    array_macc_impl(Wi, xi, acc);
}

#include "m7_kernel.h"

static void print_row(const char *tag, const i64 *v, int n) {
    neorv32_uart0_printf("%s", tag);
    for (int i = 0; i < n; i++) neorv32_uart0_printf(" %d", (int32_t)v[i]);
    neorv32_uart0_printf("\n");
}

int main(void) {
    neorv32_rte_setup();
    neorv32_uart0_setup(BAUD_RATE, 0);

    neorv32_uart0_printf("\n=====================================\n");
    neorv32_uart0_printf("  NEORV32 on-chip XOR TRAINING (M7.0b)\n");
    neorv32_uart0_printf("  fwd W.x on 4x4 array, backprop in SW \n");
    neorv32_uart0_printf("=====================================\n");

    VPU_CTRL = 0;          // training uses the raw INT32 acc; VPU bypassed

    // self-check the array boundary once (tb_rm_tpuvpu T1: RES=14,40,28,6).
    {
        const signed char W[4][4] = {{1,1,1,1},{1,2,3,4},{2,2,2,2},{1,0,1,0}};
        const signed char X[4] = {2,3,4,5};
        int32_t acc[4];
        array_macc(W, X, acc);
        neorv32_uart0_printf("array self-check RES = %d %d %d %d (expect 14 40 28 6)\n",
                             acc[0], acc[1], acc[2], acc[3]);
    }

    i64 W1[4][4], W2[4][4], b1[4], b2[4];
    m7_init(W1, b1, W2, b2);

    neorv32_uart0_printf("training %d epochs (loss -> mailbox)...\n", M7_EPOCHS);
    i64 sse = 0;
    for (int ep = 0; ep < M7_EPOCHS; ep++) {
        sse = m7_epoch(ep, W1, b1, W2, b2);
        int do_ckpt = (ep < 200) ? (ep % 20 == 0) : (ep % 400 == 0);
        if (do_ckpt) {
            // publish a training checkpoint (bit31=0, epoch+SSE) and HOLD so the host samples it
            MBOX = ((uint32_t)ep << 16) | ((uint32_t)sse & 0xFFFF);
            uint32_t hold = (ep == 0) ? (M7_HOLD_ITERS * 4) : M7_HOLD_ITERS;
            for (volatile uint32_t d = 0; d < hold; d++) { }
        }
    }

    // final weights — host compares these against the oracle golden (expect exact).
    neorv32_uart0_printf("--- trained master weights (Q8.8) ---\n");
    print_row("W1r0", W1[0], 2); print_row("W1r1", W1[1], 2);
    print_row("W1r2", W1[2], 2); print_row("W1r3", W1[3], 2);
    print_row("b1  ", b1, 4);
    print_row("W2r0", W2[0], 4);
    neorv32_uart0_printf("b2 %d\n", (int32_t)b2[0]);

    int ok = 0;
    for (int s = 0; s < 4; s++) {
        i64 z1[4], h[4], z2[4], y[4];
        m7_forward(W1, b1, W2, b2, M7_XP[s], z1, h, z2, y);
        int pred = (y[0] > M7_ONE / 2);
        ok += (pred == (M7_TV[s] > M7_ONE / 2));
        neorv32_uart0_printf("xor[%d] y=%d pred=%d\n", s, (int32_t)y[0], pred);
    }
    neorv32_uart0_printf("XOR %d/4  final sse %d  TRAIN DONE\n", ok, (int32_t)sse);

    // DONE marker (bit31=1): XOR score + final SSE. Held forever so the host
    // poll sees a stable end-of-curve sentinel.
    uint32_t done = 0x80000000u | ((uint32_t)ok << 16) | ((uint32_t)sse & 0xFFFF);
    uint32_t led = 0xF;
    while (1) {
        MBOX = done;
        neorv32_gpio_port_set(led);
        led ^= 0xF;
        for (volatile uint32_t d = 0; d < 400000; d++) { }
    }
    return 0;
}
