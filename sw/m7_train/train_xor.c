// train_xor.c — M7.0b fixed-point XOR backprop in portable C.
//
// This is the C twin of sim/oracle_train.py (the numpy golden oracle). It runs
// the SAME Q8.8/INT8 hybrid-QAT 2-4-1 leaky-MLP training, replaying the exact
// host-seeded init weights and per-epoch sample order baked into m7_vectors.h,
// and bit-exact compares its final master weights + full loss curve against the
// oracle's golden values. No RNG on this side — init + order are host-provided
// (m7_plan.md open-decisions #5/#6), which is also how the on-board NEORV32
// firmware will get them.
//
// M7.0b path: validate THIS C on the host (gcc) against the oracle first, then
// the same source becomes NEORV32 firmware — only matmul_int8() (the forward
// W*x) gets swapped for the 4x4 systolic-array XBUS path (the M6 datapath); all
// element-wise math (loss/delta/outer-product/SGD update) stays identical C.
//
// All arithmetic is int64 to mirror numpy int64 exactly. Right shifts of
// negatives must be ARITHMETIC (floor) to match numpy — true on gcc/clang and
// the RISC-V toolchain (srai). q_mul/leaky/shift-update all rely on this.
//
// Build + run on host:   make -C sw_src/m7_train check
//             or:        cc -O2 -Wall -o /tmp/train_xor train_xor.c && /tmp/train_xor

#include <stdint.h>
#include <stdio.h>
#include "m7_vectors.h"

#define FRAC   M7_FRAC
#define ONE    (1 << FRAC)          // 1.0 in Q8.8 = 256
#define QMIN   (-(1 << 15))         // INT16 master range
#define QMAX   ((1 << 15) - 1)
#define K      M7_K
#define LR     M7_LR_SHIFT
#define WSH    M7_WSHIFT
#define XSH    M7_XSHIFT

typedef int64_t i64;                // matches numpy int64 throughout

static i64 clampi(i64 x, i64 lo, i64 hi) { return x < lo ? lo : (x > hi ? hi : x); }
static i64 sat(i64 x)               { return clampi(x, QMIN, QMAX); }

// Q8.8 * Q8.8 -> Q8.8, round-half-up then arithmetic shift (matches M6 requant).
static i64 q_mul(i64 a, i64 b)      { return ((a * b) + (1 << (FRAC - 1))) >> FRAC; }

// fwd leaky ReLU and its derivative, Q8.8, negative-slope shift k (== M6 VPU_ALPHA).
static i64 leaky(i64 z)             { return z >= 0 ? z : (z >> K); }
static i64 leaky_d(i64 z)           { return z >= 0 ? ONE : (ONE >> K); }

// Q8.8 -> INT8 view: round-half-up after >>s, clamp [-128,127].
static i64 quant_int8(i64 v, int s) { return clampi((v + (1 << (s - 1))) >> s, -128, 127); }

// Model the M6 INT8 forward array: quantize W,x to INT8, INT32 accumulate,
// requant back to Q8.8. ON-BOARD this single function is replaced by the 4x4
// systolic-array XBUS sequence; everything else in this file is unchanged.
static void matmul_int8(const i64 W[4][4], const i64 x[4], i64 z[4]) {
    i64 xi[4];
    for (int j = 0; j < 4; j++) xi[j] = quant_int8(x[j], XSH);
    int down = 8 - WSH - XSH;
    for (int i = 0; i < 4; i++) {
        i64 acc = 0;
        for (int j = 0; j < 4; j++) acc += quant_int8(W[i][j], WSH) * xi[j];
        i64 zi = (down > 0) ? ((acc + (1 << (down - 1))) >> down) : (acc << (-down));
        z[i] = sat(zi);
    }
}

// forward pass; keeps z1,h,z2,y for the backward pass.
static void forward(const i64 W1[4][4], const i64 b1[4],
                    const i64 W2[4][4], const i64 b2[4],
                    const i64 x[4], i64 z1[4], i64 h[4], i64 z2[4], i64 y[4]) {
    i64 t[4];
    matmul_int8(W1, x, t);
    for (int i = 0; i < 4; i++) { z1[i] = sat(t[i] + b1[i]); h[i] = leaky(z1[i]); }
    matmul_int8(W2, h, t);
    for (int i = 0; i < 4; i++) { z2[i] = sat(t[i] + b2[i]); y[i] = leaky(z2[i]); }
}

int main(void) {
    // XOR data in Q8.8, padded to dim-4 (fixed, not RNG).
    static const i64 Xp[4][4] = {{0,0,0,0},{0,ONE,0,0},{ONE,0,0,0},{ONE,ONE,0,0}};
    static const i64 Tv[4]    = {0, ONE, ONE, 0};

    // master weights (Q8.8) — start from the host-seeded init.
    i64 W1[4][4], W2[4][4], b1[4], b2[4];
    for (int i = 0; i < 4; i++) {
        b1[i] = M7_INIT_B1[i]; b2[i] = M7_INIT_B2[i];
        for (int j = 0; j < 4; j++) { W1[i][j] = M7_INIT_W1[i][j]; W2[i][j] = M7_INIT_W2[i][j]; }
    }

    static i64 losses[M7_EPOCHS];
    for (int ep = 0; ep < M7_EPOCHS; ep++) {
        i64 sse = 0;
        for (int o = 0; o < 4; o++) {
            int s = M7_ORDER[ep][o];
            const i64 *x = Xp[s];
            i64 z1[4], h[4], z2[4], y[4];
            forward(W1, b1, W2, b2, x, z1, h, z2, y);

            // loss (lane 0 only: target lives in lane 0, other lanes are 0).
            i64 err[4];
            for (int i = 0; i < 4; i++) {
                i64 t = (i == 0) ? Tv[s] : 0;
                err[i] = clampi(y[i] - t, -(1 << 20), (1 << 20) - 1);
            }
            sse += q_mul(err[0], err[0]);

            // backward
            i64 d2[4], dW2[4][4], w2td2[4], d1[4], dW1[4][4];
            for (int i = 0; i < 4; i++)
                d2[i] = clampi(q_mul(err[i], leaky_d(z2[i])), -(1 << 14), (1 << 14) - 1);
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++) dW2[i][j] = q_mul(d2[i], h[j]);     // d2 (x) h^T

            // delta1 = (W2^T . d2) (.) leaky'(z1) -- transpose reuse (Problem 1),
            // done in master Q8.8 precision (matches the oracle's w2td2).
            for (int i = 0; i < 4; i++) {
                i64 acc = 0;
                for (int j = 0; j < 4; j++) acc += W2[j][i] * d2[j];            // W2^T
                w2td2[i] = (acc + (1 << (FRAC - 1))) >> FRAC;
                d1[i] = clampi(q_mul(w2td2[i], leaky_d(z1[i])), -(1 << 14), (1 << 14) - 1);
            }
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++) dW1[i][j] = q_mul(d1[i], x[j]);     // d1 (x) x^T

            // SGD update on master (saturating), lr = 2^-LR; keep unused parts clean.
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++) W2[i][j] = sat(W2[i][j] - (dW2[i][j] >> LR));
            for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) if (i >= 1) W2[i][j] = 0;
            for (int i = 0; i < 4; i++) b2[i] = sat(b2[i] - (d2[i] >> LR));
            for (int i = 1; i < 4; i++) b2[i] = 0;
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++) W1[i][j] = sat(W1[i][j] - (dW1[i][j] >> LR));
            for (int i = 0; i < 4; i++) for (int j = 2; j < 4; j++) W1[i][j] = 0;
            for (int i = 0; i < 4; i++) b1[i] = sat(b1[i] - (d1[i] >> LR));
        }
        losses[ep] = sse;
    }

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
        forward(W1, b1, W2, b2, Xp[s], z1, h, z2, y);
        int pred = (y[0] > ONE / 2), tgt = (Tv[s] > ONE / 2);
        ok += (pred == tgt);
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
