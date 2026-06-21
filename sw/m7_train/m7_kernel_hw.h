// m7_kernel_hw.h — M7.2 training kernel with the "trio" in HARDWARE (train_unit.v).
//
// Same shared-kernel pattern as m7_kernel.h (M7.0/M7.1): ONE source of the training
// loop, included by both the host validator (train_xor_hw.c) and the NEORV32 board
// firmware (main.c). What differs per translation unit is only the leaf accessors:
//   - array_macc()  : the 4x4 INT8 systolic array  (plain C on host / XBUS on board)
//   - the tu_*()     : the train_unit trio          (C model on host / XBUS on board)
//
// vs m7_kernel.h, the loss / leaky' / δ / SGD-update + the MASTER WEIGHTS move OUT of
// software into train_unit (the M7.2 milestone). Software keeps only: the forward
// requant+bias+leaky (unchanged from M7.1), the two systolic matmuls (forward W·x and
// backward Wᵀ·δ transpose-load), and the rank-1 outer products dW=δ⊗xᵀ (16 MACs).
// The C master arrays here are a MIRROR refreshed from the TU after every update —
// the hardware copy is authoritative (it is what the SGD update writes).
//
// Bit-exact contract: identical fixed-point to sim/oracle_train.py. train_unit.v is
// proven bit-exact in sim/tb_train.v; train_xor_hw.c proves this whole HW/SW split
// reproduces the oracle on the host before any board time.

#ifndef M7_KERNEL_HW_H
#define M7_KERNEL_HW_H

#include "m7_kernel.h"   // primitives (m7_qmul/m7_sat/m7_clamp/m7_leaky/m7_q8/m7_leaky_d),
                          // the SW forward (m7_forward / m7_matmul), the transpose matmul
                          // (m7_w2t_delta), m7_init, and M7_XP / M7_TV / M7_ORD.

// ── train_unit accessors — provided by the including TU (host model / board XBUS) ──
// The TU holds the master weights and performs the trio:
void tu_master_load(const i64 W1[4][4], const i64 b1[4], const i64 W2[4][4], const i64 b2[4]);
void tu_master_read(i64 W1[4][4], i64 b1[4], i64 W2[4][4], i64 b2[4]);   // HW -> C mirror
void tu_clr_loss(void);
i64  tu_get_loss(void);
// loss += qmul(err0,err0); d2 = clamp(qmul(clamp(y-t), leaky'(z2)))  [HW]
void tu_loss_d2(const i64 y[4], const i64 z2[4], const i64 t[4], i64 d2_out[4]);
// d1 = clamp(qmul(w2td2, leaky'(z1)))  [HW]
void tu_d1(const i64 w2td2[4], const i64 z1[4], i64 d1_out[4]);
void tu_upd_l2(const i64 dw2[4]);   // W2,b2 ← sat(· − grad>>LR)  [HW; uses last d2]
void tu_upd_l1(const i64 dw1[8]);   // W1,b1 ← sat(· − grad>>LR)  [HW; uses last d1]

// One online-SGD epoch (4 samples in the baked order). The forward + transpose
// matmuls run on the array; the loss/δ/update run in train_unit. Returns the epoch
// SSE read back from the hardware loss accumulator.
static i64 m7_epoch_hw(int ep, i64 W1[4][4], i64 b1[4], i64 W2[4][4], i64 b2[4]) {
    tu_clr_loss();                          // HW loss accumulator, reset per epoch
    for (int o = 0; o < 4; o++) {
        int s = M7_ORD(ep, o);
        const i64 *x = M7_XP[s];
        i64 z1[4], h[4], z2[4], y[4];
        m7_forward(W1, b1, W2, b2, x, z1, h, z2, y);     // SW forward (array W·x inside)

        i64 t[4] = { M7_TV[s], 0, 0, 0 };                // target (lane0 only for XOR)

        i64 d2[4];
        tu_loss_d2(y, z2, t, d2);                        // HW: loss += , output-layer δ

        i64 w2td2[4];
        m7_w2t_delta(W2, d2, w2td2);                     // array Wᵀ·δ (transpose-load) + SW requant
        i64 d1[4];
        tu_d1(w2td2, z1, d1);                            // HW: hidden-layer δ

        i64 dw2[4];
        for (int j = 0; j < 4; j++) dw2[j] = m7_qmul(d2[0], h[j]);          // SW outer product δ2⊗hᵀ (row0)
        i64 dw1[8];
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 2; j++) dw1[i*2 + j] = m7_qmul(d1[i], x[j]); // SW outer product δ1⊗xᵀ

        tu_upd_l2(dw2);                                  // HW: SGD update W2,b2 (master)
        tu_upd_l1(dw1);                                  // HW: SGD update W1,b1 (master)
        tu_master_read(W1, b1, W2, b2);                  // refresh C mirror from HW master
    }
    return tu_get_loss();
}

// Seed both the C mirror and the hardware master with the host-seeded init weights.
static void m7_init_hw(i64 W1[4][4], i64 b1[4], i64 W2[4][4], i64 b2[4]) {
    m7_init(W1, b1, W2, b2);
    tu_master_load(W1, b1, W2, b2);
}

#endif // M7_KERNEL_HW_H
