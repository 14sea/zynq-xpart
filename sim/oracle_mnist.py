#!/usr/bin/env python3
"""M7.4 fixed-point MNIST-tile training oracle (golden reference for on-board
backprop on the EBAZ4205's 4x4 INT8 systolic array).

The bigger-workload sibling of sim/oracle_train.py (XOR). A 64-8-4 leaky-MLP
classifies 8x8-downsampled MNIST digits 0-3, trained end-to-end in fixed point,
modelling EXACTLY what the NEORV32 firmware + 4x4 array will do so the on-board
loss/accuracy curve and final weights can be bit-exact-checked against this.

Locked config (host convergence sweep, 2026-06-27 — see docs/m7_plan.md M7.4):
  - topology 64(=8x8) -> hidden 8 -> 4 (digits 0,1,2,3).  Tiles onto the 4x4
    array: L1 W1[8][64] = 2x16 4x4 tiles, L2 W2[4][8] = 1x2 tiles.
  - Q8.8 master weights (INT16 range), INT32 array accumulators.
  - FORWARD and BACKWARD(Wᵀ·δ) both on the INT8 array (M7.1 transpose-load);
    the host sweep proved int8==q88 to the bit at full batch, so no precision
    penalty for keeping the whole matmul path on the fabric.
  - inputs stored INT8 (x_q88 = xi8<<2, 6-bit pixels): halves baked data and is
    self-consistent (forward only ever uses x>>XSHIFT).
  - FULL-BATCH gradient descent: accumulate all NTRAIN sample grads in INT32,
    one saturating master update per epoch: W -= (ΣdW * LR_MUL) >> LR_SHIFT.
    Full batch == smooth monotonic curve (last-10 test-acc std 0.000) AND the
    simplest firmware (no mini-batch sub-loop, no shuffle, no baked order).
  - leaky ReLU fwd + leaky' backward share shift k (== M6 VPU_ALPHA).
  - saturating master update + δ clamp (fixed-point overflow guard).

MSE on one-hot targets (lane c = ONE for label c); accuracy = argmax(y) == label.
Loss/leaky'/SGD math referenced from tiny-tpu-v2/tiny-tpu (reference only, no RTL
vendored). Result: test acc climbs 25% -> ~92.5% across epochs, bit-exact HW==oracle.
"""
import argparse
import struct
import numpy as np

FRAC = 8                      # Q8.8
ONE = 1 << FRAC               # 1.0 in Q8.8 = 256
QMIN, QMAX = -(1 << 15), (1 << 15) - 1   # INT16 master range
DATA_DIR = "data/mnist"       # raw idx files (gitignored; OSSCI S3 mirror)

# ---- locked hyperparameters ----
CLASSES = (0, 1, 2, 3)
NIN, NH, NOUT = 64, 8, 4
NTRAIN, NTEST = 128, 40
EPOCHS = 60
K = 2                         # leaky shift
LR_SHIFT, LR_MUL = 9, 1       # full-batch lr = (ΣdW * LR_MUL) >> LR_SHIFT
WSHIFT, DSHIFT = 2, 2         # INT8 quant shifts (weights / deltas)
XSHIFT, XSHIFT_H = 2, 3       # activation INT8 shifts: input (folded into storage) / hidden.
                              # The hidden layer's activations span a larger range than the
                              # 6-bit inputs, so they need a bigger downshift to fit INT8
                              # without saturating at 127 — a faithful per-layer scale.
INIT_SCALE = 16               # init ~ +-ONE/16  (~ +-0.06)
SEED = 3                      # host weight-init seed (baked)
DATA_SEED = 0                 # MNIST sample-selection seed (baked dataset)


def sat(x, lo=QMIN, hi=QMAX):
    return np.clip(x, lo, hi).astype(np.int64)


def q_mul(a, b):
    """Q8.8 * Q8.8 -> Q8.8, round-half-up then arithmetic shift (== M6 requant)."""
    p = a.astype(np.int64) * b.astype(np.int64)
    return (p + (1 << (FRAC - 1))) >> FRAC


def leaky(z, k):
    return np.where(z >= 0, z, z >> k)


def leaky_d(z, k):
    return np.where(z >= 0, ONE, ONE >> k).astype(np.int64)


def quant_int8(qval, s):
    """Q8.8 -> INT8 view: round-half-up after >>s, clamp [-128,127]."""
    v = (qval.astype(np.int64) + (1 << (s - 1))) >> s
    return np.clip(v, -128, 127).astype(np.int64)


def array_mm(W, act_i8, wshift, ashift):
    """Model the M6 INT8 array: act_i8 is ALREADY the INT8 activation view, quantised
    with shift `ashift`. acc = Wi @ act_i8 (INT32), requant -> Q8.8 by down=8-wshift-ashift.
    Tiling into 4x4 blocks is a firmware detail; INT32 accumulation is associative so the
    full matmul is bit-identical to the tiled one."""
    Wi = quant_int8(W, wshift)
    acc = (Wi @ act_i8.astype(np.int64)).astype(np.int64)
    down = 8 - wshift - ashift
    z = (acc + (1 << (down - 1))) >> down if down > 0 else acc << (-down)
    return sat(z)


def array_fwd_x(W, xi8, wshift):
    """Layer 1 forward: input already stored INT8 (XSHIFT folded into storage)."""
    return array_mm(W, xi8, wshift, XSHIFT)


def array_fwd_h(W, h, wshift):
    """Layer 2 forward: hidden activation h is Q8.8, quantise to INT8 with XSHIFT_H."""
    return array_mm(W, quant_int8(h, XSHIFT_H), wshift, XSHIFT_H)


def array_wt_delta(W2, d2, wshift, dshift):
    """M7.1 Wᵀ·δ on the SAME array via transpose-load: out[i]=Σⱼ W2[j][i]·d2[j]."""
    Wi = quant_int8(W2, wshift)
    di = quant_int8(d2, dshift)
    acc = (Wi.T @ di).astype(np.int64)
    down = 8 - wshift - dshift
    z = (acc + (1 << (down - 1))) >> down if down > 0 else acc << (-down)
    return sat(z)


# ---------------------------------------------------------------- data
def _load_images(path):
    with open(path, "rb") as f:
        _, n, r, c = struct.unpack(">IIII", f.read(16))
        return np.frombuffer(f.read(), dtype=np.uint8).reshape(n, r, c)


def _load_labels(path):
    with open(path, "rb") as f:
        struct.unpack(">II", f.read(8))
        return np.frombuffer(f.read(), dtype=np.uint8)


def _pool_matrix(src=28, dst=8):
    """Area-average resampling matrix P (dst x src): img8 = P @ img28 @ P.T."""
    P = np.zeros((dst, src))
    edges = np.linspace(0, src, dst + 1)
    for o in range(dst):
        lo, hi = edges[o], edges[o + 1]
        for i in range(src):
            P[o, i] = max(0, min(hi, i + 1) - max(lo, i))
        P[o] /= P[o].sum()
    return P


def load_dataset(data_dir=DATA_DIR):
    """Return (train_x int8[NTRAIN][64] in [0,64], train_y, test_x, test_y),
    deterministic given DATA_SEED. 8x8 area-pool, 6-bit pixel storage
    (xi8 = round(pixel/255 * 64) = forward INT8 view with XSHIFT=2)."""
    P = _pool_matrix()
    rng = np.random.default_rng(DATA_SEED)

    def take(imgs_path, lbls_path, n):
        X = _load_images(imgs_path).astype(np.float64) / 255.0
        Y = _load_labels(lbls_path)
        per = n // len(CLASSES)
        xs, ys = [], []
        for ci, c in enumerate(CLASSES):
            idx = rng.permutation(np.where(Y == c)[0])[:per]
            for i in idx:
                small = P @ X[i] @ P.T            # 8x8 float in [0,1]
                xs.append(small.flatten())
                ys.append(ci)
        xs = np.array(xs); ys = np.array(ys)
        o = rng.permutation(len(ys))
        xs, ys = xs[o], ys[o]
        # 6-bit storage: round(pixel*256)>>2 == round(pixel*64), clamp [0,127]
        xi8 = np.clip((np.round(xs * ONE).astype(np.int64) + 2) >> 2, 0, 127)
        return xi8.astype(np.int64), ys.astype(np.int64)

    trx, trY = take(f"{data_dir}/train-images-idx3-ubyte",
                    f"{data_dir}/train-labels-idx1-ubyte", NTRAIN)
    tex, teY = take(f"{data_dir}/t10k-images-idx3-ubyte",
                    f"{data_dir}/t10k-labels-idx1-ubyte", NTEST)
    return trx, trY, tex, teY


# ---------------------------------------------------------------- train
def forward(P, xi8):
    z1 = sat(array_fwd_x(P['W1'], xi8, WSHIFT) + P['b1'])
    h = leaky(z1, K)
    z2 = sat(array_fwd_h(P['W2'], h, WSHIFT) + P['b2'])
    y = leaky(z2, K)
    return z1, h, z2, y


def accuracy(P, X, Y):
    ok = 0
    for i in range(len(Y)):
        _, _, _, y = forward(P, X[i])
        ok += int(np.argmax(y[:NOUT]) == Y[i])
    return ok / len(Y)


def init_master(seed=SEED):
    rng = np.random.default_rng(seed)
    def init(shape):
        return sat(rng.integers(-ONE // INIT_SCALE, ONE // INIT_SCALE + 1, size=shape))
    return {'W1': init((NH, NIN)), 'b1': init((NH,)),
            'W2': init((NOUT, NH)), 'b2': init((NOUT,))}


def train(trx, trY, tex, teY, epochs=EPOCHS, verbose=True, init_log=None):
    P = init_master()
    if init_log is not None:
        init_log.update({n: P[n].copy() for n in P})
    losses, accs = [], []
    for ep in range(epochs):
        # full-batch: accumulate every sample's grad, one update per epoch
        aW1 = np.zeros((NH, NIN), np.int64); ab1 = np.zeros(NH, np.int64)
        aW2 = np.zeros((NOUT, NH), np.int64); ab2 = np.zeros(NOUT, np.int64)
        sse = 0
        for s in range(NTRAIN):
            xi8 = trx[s]; xq = xi8 << 2                       # x_q88 for the weight grad
            t = np.zeros(NOUT, np.int64); t[trY[s]] = ONE
            z1, h, z2, y = forward(P, xi8)
            err = sat(y[:NOUT] - t, -(1 << 20), (1 << 20) - 1)
            sse += int(np.sum(q_mul(err, err)))
            d2 = sat(q_mul(err, leaky_d(z2, K)), -(1 << 14), (1 << 14) - 1)
            w2td2 = array_wt_delta(P['W2'], d2, WSHIFT, DSHIFT)
            d1 = sat(q_mul(w2td2, leaky_d(z1, K)), -(1 << 14), (1 << 14) - 1)
            aW2 += q_mul(d2.reshape(NOUT, 1), h.reshape(1, NH)); ab2 += d2
            aW1 += q_mul(d1.reshape(NH, 1), xq.reshape(1, NIN)); ab1 += d1
        P['W2'] = sat(P['W2'] - ((aW2 * LR_MUL) >> LR_SHIFT))
        P['b2'] = sat(P['b2'] - ((ab2 * LR_MUL) >> LR_SHIFT))
        P['W1'] = sat(P['W1'] - ((aW1 * LR_MUL) >> LR_SHIFT))
        P['b1'] = sat(P['b1'] - ((ab1 * LR_MUL) >> LR_SHIFT))
        losses.append(int(sse))
        accs.append(accuracy(P, tex, teY))
        if verbose and (ep % max(1, epochs // 20) == 0 or ep == epochs - 1):
            print(f"  ep{ep:3d}  SSE={sse:9d}  train_acc={accuracy(P, trx, trY):.3f}"
                  f"  test_acc={accs[-1]:.3f}")
    return P, losses, accs


# ---------------------------------------------------------------- header dump
def _arr2d_i(name, a, ctype="short"):
    rows = ",\n  ".join("{" + ",".join(f"{int(v):d}" for v in row) + "}" for row in a)
    return f"static const {ctype} {name}[{a.shape[0]}][{a.shape[1]}] = {{\n  {rows}\n}};\n"


def _arr1d_i(name, a, ctype="short"):
    return f"static const {ctype} {name}[{len(a)}] = {{ " + ",".join(f"{int(v):d}" for v in a) + " };\n"


def dump_header(path):
    trx, trY, tex, teY = load_dataset()
    init_log = {}
    P, losses, accs = train(trx, trY, tex, teY, verbose=False, init_log=init_log)
    final = accuracy(P, tex, teY)
    print(f"oracle: test_acc 25% -> {accs[-1]:.3f} (peak {max(accs):.3f}), "
          f"SSE {losses[0]} -> {losses[-1]}")
    with open(path, "w") as f:
        f.write("// AUTO-GENERATED by sim/oracle_mnist.py --dump-header — DO NOT EDIT.\n")
        f.write(f"// M7.4 MNIST-tile golden: {NIN}-{NH}-{NOUT}, digits {CLASSES}, "
                f"full-batch, seed={SEED}, epochs={EPOCHS}\n")
        f.write(f"// final test_acc={final:.3f} peak={max(accs):.3f}\n")
        f.write("#ifndef M7_MNIST_VECTORS_H\n#define M7_MNIST_VECTORS_H\n\n")
        for n, v in (("M7M_FRAC", FRAC), ("M7M_K", K), ("M7M_LR_SHIFT", LR_SHIFT),
                     ("M7M_LR_MUL", LR_MUL), ("M7M_WSHIFT", WSHIFT), ("M7M_DSHIFT", DSHIFT),
                     ("M7M_XSHIFT", XSHIFT), ("M7M_XSHIFT_H", XSHIFT_H),
                     ("M7M_NIN", NIN), ("M7M_NH", NH), ("M7M_NOUT", NOUT),
                     ("M7M_NTRAIN", NTRAIN), ("M7M_NTEST", NTEST), ("M7M_EPOCHS", EPOCHS)):
            f.write(f"#define {n:14s} {v}\n")
        f.write("\n// --- host-seeded init master weights (Q8.8) ---\n")
        f.write(_arr2d_i("M7M_INIT_W1", init_log['W1']))
        f.write(_arr1d_i("M7M_INIT_B1", init_log['b1']))
        f.write(_arr2d_i("M7M_INIT_W2", init_log['W2']))
        f.write(_arr1d_i("M7M_INIT_B2", init_log['b2']))
        f.write("\n// --- baked dataset: inputs stored INT8 (6-bit pixels, x_q88 = v<<2) ---\n")
        f.write(_arr2d_i("M7M_TRAIN_X", trx, "signed char"))
        f.write(_arr1d_i("M7M_TRAIN_Y", trY, "unsigned char"))
        f.write(_arr2d_i("M7M_TEST_X", tex, "signed char"))
        f.write(_arr1d_i("M7M_TEST_Y", teY, "unsigned char"))
        f.write("\n// --- golden results (this oracle) for the host C self-check ---\n")
        f.write("// Excluded from the on-board build (M7_BOARD): the board only needs\n")
        f.write("// init+data; it streams its own loss/acc over the PS mailbox.\n")
        f.write("#ifndef M7_BOARD\n")
        f.write(_arr2d_i("M7M_GOLD_W1", P['W1']))
        f.write(_arr1d_i("M7M_GOLD_B1", P['b1']))
        f.write(_arr2d_i("M7M_GOLD_W2", P['W2']))
        f.write(_arr1d_i("M7M_GOLD_B2", P['b2']))
        f.write(f"static const long M7M_GOLD_LOSS[{EPOCHS}] = {{\n")
        f.write(",".join(str(v) for v in losses))
        f.write("\n};\n")
        f.write(f"// golden per-epoch test accuracy x1000 (integer, for board compare)\n")
        f.write(_arr1d_i("M7M_GOLD_ACC1000", np.round(np.array(accs) * 1000).astype(np.int64), "short"))
        f.write("#endif // !M7_BOARD\n\n#endif // M7_MNIST_VECTORS_H\n")
    print(f"wrote {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--epochs', type=int, default=EPOCHS)
    ap.add_argument('--dump-header', metavar='PATH',
                    help='write the C golden header for the firmware/host and exit')
    args = ap.parse_args()
    if args.dump_header:
        dump_header(args.dump_header)
        return
    print(f"== M7.4 MNIST-tile training oracle ({NIN}-{NH}-{NOUT}, digits {CLASSES}, "
          f"full-batch fixed-point) ==")
    trx, trY, tex, teY = load_dataset()
    print(f"dataset: train {len(trY)}  test {len(teY)}  (8x8 INT8 pixels)")
    P, losses, accs = train(trx, trY, tex, teY, epochs=args.epochs)
    print(f"\n== test_acc {accs[0]:.3f} -> {accs[-1]:.3f} (peak {max(accs):.3f}), "
          f"SSE {losses[0]} -> {losses[-1]} ==")


if __name__ == '__main__':
    main()
