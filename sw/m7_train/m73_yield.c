// m73_yield.c — M7.3 path (a) "converged-seed single-step" dual-phase firmware.
//
// ONE static-region NEORV32 image drives BOTH RP modules across a host-performed DFX
// swap (M6.4 measure-then-yield). The array (XBUS 0x00-0x2C = wb_tpu_accel) is IDENTICAL
// in rm_train and rm_tpuvpu, and M7.1 proved the XOR forward (array matmul + SW
// requant, VPU bypassed) is bit-exact to the oracle — so the SAME m7_forward runs on
// whichever RM is loaded. The train_unit window (0x800) exists only in rm_train and is
// touched only in Phase 1.
//
// Phase 1 (rm_train loaded):
//   - seed the train_unit master with the oracle's CONVERGED Q8.8 weights (host-known,
//     sim/oracle_train.py --seed 3 --fwd int8 --wshift 2 --xshift 2 -> XOR 4/4 SSE=0),
//   - do ONE verified HW SGD step (m7_epoch_hw; loss already ~0, weights stay converged),
//   - read the updated master back, publish W2[0..3]+b2 over the mailbox (PS reads the
//     "learned model"), then publish READY_TO_YIELD,
//   - spin a fixed wall-clock window so the host can run a *measured* `loadbp` swap to
//     rm_tpuvpu underneath us (the static NEORV32 keeps running across the RP reconfig).
//
// Phase 2 (rm_tpuvpu loaded after the host swap; VPU bypassed = legacy array timing):
//   - short mailbox-visible pacing window after the swap,
//   - run m7_forward on the 4 XOR inputs using the weights CARRIED IN DMEM across the
//     swap, publish DONE | XOR-score. => train-then-yield-then-infer on the learned model.
//
// The weights live in NEORV32 DMEM (static), so they survive the RP loadbp; no inbound
// mailbox / RTL change is needed — the swap window is a fixed spin, and the forward works
// on either RM (array present in both) so exact swap timing is not correctness-critical.
//
// NOTE (2026-07-02): the old M7.2 build-lottery diagnosis was superseded by the
// NEORV32 image_gen LMA-gap root cause. Keep this firmware's self-checks, but do not
// treat a correct rebuild as a routing lottery.

#include <neorv32.h>

#define BAUD_RATE 115200
#define TPU_BASE  0xF0000000U

#define TPU_CTRL    (*(volatile uint32_t *)(TPU_BASE + 0x00))
#define TPU_STATUS  (*(volatile uint32_t *)(TPU_BASE + 0x04))
#define TPU_W_ADDR  (*(volatile uint32_t *)(TPU_BASE + 0x08))
#define TPU_W_DATA4 (*(volatile uint32_t *)(TPU_BASE + 0x14))
#define TPU_X_IN    (*(volatile uint32_t *)(TPU_BASE + 0x10))
#define TPU_RES(r)  (*(volatile uint32_t *)(TPU_BASE + 0x20 + (r)*4))
#define MBOX        (*(volatile uint32_t *)0xF1000000U)

#define TU_BASE     (TPU_BASE + 0x800U)
#define TU_REG(w)   (*(volatile uint32_t *)(TU_BASE + (w)*4))
#define TU_INA(i)   TU_REG(0 + (i))
#define TU_Z(i)     TU_REG(4 + (i))
#define TU_T(i)     TU_REG(8 + (i))
#define TU_DW(i)    TU_REG(12 + (i))
#define TU_CMD      TU_REG(20)
#define TU_MW(i)    TU_REG(32 + (i))
#define TU_D2(i)    TU_REG(52 + (i))
#define TU_D1(i)    TU_REG(56 + (i))
#define TU_LOSS     TU_REG(60)

// Mailbox tags (PS polls 0x41200000 via `md`). Distinct from the loss-curve protocol:
//   0xC0..0xC4 : learned model words W2[0],W2[1],W2[2],W2[3],b2 (value = signed 24-bit)
//   0x600D0000 : READY_TO_YIELD  (host may now measured-loadbp swap to rm_tpuvpu)
//   0x8000.... : DONE = 0x80000000 | (XOR_score<<16) | (preds_nibble<<8) | 0xED
#define M73_READY     0x600D0000u
#define M73_HOLD      20000000u    // ~3-4 s per published word (PS poll window)
#define M73_SETTLE    30000000u    // ~10 s post-config settle (M7.1)

#define M7_BOARD                   // exclude the host golden self-check arrays

#include <stdint.h>
typedef int64_t i64;

// ── 4x4 array over XBUS (forward W·x; raw INT32 acc) — identical to main.c ────────
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

// ── train_unit "trio" over XBUS (Phase 1 only) — identical to main.c ──────────────
void tu_master_load(const i64 W1[4][4], const i64 b1[4], const i64 W2[4][4], const i64 b2[4]) {
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 2; j++) TU_MW(i*2 + j) = (uint32_t)(int32_t)W1[i][j];
    for (int i = 0; i < 4; i++) TU_MW(8 + i)  = (uint32_t)(int32_t)b1[i];
    for (int j = 0; j < 4; j++) TU_MW(12 + j) = (uint32_t)(int32_t)W2[0][j];
    TU_MW(16) = (uint32_t)(int32_t)b2[0];
}
void tu_master_read(i64 W1[4][4], i64 b1[4], i64 W2[4][4], i64 b2[4]) {
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 2; j++) W1[i][j] = (i64)(int32_t)TU_MW(i*2 + j);
        W1[i][2] = 0; W1[i][3] = 0;
        b1[i] = (i64)(int32_t)TU_MW(8 + i);
    }
    for (int j = 0; j < 4; j++) W2[0][j] = (i64)(int32_t)TU_MW(12 + j);
    for (int i = 1; i < 4; i++) for (int j = 0; j < 4; j++) W2[i][j] = 0;
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

// ── CONVERGED master weights (Q8.8) — sim/oracle_train.py golden config (XOR 4/4) ──
static const i64 CW1[4][4] = {{178,-183,0,0},{-55,199,0,0},{-177,170,0,0},{76,-86,0,0}};
static const i64 Cb1[4]    = {1, 251, 2, 7};
static const i64 CW2[4][4] = {{382,45,475,288},{0,0,0,0},{0,0,0,0},{0,0,0,0}};
static const i64 Cb2[4]    = {-59, 0, 0, 0};

static void pub(uint32_t w) { __asm__ volatile("fence" ::: "memory"); MBOX = w;
                              for (volatile uint32_t d = 0; d < M73_HOLD; d++) { } }
static uint32_t tag24(uint32_t tag, i64 v) { return (tag << 24) | ((uint32_t)(int32_t)v & 0x00FFFFFFu); }

int main(void) {
    // NB: NEORV32 uart0 is NOT pinned out on this board (dfx_top.v) — all firmware
    // status goes through the PS-visible mailbox 0x41200000, NOT printf. printf was
    // therefore dead code AND bloated the IMEM (.text); per the M7.2 size-correlated
    // build lottery (smaller IMEM => better odds of a correct-routing array), this
    // image carries NO uart0/printf at all (mailbox-only).
    neorv32_rte_setup();

    // ── seed the working set AND the HW master with the CONVERGED weights ──
    i64 W1[4][4], b1[4], W2[4][4], b2[4];
    for (int i = 0; i < 4; i++) { b1[i] = Cb1[i]; b2[i] = Cb2[i];
        for (int j = 0; j < 4; j++) { W1[i][j] = CW1[i][j]; W2[i][j] = CW2[i][j]; } }
    tu_master_load(W1, b1, W2, b2);

    // post-config settle before any compute (M7.1).
    {
        const signed char Ww[4][4] = {{1,1,1,1},{1,2,3,4},{2,2,2,2},{1,0,1,0}};
        const signed char Xw[4]    = {2,3,4,5};
        int32_t accw[4];
        for (int w = 0; w < 16; w++) array_macc(Ww, Xw, accw);
        for (volatile uint32_t d = 0; d < M73_SETTLE; d++) { }
    }

    // ── Phase 1: ONE verified HW SGD step on the converged master (loss stays ~0) ──
    tu_clr_loss();
    i64 sse = m7_epoch_hw(0, W1, b1, W2, b2);   // 4 samples = one online-SGD epoch
    (void)sse;

    // publish the learned model (W2 row0 + b2) then READY_TO_YIELD.
    pub(tag24(0xC0, W2[0][0])); pub(tag24(0xC1, W2[0][1]));
    pub(tag24(0xC2, W2[0][2])); pub(tag24(0xC3, W2[0][3]));
    pub(tag24(0xC4, b2[0]));
    pub(M73_READY);

    // ── Phase 2: continuous INFER loop on the carried-in-DMEM weights. The host runs a
    // MEASURED loadbp swap rm_train -> rm_tpuvpu at any time; the array is present in both
    // RMs so each pass re-loads weights + re-runs the forward and keeps publishing XOR.
    // After a swap the array needs a post-config settle (M7.1), so the published score
    // stabilizes to 4/4 a few seconds after the yield (a clean "watch it settle" demo). ──
    uint32_t led = 0xF;
    while (1) {
        int ok = 0, preds = 0;
        for (int s = 0; s < 4; s++) {
            i64 z1[4], h[4], z2[4], y[4];
            m7_forward(W1, b1, W2, b2, M7_XP[s], z1, h, z2, y);
            int pred = (y[0] > M7_ONE / 2);
            preds |= (pred << s);
            ok += (pred == (M7_TV[s] > M7_ONE / 2));
        }
        // DONE = 0x80000000 | (XOR_score<<16) | (preds_nibble<<8) | 0xED
        MBOX = 0x80000000u | ((uint32_t)ok << 16) | ((uint32_t)preds << 8) | 0xEDu;
        neorv32_gpio_port_set(led);
        led ^= 0xF;
        for (volatile uint32_t d = 0; d < 4000000u; d++) { }   // ~1 s per inference pass
    }
    return 0;
}
