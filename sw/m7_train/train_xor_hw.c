// train_xor_hw.c — M7.2 HOST validator for the HW-trio training split.
//
// Runs the SAME kernel the board firmware runs (m7_kernel_hw.h), but with the
// train_unit "trio" (loss / leaky' / δ / SGD-update + master weights) modelled in
// plain C below, and the 4x4 array modelled as a plain-C MAC. Bit-exact compares the
// final master weights + full loss curve against the numpy oracle (sim/oracle_train.py).
//
// This proves the M7.2 HW/SW *split* reproduces the oracle on the host before any
// board time. The train_unit RTL itself is independently proven bit-exact in
// sim/tb_train.v; the C model here uses the IDENTICAL fixed-point primitives
// (m7_kernel.h), so host-pass ⇒ the firmware sequencing is correct by construction.
//
// Build + run:   make -C sw/m7_train -f Makefile.host check-hw
//        or:     cc -O2 -Wall -o /tmp/train_xor_hw train_xor_hw.c && /tmp/train_xor_hw

#include <stdint.h>
#include <stdio.h>

typedef int64_t i64;

// HOST array_macc: signed INT8 MAC -> INT32, identical contract to pe.v.
void array_macc(const signed char Wi[4][4], const signed char xi[4], int32_t acc[4]) {
    for (int i = 0; i < 4; i++) {
        int32_t a = 0;
        for (int j = 0; j < 4; j++) a += (int32_t)Wi[i][j] * (int32_t)xi[j];
        acc[i] = a;
    }
}

#include "m7_kernel_hw.h"   // pulls m7_kernel.h primitives too

// ── train_unit C model — the HARDWARE state, mirrored exactly to train_unit.v ──
// Master weights resident "in the unit": W2 row0 + b2[0] (output), W1[*][0..1] + b1
// (hidden); the structurally-unused parts are kept 0. Plus the loss accumulator and
// the last-computed δ vectors (the SGD update consumes them, as in the RTL).
static i64 TU_W1[4][4], TU_b1[4], TU_W2[4][4], TU_b2[4];
static i64 TU_loss;
static i64 TU_d2[4], TU_d1[4];

#define TU_ERR_CLAMP (1 << 20)
#define TU_D_CLAMP   (1 << 14)

void tu_master_load(const i64 W1[4][4], const i64 b1[4], const i64 W2[4][4], const i64 b2[4]) {
    for (int i = 0; i < 4; i++) {
        TU_b1[i] = b1[i]; TU_b2[i] = b2[i];
        for (int j = 0; j < 4; j++) { TU_W1[i][j] = W1[i][j]; TU_W2[i][j] = W2[i][j]; }
    }
}
void tu_master_read(i64 W1[4][4], i64 b1[4], i64 W2[4][4], i64 b2[4]) {
    for (int i = 0; i < 4; i++) {
        b1[i] = TU_b1[i]; b2[i] = TU_b2[i];
        for (int j = 0; j < 4; j++) { W1[i][j] = TU_W1[i][j]; W2[i][j] = TU_W2[i][j]; }
    }
}
void tu_clr_loss(void) { TU_loss = 0; }
i64  tu_get_loss(void) { return TU_loss; }

void tu_loss_d2(const i64 y[4], const i64 z2[4], const i64 t[4], i64 d2_out[4]) {
    i64 err[4];
    for (int i = 0; i < 4; i++) err[i] = m7_clamp(y[i] - t[i], -TU_ERR_CLAMP, TU_ERR_CLAMP - 1);
    TU_loss += m7_qmul(err[0], err[0]);
    for (int i = 0; i < 4; i++) {
        TU_d2[i] = m7_clamp(m7_qmul(err[i], m7_leaky_d(z2[i])), -TU_D_CLAMP, TU_D_CLAMP - 1);
        d2_out[i] = TU_d2[i];
    }
}
void tu_d1(const i64 w2td2[4], const i64 z1[4], i64 d1_out[4]) {
    for (int i = 0; i < 4; i++) {
        TU_d1[i] = m7_clamp(m7_qmul(w2td2[i], m7_leaky_d(z1[i])), -TU_D_CLAMP, TU_D_CLAMP - 1);
        d1_out[i] = TU_d1[i];
    }
}
void tu_upd_l2(const i64 dw2[4]) {   // master W2 row0 + b2[0]; rest stay 0
    for (int j = 0; j < 4; j++) TU_W2[0][j] = m7_sat(TU_W2[0][j] - (dw2[j] >> M7_LR_SHIFT));
    for (int i = 1; i < 4; i++) for (int j = 0; j < 4; j++) TU_W2[i][j] = 0;
    TU_b2[0] = m7_sat(TU_b2[0] - (TU_d2[0] >> M7_LR_SHIFT));
    for (int i = 1; i < 4; i++) TU_b2[i] = 0;
}
void tu_upd_l1(const i64 dw1[8]) {   // master W1[*][0..1] + b1; cols 2,3 stay 0
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 2; j++) TU_W1[i][j] = m7_sat(TU_W1[i][j] - (dw1[i*2 + j] >> M7_LR_SHIFT));
    for (int i = 0; i < 4; i++) for (int j = 2; j < 4; j++) TU_W1[i][j] = 0;
    for (int i = 0; i < 4; i++) TU_b1[i] = m7_sat(TU_b1[i] - (TU_d1[i] >> M7_LR_SHIFT));
}

int main(void) {
    i64 W1[4][4], W2[4][4], b1[4], b2[4];
    m7_init_hw(W1, b1, W2, b2);

    static i64 losses[M7_EPOCHS];
    for (int ep = 0; ep < M7_EPOCHS; ep++)
        losses[ep] = m7_epoch_hw(ep, W1, b1, W2, b2);

    int wmism = 0, lmism = 0;
    for (int i = 0; i < 4; i++) {
        if (b1[i] != M7_GOLD_B1[i]) wmism++;
        if (b2[i] != M7_GOLD_B2[i]) wmism++;
        for (int j = 0; j < 4; j++) {
            if (W1[i][j] != M7_GOLD_W1[i][j]) wmism++;
            if (W2[i][j] != M7_GOLD_W2[i][j]) wmism++;
        }
    }
    for (int ep = 0; ep < M7_EPOCHS; ep++)
        if (losses[ep] != (i64)M7_GOLD_LOSS[ep]) lmism++;

    int ok = 0;
    for (int s = 0; s < 4; s++) {
        i64 z1[4], h[4], z2[4], y[4];
        m7_forward(W1, b1, W2, b2, M7_XP[s], z1, h, z2, y);
        ok += ((y[0] > M7_ONE / 2) == (M7_TV[s] > M7_ONE / 2));
    }

    printf("M7.2 HW-split C-vs-oracle: weight mism=%d, loss-curve mism=%d/%d, XOR=%d/4, "
           "final SSE=%lld\n", wmism, lmism, M7_EPOCHS, ok, (long long)losses[M7_EPOCHS - 1]);
    if (wmism == 0 && lmism == 0 && ok == 4) { printf("== PASS: bit-exact match ==\n"); return 0; }
    printf("== FAIL ==\n");
    return 1;
}
