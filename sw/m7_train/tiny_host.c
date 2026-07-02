// tiny_host.c — M7.4-tiny HOST validator for the shared backprop kernel.
//
// Same as mnist_host.c but for the small 16-4-2 net (oracle_tiny.py), which was
// the first MNIST variant to run multi-epoch ON-BOARD. Runs the SAME kernel the
// NEORV32 firmware runs
// (m7_mnist_kernel.h, dimension-generic), replaying the host-seeded init + baked
// 4x4 dataset from m7_tiny_vectors.h, and bit-exact compares final master weights
// + full loss curve + per-epoch test accuracy against the numpy oracle.
//
// Build + run:   make -C sw/m7_train -f Makefile.host tiny

#include <stdint.h>
#include <stdio.h>

// HOST array_macc: signed INT8 MAC -> INT32, identical contract to pe.v.
void array_macc(const signed char Wi[4][4], const signed char xi[4], int32_t acc[4]) {
    for (int i = 0; i < 4; i++) {
        int32_t a = 0;
        for (int j = 0; j < 4; j++) a += (int32_t)Wi[i][j] * (int32_t)xi[j];
        acc[i] = a;
    }
}

#define M7M_VECTORS_H "m7_tiny_vectors.h"
#include "m7_mnist_kernel.h"

int main(void) {
    i64 W1[M7M_NH][M7M_NIN], b1[M7M_NH], W2[M7M_NOUT][M7M_NH], b2[M7M_NOUT];
    m7_init(W1, b1, W2, b2);

    static long losses[M7M_EPOCHS];
    static int  acc1000[M7M_EPOCHS];
    for (int ep = 0; ep < M7M_EPOCHS; ep++) {
        losses[ep] = (long)m7_epoch(W1, b1, W2, b2);
        int ok = m7_test_correct(W1, b1, W2, b2);
        acc1000[ep] = (ok * 1000 + M7M_NTEST / 2) / M7M_NTEST;   // round-to-nearest x1000
    }

    // ---- bit-exact compare against the numpy oracle (golden) ----
    int wmism = 0, lmism = 0, amism = 0;
    for (int i = 0; i < M7M_NH; i++) {
        if (b1[i] != M7M_GOLD_B1[i]) wmism++;
        for (int j = 0; j < M7M_NIN; j++) if (W1[i][j] != M7M_GOLD_W1[i][j]) wmism++;
    }
    for (int i = 0; i < M7M_NOUT; i++) {
        if (b2[i] != M7M_GOLD_B2[i]) wmism++;
        for (int j = 0; j < M7M_NH; j++) if (W2[i][j] != M7M_GOLD_W2[i][j]) wmism++;
    }
    for (int ep = 0; ep < M7M_EPOCHS; ep++) {
        if (losses[ep] != M7M_GOLD_LOSS[ep]) lmism++;
        if (acc1000[ep] != M7M_GOLD_ACC1000[ep]) amism++;
    }

    printf("M7.4-tiny (%d-%d-%d, digits 0/1) host kernel vs numpy oracle:\n",
           M7M_NIN, M7M_NH, M7M_NOUT);
    printf("  weight mismatches : %d\n", wmism);
    printf("  loss   mismatches : %d / %d\n", lmism, M7M_EPOCHS);
    printf("  acc    mismatches : %d / %d\n", amism, M7M_EPOCHS);
    printf("  test acc: ep0=%d.%d%%  final=%d.%d%%  (x1000)\n",
           acc1000[0] / 10, acc1000[0] % 10,
           acc1000[M7M_EPOCHS - 1] / 10, acc1000[M7M_EPOCHS - 1] % 10);
    int peak = 0;
    for (int ep = 0; ep < M7M_EPOCHS; ep++) if (acc1000[ep] > peak) peak = acc1000[ep];
    printf("  peak test acc: %d.%d%%\n", peak / 10, peak % 10);

    int ok = (wmism == 0 && lmism == 0 && amism == 0);
    printf("\n%s: host kernel is %sbit-exact to the oracle\n",
           ok ? "PASS" : "FAIL", ok ? "" : "NOT ");
    return ok ? 0 : 1;
}
