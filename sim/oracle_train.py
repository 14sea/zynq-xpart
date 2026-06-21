#!/usr/bin/env python3
"""M7.0 fixed-point training oracle (golden reference for on-chip backprop).

A 2-4-1 leaky-MLP trained on XOR entirely in fixed-point, modelling exactly what
the EBAZ4205 firmware/hardware will do so the on-board LOSS curve and final
weights can be checked against this (target: <=1 LSB of the Q8.8 master).

Decisions (from docs/m7_plan.md "Open decisions", recommended values taken):
  - Q8.8 master weights (INT16-range), INT32 accumulators.
  - topology 2-4-1 (pad to the 4x4 array: input dim 2->4, hidden 4, output 1->4).
  - online SGD, power-of-two learning rate W -= dW >> LR_SHIFT (no divider).
  - leaky ReLU fwd + leaky' backward share the same shift k (== M6 VPU_ALPHA).
  - saturating master update + delta clamp (fixed-point overflow guard).

Two forward models, selectable, so we can separate "does fixed-point training
converge at all" from "does it survive the M6 INT8 forward array":
  --fwd q88     : Q8.8 throughout (tiny-tpu-style 16-bit-ish sanity).
  --fwd int8    : master Q8.8 -> INT8 quantized view for W*x (the M6 datapath),
                  activations quantized to INT8 with a power-of-two scale.

Algorithm (MSE loss, leaky deriv, SGD) referenced from tiny-tpu-v2/tiny-tpu
src/{loss,leaky_relu,gradient_descent}.sv (reference only, no RTL vendored).
"""
import argparse
import numpy as np

FRAC = 8                      # Q8.8
ONE = 1 << FRAC               # 1.0 in Q8.8 = 256
QMIN, QMAX = -(1 << 15), (1 << 15) - 1   # INT16 master range


def sat(x, lo=QMIN, hi=QMAX):
    return np.clip(x, lo, hi).astype(np.int64)


def q_mul(a, b):
    """Q8.8 * Q8.8 -> Q8.8, round-half-up, same as the M6 requant rounding."""
    p = a.astype(np.int64) * b.astype(np.int64)        # Q16.16
    return (p + (1 << (FRAC - 1))) >> FRAC             # arithmetic shift (floor for neg)


def leaky(z, k):
    """fwd leaky ReLU: z>=0 ? z : z>>k  (z in Q8.8)."""
    return np.where(z >= 0, z, z >> k)


def leaky_d(z, k):
    """leaky' in Q8.8: z>=0 ? 1.0 : 2^-k."""
    return np.where(z >= 0, ONE, ONE >> k).astype(np.int64)


def quant_int8(qval, scale_shift):
    """Q8.8 -> INT8 view: round-half-up after >>scale_shift, clamp [-128,127]."""
    v = (qval.astype(np.int64) + (1 << (scale_shift - 1))) >> scale_shift
    return np.clip(v, -128, 127).astype(np.int64)


def matmul_q88(W, x):
    """z[i] = sum_j W[i][j]*x[j] in Q8.8 (accumulate Q16.16, then >>FRAC)."""
    acc = (W.astype(np.int64) @ x.astype(np.int64))    # Q16.16
    return (acc + (1 << (FRAC - 1))) >> FRAC


def matmul_int8(W, x, wshift, xshift, out_shift=None):
    """Model the M6 INT8 array: quantize W,x to INT8, INT32 accumulate, requant
    back to Q8.8.  W_int8 = W_q88>>wshift ~ W_real*2^(8-wshift); likewise x.  So
    acc ~ (W.x)_real * 2^(16-wshift-xshift); to Q8.8 (x2^8) shift RIGHT by
    down=(8-wshift-xshift)  (left if negative)."""
    Wi = quant_int8(W, wshift)
    xi = quant_int8(x, xshift)
    acc = (Wi @ xi).astype(np.int64)                   # INT32 (INT8*INT8 sums)
    down = 8 - wshift - xshift
    z = (acc + (1 << (down - 1))) >> down if down > 0 else acc << (-down)
    return sat(z)


def forward(P, x, k, fwd, qcfg):
    if fwd == 'q88':
        z1 = sat(matmul_q88(P['W1'], x) + P['b1'])
    else:
        z1 = sat(matmul_int8(P['W1'], x, **qcfg) + P['b1'])
    h = leaky(z1, k)
    if fwd == 'q88':
        z2 = sat(matmul_q88(P['W2'], h) + P['b2'])
    else:
        z2 = sat(matmul_int8(P['W2'], h, **qcfg) + P['b2'])
    y = leaky(z2, k)
    return z1, h, z2, y


def train(seed=1, k=2, lr_shift=4, epochs=4000, fwd='q88', wshift=2, xshift=2, verbose=True):
    rng = np.random.default_rng(seed)
    # XOR data in Q8.8 (inputs/targets 0 or 1), padded to dim-4.
    X = np.array([[0, 0], [0, 1], [1, 0], [1, 1]], dtype=np.int64) * ONE
    T = np.array([0, 1, 1, 0], dtype=np.int64) * ONE
    Xp = np.zeros((4, 4), dtype=np.int64); Xp[:, :2] = X     # pad input to 4

    # host-seeded small init weights in Q8.8 (~ +-0.5)
    def init(shape):
        return sat(rng.integers(-ONE // 2, ONE // 2 + 1, size=shape))
    P = {
        'W1': init((4, 4)),   # hidden(4) x input(4); cols 2,3 unused (x pad=0)
        'b1': init((4,)),
        'W2': init((4, 4)),   # output rows; only row0 used (output dim 1)
        'b2': init((4,)),
    }
    # zero the structurally-unused parts so they stay clean
    P['W1'][:, 2:] = 0
    P['W2'][1:, :] = 0; P['b2'][1:] = 0

    qcfg = dict(wshift=wshift, xshift=xshift)   # int8 forward quantization
    losses = []
    for ep in range(epochs):
        order = rng.permutation(4)
        sse = 0
        for s in order:
            x = Xp[s]
            t = np.zeros(4, dtype=np.int64); t[0] = T[s]
            z1, h, z2, y = forward(P, x, k, fwd, qcfg)
            # loss (only output lane 0 active)
            err = sat(y - t, -(1 << 20), (1 << 20) - 1)          # (y - t) Q8.8
            sse += int(q_mul(err, err)[0])
            # backward
            d2 = sat(q_mul(err, leaky_d(z2, k)), -(1 << 14), (1 << 14) - 1)   # delta2
            dW2 = q_mul(d2.reshape(4, 1), h.reshape(1, 4))        # outer product
            db2 = d2
            # delta1 = (W2^T . d2) ⊙ leaky'(z1)   -- transpose reuse (Problem 1)
            w2td2 = (P['W2'].T.astype(np.int64) @ d2.astype(np.int64) + (1 << (FRAC - 1))) >> FRAC
            d1 = sat(q_mul(w2td2, leaky_d(z1, k)), -(1 << 14), (1 << 14) - 1)
            dW1 = q_mul(d1.reshape(4, 1), x.reshape(1, 4))
            db1 = d1
            # SGD update on master (saturating), lr = 2^-lr_shift
            P['W2'] = sat(P['W2'] - (dW2 >> lr_shift)); P['W2'][1:, :] = 0
            P['b2'] = sat(P['b2'] - (db2 >> lr_shift)); P['b2'][1:] = 0
            P['W1'] = sat(P['W1'] - (dW1 >> lr_shift)); P['W1'][:, 2:] = 0
            P['b1'] = sat(P['b1'] - (db1 >> lr_shift))
        losses.append(sse)
        if verbose and (ep % max(1, epochs // 20) == 0 or ep == epochs - 1):
            print(f"  epoch {ep:5d}  SSE(Q16.16)={sse:12d}  ~MSE={sse/4/ (ONE*ONE):.5f}")

    # final predictions
    print(f"\n  final XOR predictions (fwd={fwd}, k={k}, lr_shift={lr_shift}):")
    ok = 0
    for s in range(4):
        x = Xp[s]; _, _, _, y = forward(P, x, k, fwd, qcfg)
        pred = y[0] / ONE; tgt = T[s] / ONE
        hit = (pred > 0.5) == (tgt > 0.5)
        ok += hit
        print(f"    x={X[s]//ONE}  y={pred:+.3f}  t={tgt:.0f}  {'OK' if hit else 'MISS'}")
    print(f"  XOR correct: {ok}/4   final SSE={losses[-1]}")
    if verbose:
        print("\n  final master weights (Q8.8 ints) — golden ref for firmware <=1 LSB compare:")
        print("    W1[hidden4 x in2] =\n" + "\n".join(
            "      " + " ".join(f"{v:6d}" for v in row[:2]) for row in P['W1']))
        print("    b1 = " + " ".join(f"{v:6d}" for v in P['b1']))
        print("    W2[out1 x hid4]  = " + " ".join(f"{v:6d}" for v in P['W2'][0]))
        print(f"    b2 = {P['b2'][0]:6d}")
    return P, losses, ok


def main():
    ap = argparse.ArgumentParser()
    # Defaults = the HW-faithful golden config: INT8 forward view (the M6 array),
    # seed 3, Q8.8>>2 quant -> converges XOR 4/4, SSE=0.
    ap.add_argument('--fwd', choices=['q88', 'int8'], default='int8')
    ap.add_argument('--seed', type=int, default=3)
    ap.add_argument('--k', type=int, default=2)
    ap.add_argument('--lr-shift', type=int, default=4)
    ap.add_argument('--epochs', type=int, default=4000)
    ap.add_argument('--wshift', type=int, default=2)
    ap.add_argument('--xshift', type=int, default=2)
    args = ap.parse_args()
    print(f"== M7.0 fixed-point XOR training oracle (Q8.8, 2-4-1 leaky, fwd={args.fwd}) ==")
    P, losses, ok = train(args.seed, args.k, args.lr_shift, args.epochs, args.fwd,
                          args.wshift, args.xshift)
    print(f"\n== {'PASS' if ok == 4 else 'FAIL'}: XOR {ok}/4, loss {losses[0]} -> {losses[-1]} ==")


if __name__ == '__main__':
    main()
