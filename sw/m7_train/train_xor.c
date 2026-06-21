// train_xor.c — M7.0b HOST validator for the shared backprop kernel.
//
// Runs the SAME kernel the NEORV32 board firmware runs (m7_kernel.h), replaying
// the host-seeded init + per-epoch order from m7_vectors.h, and bit-exact
// compares its final master weights + full loss curve against the numpy oracle
// (sim/oracle_train.py). The only thing host-specific here is array_macc() —
// plain C standing in for the 4x4 systolic array — and the golden compare.
//
// Build + run:   make -C sw/m7_train -f Makefile.host check
//        or:     cc -O2 -Wall -o /tmp/train_xor train_xor.c && /tmp/train_xor

#include <stdint.h>
#include <stdio.h>

// HOST array_macc: signed INT8 MAC -> INT32, identical contract to pe.v.
// (Defined before the kernel include so the kernel binds to it.)
typedef signed char i8_host;
void array_macc(const signed char Wi[4][4], const signed char xi[4], int32_t acc[4]) {
    for (int i = 0; i < 4; i++) {
        int32_t a = 0;
        for (int j = 0; j < 4; j++) a += (int32_t)Wi[i][j] * (int32_t)xi[j];
        acc[i] = a;
    }
}

#include "m7_kernel.h"

int main(void) {
    i64 W1[4][4], W2[4][4], b1[4], b2[4];
    m7_init(W1, b1, W2, b2);

    static i64 losses[M7_EPOCHS];
    for (int ep = 0; ep < M7_EPOCHS; ep++)
        losses[ep] = m7_epoch(ep, W1, b1, W2, b2);

    // ---- bit-exact compare against the numpy oracle (golden) ----
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

    // XOR correctness from the C-trained weights (independent sanity).
    int ok = 0;
    for (int s = 0; s < 4; s++) {
        i64 z1[4], h[4], z2[4], y[4];
        m7_forward(W1, b1, W2, b2, M7_XP[s], z1, h, z2, y);
        ok += ((y[0] > M7_ONE / 2) == (M7_TV[s] > M7_ONE / 2));
    }

    printf("M7.0b C-vs-oracle: weight mism=%d, loss-curve mism=%d/%d, XOR=%d/4, "
           "final SSE=%lld\n", wmism, lmism, M7_EPOCHS, ok, (long long)losses[M7_EPOCHS - 1]);
    printf("  C final  W2[0]=%lld %lld %lld %lld  b2=%lld\n",
           (long long)W2[0][0], (long long)W2[0][1], (long long)W2[0][2],
           (long long)W2[0][3], (long long)b2[0]);
    if (wmism == 0 && lmism == 0 && ok == 4) { printf("== PASS: bit-exact match ==\n"); return 0; }
    printf("== FAIL ==\n");
    return 1;
}
