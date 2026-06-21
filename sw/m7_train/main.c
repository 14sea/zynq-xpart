// main.c — NEORV32 bare-metal firmware: on-board XOR TRAINING with the trio in HW (M7.2).
//
// The board trains a 2-4-1 leaky-MLP to solve XOR end-to-end. Versus M7.1, the loss /
// leaky' / δ / SGD-update and the MASTER WEIGHTS now live in hardware (train_unit.v,
// the rm_train DFX module); firmware only SEQUENCES. Software still does the forward
// requant+bias+leaky (unchanged from M7.1) and the two systolic matmuls (forward W·x,
// backward Wᵀ·δ via transpose-load) on the 4x4 INT8 array, plus the 16-MAC rank-1
// outer products dW=δ⊗xᵀ (the M7.2 scope decision: trio in HW, outer-product in SW).
//
// The shared kernel (m7_kernel_hw.h) is proven bit-exact against the numpy oracle on
// the host (train_xor_hw.c: weight/loss mism=0, XOR 4/4, SSE=0), and train_unit.v is
// proven bit-exact in sim (sim/tb_train.v). This file only adds the XBUS leaf
// accessors (array_macc + the tu_*) so the board reproduces the oracle's loss curve.
//
// The C master arrays are a MIRROR refreshed from the TU after every update — the
// hardware copy (in train_unit) is authoritative.

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

// --- train_unit window (rm_train wrapper claims base 0x800; word w -> byte w*4) ---
#define TU_BASE     (TPU_BASE + 0x800U)
#define TU_REG(w)   (*(volatile uint32_t *)(TU_BASE + (w)*4))
#define TU_INA(i)   TU_REG(0 + (i))      // y / w2td2
#define TU_Z(i)     TU_REG(4 + (i))      // z2 / z1
#define TU_T(i)     TU_REG(8 + (i))      // target
#define TU_DW(i)    TU_REG(12 + (i))     // outer-product gradient bank (0..7)
#define TU_CMD      TU_REG(20)           // [0]loss_d2 [1]d1 [2]upd_l2 [3]upd_l1 [4]clr_loss
#define TU_MW(i)    TU_REG(32 + (i))     // master window words 0..16
#define TU_D2(i)    TU_REG(52 + (i))
#define TU_D1(i)    TU_REG(56 + (i))
#define TU_LOSS     TU_REG(60)

// Mailbox loss-curve protocol (PS / host polls 0x41200000 via `md`): identical to M7.1.
//   bit31=0 -> checkpoint: [30:16]=epoch, [15:0]=SSE ; bit31=1 -> DONE 0x8000|XOR<<16|SSE
#define M7_HOLD_ITERS   60000000u    // ~3-5 s/checkpoint
#define M7_SETTLE_ITERS 30000000u    // ~10 s post-config settle (see M7.1 finding)

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

// ── train_unit "trio" over XBUS ──────────────────────────────────────────────────
void tu_master_load(const i64 W1[4][4], const i64 b1[4], const i64 W2[4][4], const i64 b2[4]) {
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 2; j++) TU_MW(i*2 + j) = (uint32_t)(int32_t)W1[i][j];   // 0..7
    for (int i = 0; i < 4; i++) TU_MW(8 + i)  = (uint32_t)(int32_t)b1[i];           // 8..11
    for (int j = 0; j < 4; j++) TU_MW(12 + j) = (uint32_t)(int32_t)W2[0][j];        // 12..15
    TU_MW(16) = (uint32_t)(int32_t)b2[0];                                           // 16
}
void tu_master_read(i64 W1[4][4], i64 b1[4], i64 W2[4][4], i64 b2[4]) {
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 2; j++) W1[i][j] = (i64)(int32_t)TU_MW(i*2 + j);
        W1[i][2] = 0; W1[i][3] = 0;                       // structurally-zero cols
        b1[i] = (i64)(int32_t)TU_MW(8 + i);
    }
    for (int j = 0; j < 4; j++) W2[0][j] = (i64)(int32_t)TU_MW(12 + j);
    for (int i = 1; i < 4; i++) for (int j = 0; j < 4; j++) W2[i][j] = 0;   // rows 1..3 ≡ 0
    b2[0] = (i64)(int32_t)TU_MW(16);
    b2[1] = 0; b2[2] = 0; b2[3] = 0;
}
void tu_clr_loss(void) { __asm__ volatile("fence" ::: "memory"); TU_CMD = 0x10; }
i64  tu_get_loss(void) { return (i64)(int32_t)TU_LOSS; }

void tu_loss_d2(const i64 y[4], const i64 z2[4], const i64 t[4], i64 d2_out[4]) {
    for (int i = 0; i < 4; i++) { TU_INA(i) = (uint32_t)(int32_t)y[i];
                                  TU_Z(i)   = (uint32_t)(int32_t)z2[i];
                                  TU_T(i)   = (uint32_t)(int32_t)t[i]; }
    __asm__ volatile("fence" ::: "memory");
    TU_CMD = 0x01;
    for (int i = 0; i < 4; i++) d2_out[i] = (i64)(int32_t)TU_D2(i);
}
void tu_d1(const i64 w2td2[4], const i64 z1[4], i64 d1_out[4]) {
    for (int i = 0; i < 4; i++) { TU_INA(i) = (uint32_t)(int32_t)w2td2[i];
                                  TU_Z(i)   = (uint32_t)(int32_t)z1[i]; }
    __asm__ volatile("fence" ::: "memory");
    TU_CMD = 0x02;
    for (int i = 0; i < 4; i++) d1_out[i] = (i64)(int32_t)TU_D1(i);
}
void tu_upd_l2(const i64 dw2[4]) {
    for (int j = 0; j < 4; j++) TU_DW(j) = (uint32_t)(int32_t)dw2[j];
    __asm__ volatile("fence" ::: "memory");
    TU_CMD = 0x04;
}
void tu_upd_l1(const i64 dw1[8]) {
    for (int n = 0; n < 8; n++) TU_DW(n) = (uint32_t)(int32_t)dw1[n];
    __asm__ volatile("fence" ::: "memory");
    TU_CMD = 0x08;
}

#include "m7_kernel_hw.h"

int main(void) {
    neorv32_rte_setup();
    neorv32_uart0_setup(BAUD_RATE, 0);

    neorv32_uart0_printf("\n=====================================\n");
    neorv32_uart0_printf("  NEORV32 on-chip XOR TRAINING (M7.2) \n");
    neorv32_uart0_printf("  trio (loss/leaky'/SGD) in train_unit \n");
    neorv32_uart0_printf("=====================================\n");

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
    m7_init_hw(W1, b1, W2, b2);     // seed C mirror AND the train_unit master

    // self-check the train_unit master round-trip (write init, read back, compare).
    {
        i64 rW1[4][4], rb1[4], rW2[4][4], rb2[4];
        tu_master_read(rW1, rb1, rW2, rb2);
        int mm = 0;
        for (int i = 0; i < 4; i++) { if (rb1[i] != b1[i]) mm++;
            for (int j = 0; j < 2; j++) if (rW1[i][j] != W1[i][j]) mm++; }
        for (int j = 0; j < 4; j++) if (rW2[0][j] != W2[0][j]) mm++;
        if (rb2[0] != b2[0]) mm++;
        neorv32_uart0_printf("train_unit master round-trip mism = %d (expect 0)\n", mm);
    }

    // M7.1 post-config SETTLE (still required: the first SGD step must not land on a
    // bad matmul — see m7_plan.md §M7.1 "post-config settle"). Warm-up + ~10 s hold.
    {
        const signed char Ww[4][4] = {{1,1,1,1},{1,2,3,4},{2,2,2,2},{1,0,1,0}};
        const signed char Xw[4]    = {2,3,4,5};
        int32_t accw[4];
        for (int w = 0; w < 16; w++) array_macc(Ww, Xw, accw);
        for (volatile uint32_t d = 0; d < M7_SETTLE_ITERS; d++) { }
    }

    neorv32_uart0_printf("training %d epochs (loss -> mailbox)...\n", M7_EPOCHS);
    i64 sse = 0;
    for (int ep = 0; ep < M7_EPOCHS; ep++) {
        sse = m7_epoch_hw(ep, W1, b1, W2, b2);
        int do_ckpt = (ep < 200) ? (ep % 20 == 0) : (ep % 400 == 0);
        if (do_ckpt) {
            MBOX = ((uint32_t)ep << 16) | ((uint32_t)sse & 0xFFFF);
            uint32_t hold = (ep == 0) ? (M7_HOLD_ITERS * 4) : M7_HOLD_ITERS;
            for (volatile uint32_t d = 0; d < hold; d++) { }
        }
    }

    neorv32_uart0_printf("--- trained master weights (Q8.8, from train_unit) ---\n");
    neorv32_uart0_printf("W2r0 %d %d %d %d\n", (int32_t)W2[0][0], (int32_t)W2[0][1],
                         (int32_t)W2[0][2], (int32_t)W2[0][3]);
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
