// m7_mnist_kernel.h — shared fixed-point MNIST-tile backprop kernel (M7.4).
//
// The bigger-workload sibling of m7_kernel.h (XOR). SINGLE source of the training
// math, included verbatim by both the host validator (mnist_host.c) and the NEORV32
// board firmware. The host proves it bit-exact against the numpy oracle
// (sim/oracle_mnist.py); the board runs the EXACT same code — only array_macc()
// (the 4x4 systolic-array matmul) differs between the two translation units.
//
// Net: 64(=8x8) -> hidden 8 -> 4 (digits 0-3), leaky-MLP, MSE one-hot, full-batch GD.
// The 8x64 / 4x8 / 8x4 matmuls are TILED into 4x4 blocks; array_macc() is the only
// hardware call and runs one 4x4 tile (acc[i]=Σⱼ Wi[i][j]·xi[j], signed INT32). INT32
// accumulation is associative, so the tiled result is bit-identical to a full matmul.
//
// All arithmetic is int64 to mirror numpy int64 exactly; right shifts of negatives
// MUST be arithmetic (floor) — true on gcc/clang and RISC-V (srai).
//
// Each TU MUST define array_macc() before including this header:
//   void array_macc(const i8 Wi[4][4], const i8 xi[4], int32_t acc[4]);

#ifndef M7_MNIST_KERNEL_H
#define M7_MNIST_KERNEL_H

#include <stdint.h>
#include "m7_mnist_vectors.h"   // dims/shifts + INIT + DATASET (+ golden if !M7_BOARD)

typedef int64_t     i64;
typedef signed char i8;

#define M7_ONE   (1 << M7M_FRAC)
#define M7_QMIN  (-(1 << 15))
#define M7_QMAX  ((1 << 15) - 1)
#define M7M_RMAX 8              // largest matmul output dim (hidden=8)

// array_macc() provided by the including TU (host = plain C, board = XBUS array).
void array_macc(const i8 Wi[4][4], const i8 xi[4], int32_t acc[4]);

static i64 m7_clamp(i64 x, i64 lo, i64 hi) { return x < lo ? lo : (x > hi ? hi : x); }
static i64 m7_sat(i64 x)   { return m7_clamp(x, M7_QMIN, M7_QMAX); }
static i64 m7_qmul(i64 a, i64 b) { return ((a * b) + (1 << (M7M_FRAC - 1))) >> M7M_FRAC; }
static i64 m7_leaky(i64 z)   { return z >= 0 ? z : (z >> M7M_K); }
static i64 m7_leaky_d(i64 z) { return z >= 0 ? M7_ONE : (M7_ONE >> M7M_K); }
static i64 m7_q8(i64 v, int s) { return m7_clamp((v + (1 << (s - 1))) >> s, -128, 127); }

// W element accessor: normal W[i][j] or transposed W[j][i] (for the Wᵀ·δ load).
static i64 m7_wget(const i64 *W, int wstride, int transpose, int i, int j) {
    return transpose ? W[j * wstride + i] : W[i * wstride + j];
}

// Tiled INT8 array matmul: z[0..NR) = requant( Wi(NRxNC) @ ai8(NC) ).  Wi = INT8
// view of the Q8.8 master (per-element m7_q8 with `wshift`); ai8 is the caller's
// INT8 activation view (quantised with `ashift`).  Tiles 4x4; array_macc per tile.
static void m7_mm(const i64 *W, int NR, int NC, int wstride, int transpose,
                  const i8 *ai8, int wshift, int ashift, i64 *z) {
    int32_t acc[M7M_RMAX];
    for (int i = 0; i < NR; i++) acc[i] = 0;
    i8 Wt[4][4], xt[4];
    int32_t part[4];
    for (int rt = 0; rt < NR; rt += 4) {
        for (int ct = 0; ct < NC; ct += 4) {
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++)
                    Wt[i][j] = (i8)m7_q8(m7_wget(W, wstride, transpose, rt + i, ct + j), wshift);
            for (int j = 0; j < 4; j++) xt[j] = ai8[ct + j];
            array_macc(Wt, xt, part);                 // <-- the 4x4 systolic array
            for (int i = 0; i < 4; i++) acc[rt + i] += part[i];
        }
    }
    int down = 8 - wshift - ashift;
    for (int i = 0; i < NR; i++)
        z[i] = (down > 0) ? m7_sat(((i64)acc[i] + (1 << (down - 1))) >> down)
                          : m7_sat((i64)acc[i] << (-down));
}

// Forward: x already INT8 (stored 6-bit).  z1 = W1·x + b1 ; h = leaky(z1) ;
// z2 = W2·quant(h) + b2 ; y = leaky(z2).  Hidden uses XSHIFT_H (wider range).
static void m7_forward(const i64 W1[M7M_NH][M7M_NIN], const i64 b1[M7M_NH],
                       const i64 W2[M7M_NOUT][M7M_NH], const i64 b2[M7M_NOUT],
                       const i8 xi8[M7M_NIN],
                       i64 z1[M7M_NH], i64 h[M7M_NH], i64 z2[M7M_NOUT], i64 y[M7M_NOUT]) {
    i64 t[M7M_RMAX];
    m7_mm(&W1[0][0], M7M_NH, M7M_NIN, M7M_NIN, 0, xi8, M7M_WSHIFT, M7M_XSHIFT, t);
    for (int i = 0; i < M7M_NH; i++) { z1[i] = m7_sat(t[i] + b1[i]); h[i] = m7_leaky(z1[i]); }
    i8 hi8[M7M_NH];
    for (int i = 0; i < M7M_NH; i++) hi8[i] = (i8)m7_q8(h[i], M7M_XSHIFT_H);
    m7_mm(&W2[0][0], M7M_NOUT, M7M_NH, M7M_NH, 0, hi8, M7M_WSHIFT, M7M_XSHIFT_H, t);
    for (int i = 0; i < M7M_NOUT; i++) { z2[i] = m7_sat(t[i] + b2[i]); y[i] = m7_leaky(z2[i]); }
}

static int m7_argmax(const i64 y[M7M_NOUT]) {
    int best = 0;
    for (int i = 1; i < M7M_NOUT; i++) if (y[i] > y[best]) best = i;
    return best;
}

static void m7_init(i64 W1[M7M_NH][M7M_NIN], i64 b1[M7M_NH],
                    i64 W2[M7M_NOUT][M7M_NH], i64 b2[M7M_NOUT]) {
    for (int i = 0; i < M7M_NH; i++) {
        b1[i] = M7M_INIT_B1[i];
        for (int j = 0; j < M7M_NIN; j++) W1[i][j] = M7M_INIT_W1[i][j];
    }
    for (int i = 0; i < M7M_NOUT; i++) {
        b2[i] = M7M_INIT_B2[i];
        for (int j = 0; j < M7M_NH; j++) W2[i][j] = M7M_INIT_W2[i][j];
    }
}

// One full-batch epoch: accumulate every train sample's gradient, then ONE
// saturating master update: W -= (ΣdW * LR_MUL) >> LR_SHIFT.  Returns epoch SSE.
static i64 m7_epoch(i64 W1[M7M_NH][M7M_NIN], i64 b1[M7M_NH],
                    i64 W2[M7M_NOUT][M7M_NH], i64 b2[M7M_NOUT]) {
    // static (not stack): the NH×NIN accumulator is 4 KB; on the NEORV32 board (16 KB
    // DMEM) keeping it off the stack avoids piling it on main's master arrays. Single-
    // threaded and re-zeroed every call below, so static is safe & bit-exact.
    static i64 aW1[M7M_NH][M7M_NIN], ab1[M7M_NH];
    static i64 aW2[M7M_NOUT][M7M_NH], ab2[M7M_NOUT];
    for (int i = 0; i < M7M_NH; i++) { ab1[i] = 0; for (int j = 0; j < M7M_NIN; j++) aW1[i][j] = 0; }
    for (int i = 0; i < M7M_NOUT; i++) { ab2[i] = 0; for (int j = 0; j < M7M_NH; j++) aW2[i][j] = 0; }

    i64 sse = 0;
    for (int s = 0; s < M7M_NTRAIN; s++) {
        const i8 *xi8 = M7M_TRAIN_X[s];
        i64 z1[M7M_NH], h[M7M_NH], z2[M7M_NOUT], y[M7M_NOUT];
        m7_forward(W1, b1, W2, b2, xi8, z1, h, z2, y);

        // MSE on one-hot target (lane = label).
        i64 err[M7M_NOUT];
        for (int i = 0; i < M7M_NOUT; i++) {
            i64 t = (i == (int)M7M_TRAIN_Y[s]) ? M7_ONE : 0;
            err[i] = m7_clamp(y[i] - t, -(1 << 20), (1 << 20) - 1);
            sse += m7_qmul(err[i], err[i]);
        }

        // backward
        i64 d2[M7M_NOUT];
        for (int i = 0; i < M7M_NOUT; i++)
            d2[i] = m7_clamp(m7_qmul(err[i], m7_leaky_d(z2[i])), -(1 << 14), (1 << 14) - 1);

        // W2ᵀ·d2 on the SAME array via transpose-load (NR=NH, NC=NOUT).
        i8 di8[M7M_NOUT];
        for (int i = 0; i < M7M_NOUT; i++) di8[i] = (i8)m7_q8(d2[i], M7M_DSHIFT);
        i64 w2td2[M7M_NH];
        m7_mm(&W2[0][0], M7M_NH, M7M_NOUT, M7M_NH, /*transpose=*/1,
              di8, M7M_WSHIFT, M7M_DSHIFT, w2td2);

        i64 d1[M7M_NH];
        for (int i = 0; i < M7M_NH; i++)
            d1[i] = m7_clamp(m7_qmul(w2td2[i], m7_leaky_d(z1[i])), -(1 << 14), (1 << 14) - 1);

        // accumulate outer-product grads (full batch). x_q88 = xi8 << XSHIFT.
        for (int i = 0; i < M7M_NOUT; i++) {
            for (int j = 0; j < M7M_NH; j++) aW2[i][j] += m7_qmul(d2[i], h[j]);
            ab2[i] += d2[i];
        }
        for (int i = 0; i < M7M_NH; i++) {
            for (int j = 0; j < M7M_NIN; j++)
                aW1[i][j] += m7_qmul(d1[i], (i64)xi8[j] << M7M_XSHIFT);
            ab1[i] += d1[i];
        }
    }

    // one saturating master update per epoch
    for (int i = 0; i < M7M_NOUT; i++) {
        for (int j = 0; j < M7M_NH; j++) W2[i][j] = m7_sat(W2[i][j] - ((aW2[i][j] * M7M_LR_MUL) >> M7M_LR_SHIFT));
        b2[i] = m7_sat(b2[i] - ((ab2[i] * M7M_LR_MUL) >> M7M_LR_SHIFT));
    }
    for (int i = 0; i < M7M_NH; i++) {
        for (int j = 0; j < M7M_NIN; j++) W1[i][j] = m7_sat(W1[i][j] - ((aW1[i][j] * M7M_LR_MUL) >> M7M_LR_SHIFT));
        b1[i] = m7_sat(b1[i] - ((ab1[i] * M7M_LR_MUL) >> M7M_LR_SHIFT));
    }
    return sse;
}

// Count correct predictions over the held-out test tile.
static int m7_test_correct(const i64 W1[M7M_NH][M7M_NIN], const i64 b1[M7M_NH],
                           const i64 W2[M7M_NOUT][M7M_NH], const i64 b2[M7M_NOUT]) {
    int ok = 0;
    for (int s = 0; s < M7M_NTEST; s++) {
        i64 z1[M7M_NH], h[M7M_NH], z2[M7M_NOUT], y[M7M_NOUT];
        m7_forward(W1, b1, W2, b2, M7M_TEST_X[s], z1, h, z2, y);
        if (m7_argmax(y) == (int)M7M_TEST_Y[s]) ok++;
    }
    return ok;
}

#endif // M7_MNIST_KERNEL_H
