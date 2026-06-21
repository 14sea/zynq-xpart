// m7_kernel.h — the shared fixed-point XOR backprop kernel (M7.0b).
//
// This is the SINGLE source of the training math, included verbatim by both the
// host validator (train_xor.c) and the NEORV32 board firmware (main.c). The host
// proves it bit-exact against the numpy oracle; the board then runs the EXACT
// same code — only array_macc() (the 4x4 systolic-array matmul) differs between
// the two translation units. That is the M7.0/M7.1 SW/HW split made literal.
//
// All arithmetic is int64 to mirror numpy int64 exactly. Right shifts of
// negatives MUST be arithmetic (floor) — true on gcc/clang and RISC-V (srai).
//
// Each TU MUST define array_macc() before including this header:
//   void array_macc(const i8 Wi[4][4], const i8 xi[4], int32_t acc[4]);
// computing acc[i] = Σⱼ Wi[i][j]·xi[j] in signed INT32 (the array's contract).

#ifndef M7_KERNEL_H
#define M7_KERNEL_H

#include <stdint.h>
#include "m7_vectors.h"        // FRAC/K/LR/WSH/XSH + INIT + ORDER (+ golden if !M7_BOARD)

typedef int64_t     i64;       // matches numpy int64 throughout
typedef signed char i8;

#define M7_ONE   (1 << M7_FRAC)        // 1.0 in Q8.8 = 256
#define M7_QMIN  (-(1 << 15))          // INT16 master range
#define M7_QMAX  ((1 << 15) - 1)

// array_macc() is provided by the including TU (host = plain C, board = XBUS).
void array_macc(const i8 Wi[4][4], const i8 xi[4], int32_t acc[4]);

// XOR data in Q8.8, padded to dim-4 (fixed, not RNG).
static const i64 M7_XP[4][4] = {{0,0,0,0},
                                {0,M7_ONE,0,0},
                                {M7_ONE,0,0,0},
                                {M7_ONE,M7_ONE,0,0}};
static const i64 M7_TV[4]    = {0, M7_ONE, M7_ONE, 0};

static i64 m7_clamp(i64 x, i64 lo, i64 hi) { return x < lo ? lo : (x > hi ? hi : x); }
static i64 m7_sat(i64 x)   { return m7_clamp(x, M7_QMIN, M7_QMAX); }
// Q8.8 * Q8.8 -> Q8.8, round-half-up then arithmetic shift (== M6 requant).
static i64 m7_qmul(i64 a, i64 b) { return ((a * b) + (1 << (M7_FRAC - 1))) >> M7_FRAC; }
static i64 m7_leaky(i64 z)   { return z >= 0 ? z : (z >> M7_K); }
static i64 m7_leaky_d(i64 z) { return z >= 0 ? M7_ONE : (M7_ONE >> M7_K); }
static i64 m7_q8(i64 v, int s) { return m7_clamp((v + (1 << (s - 1))) >> s, -128, 127); }

// Forward W·x: quantize Q8.8 master W,x to the INT8 array view, run the array,
// requant the INT32 acc back to Q8.8. array_macc() is the only hardware call.
static void m7_matmul(const i64 W[4][4], const i64 x[4], i64 z[4]) {
    i8 Wi[4][4], xi[4];
    int32_t acc[4];
    for (int j = 0; j < 4; j++) xi[j] = (i8)m7_q8(x[j], M7_XSHIFT);
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) Wi[i][j] = (i8)m7_q8(W[i][j], M7_WSHIFT);
    array_macc(Wi, xi, acc);                       // <-- 4x4 systolic array
    int down = 8 - M7_WSHIFT - M7_XSHIFT;
    for (int i = 0; i < 4; i++) {
        i64 a = acc[i];
        z[i] = m7_sat((down > 0) ? ((a + (1 << (down - 1))) >> down) : (a << (-down)));
    }
}

static void m7_forward(const i64 W1[4][4], const i64 b1[4],
                       const i64 W2[4][4], const i64 b2[4],
                       const i64 x[4], i64 z1[4], i64 h[4], i64 z2[4], i64 y[4]) {
    i64 t[4];
    m7_matmul(W1, x, t);
    for (int i = 0; i < 4; i++) { z1[i] = m7_sat(t[i] + b1[i]); h[i] = m7_leaky(z1[i]); }
    m7_matmul(W2, h, t);
    for (int i = 0; i < 4; i++) { z2[i] = m7_sat(t[i] + b2[i]); y[i] = m7_leaky(z2[i]); }
}

// Copy the host-seeded init master weights into the working set.
static void m7_init(i64 W1[4][4], i64 b1[4], i64 W2[4][4], i64 b2[4]) {
    for (int i = 0; i < 4; i++) {
        b1[i] = M7_INIT_B1[i]; b2[i] = M7_INIT_B2[i];
        for (int j = 0; j < 4; j++) { W1[i][j] = M7_INIT_W1[i][j]; W2[i][j] = M7_INIT_W2[i][j]; }
    }
}

// One online-SGD epoch (4 samples in the baked order); returns the epoch SSE.
static i64 m7_epoch(int ep, i64 W1[4][4], i64 b1[4], i64 W2[4][4], i64 b2[4]) {
    i64 sse = 0;
    for (int o = 0; o < 4; o++) {
        int s = M7_ORD(ep, o);
        const i64 *x = M7_XP[s];
        i64 z1[4], h[4], z2[4], y[4];
        m7_forward(W1, b1, W2, b2, x, z1, h, z2, y);

        // loss (lane 0 only: target lives in lane 0, other lanes are 0).
        i64 err[4];
        for (int i = 0; i < 4; i++) {
            i64 t = (i == 0) ? M7_TV[s] : 0;
            err[i] = m7_clamp(y[i] - t, -(1 << 20), (1 << 20) - 1);
        }
        sse += m7_qmul(err[0], err[0]);

        // backward
        i64 d2[4], dW2[4][4], d1[4], dW1[4][4];
        for (int i = 0; i < 4; i++)
            d2[i] = m7_clamp(m7_qmul(err[i], m7_leaky_d(z2[i])), -(1 << 14), (1 << 14) - 1);
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) dW2[i][j] = m7_qmul(d2[i], h[j]);    // d2 (x) h^T

        // delta1 = (W2^T . d2) (.) leaky'(z1) -- transpose reuse (Problem 1),
        // in master Q8.8 precision (matches the oracle).
        for (int i = 0; i < 4; i++) {
            i64 acc = 0;
            for (int j = 0; j < 4; j++) acc += W2[j][i] * d2[j];            // W2^T . d2
            i64 w2td2 = (acc + (1 << (M7_FRAC - 1))) >> M7_FRAC;
            d1[i] = m7_clamp(m7_qmul(w2td2, m7_leaky_d(z1[i])), -(1 << 14), (1 << 14) - 1);
        }
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) dW1[i][j] = m7_qmul(d1[i], x[j]);   // d1 (x) x^T

        // SGD update on master (saturating), lr = 2^-LR; keep unused parts clean.
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) W2[i][j] = m7_sat(W2[i][j] - (dW2[i][j] >> M7_LR_SHIFT));
        for (int i = 1; i < 4; i++) for (int j = 0; j < 4; j++) W2[i][j] = 0;
        for (int i = 0; i < 4; i++) b2[i] = m7_sat(b2[i] - (d2[i] >> M7_LR_SHIFT));
        for (int i = 1; i < 4; i++) b2[i] = 0;
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) W1[i][j] = m7_sat(W1[i][j] - (dW1[i][j] >> M7_LR_SHIFT));
        for (int i = 0; i < 4; i++) for (int j = 2; j < 4; j++) W1[i][j] = 0;
        for (int i = 0; i < 4; i++) b1[i] = m7_sat(b1[i] - (d1[i] >> M7_LR_SHIFT));
    }
    return sse;
}

#endif // M7_KERNEL_H
