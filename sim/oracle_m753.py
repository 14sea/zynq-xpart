#!/usr/bin/env python3
"""M7.5.3-lite oracle: a 4(=2x2)->4->2 fixed-point classifier (MNIST 0 vs 1,
area-pooled 28x28 -> 2x2) whose WHOLE 2-layer net time-folds onto a SINGLE 4x4
LUT-KCM tile — L1 W1[4][4] = one tile, L2 W2[2][4] = one tile (padded). So the
on-board inference is exactly two array passes with the LUT-KCM weights ICAP-baked
to W1 (pass 1) then W2 (pass 2): every weight of the net is computed in hardwired,
ICAP-editable LUT logic, the layers folded in time onto one tile (the spatial
whole-net LUT-KCM doesn't fit XC7Z010: one tile already = 80% of the RP LUTs).

Same fixed-point math as sim/oracle_tiny.py, so the shared kernel m7_mnist_kernel.h
(which already 4x4-tiles every matmul) reproduces it bit-exact and IS the on-board
per-tile execution. Smaller input (4 vs 16) is what makes L1 a single tile.
"""
import argparse, struct
import numpy as np

FRAC = 8
ONE = 1 << FRAC
QMIN, QMAX = -(1 << 15), (1 << 15) - 1
DATA_DIR = "data/mnist"

CLASSES = (0, 1)
NIN, NH, NOUT = 4, 4, 2
NTRAIN, NTEST = 64, 40
EPOCHS = 60
K = 2
LR_SHIFT, LR_MUL = 7, 1
WSHIFT, DSHIFT = 2, 2
XSHIFT, XSHIFT_H = 2, 3
INIT_SCALE = 16
SEED = 3
DATA_SEED = 0
POOL = 2


def sat(x, lo=QMIN, hi=QMAX): return np.clip(x, lo, hi).astype(np.int64)
def q_mul(a, b):
    p = a.astype(np.int64) * b.astype(np.int64)
    return (p + (1 << (FRAC - 1))) >> FRAC
def leaky(z, k): return np.where(z >= 0, z, z >> k)
def leaky_d(z, k): return np.where(z >= 0, ONE, ONE >> k).astype(np.int64)
def quant_int8(qval, s):
    v = (qval.astype(np.int64) + (1 << (s - 1))) >> s
    return np.clip(v, -128, 127).astype(np.int64)


def array_mm(W, act_i8, wshift, ashift):
    Wi = quant_int8(W, wshift)
    acc = (Wi @ act_i8.astype(np.int64)).astype(np.int64)
    down = 8 - wshift - ashift
    z = (acc + (1 << (down - 1))) >> down if down > 0 else acc << (-down)
    return sat(z)
def array_fwd_x(W, xi8, wshift): return array_mm(W, xi8, wshift, XSHIFT)
def array_fwd_h(W, h, wshift): return array_mm(W, quant_int8(h, XSHIFT_H), wshift, XSHIFT_H)
def array_wt_delta(W2, d2, wshift, dshift):
    Wi = quant_int8(W2, wshift); di = quant_int8(d2, dshift)
    acc = (Wi.T @ di).astype(np.int64)
    down = 8 - wshift - dshift
    z = (acc + (1 << (down - 1))) >> down if down > 0 else acc << (-down)
    return sat(z)


def _load_images(path):
    with open(path, "rb") as f:
        _, n, r, c = struct.unpack(">IIII", f.read(16))
        return np.frombuffer(f.read(), dtype=np.uint8).reshape(n, r, c)
def _load_labels(path):
    with open(path, "rb") as f:
        struct.unpack(">II", f.read(8)); return np.frombuffer(f.read(), dtype=np.uint8)
def _pool_matrix(src=28, dst=POOL):
    P = np.zeros((dst, src)); edges = np.linspace(0, src, dst + 1)
    for o in range(dst):
        lo, hi = edges[o], edges[o + 1]
        for i in range(src): P[o, i] = max(0, min(hi, i + 1) - max(lo, i))
        P[o] /= P[o].sum()
    return P


def load_dataset(data_dir=DATA_DIR):
    P = _pool_matrix(); rng = np.random.default_rng(DATA_SEED)
    def take(ip, lp, n):
        X = _load_images(ip).astype(np.float64) / 255.0; Y = _load_labels(lp)
        per = n // len(CLASSES); xs, ys = [], []
        for ci, c in enumerate(CLASSES):
            idx = rng.permutation(np.where(Y == c)[0])[:per]
            for i in idx:
                xs.append((P @ X[i] @ P.T).flatten()); ys.append(ci)
        xs = np.array(xs); ys = np.array(ys); o = rng.permutation(len(ys))
        xs, ys = xs[o], ys[o]
        xi8 = np.clip((np.round(xs * ONE).astype(np.int64) + 2) >> 2, 0, 127)
        return xi8.astype(np.int64), ys.astype(np.int64)
    trx, trY = take(f"{data_dir}/train-images-idx3-ubyte", f"{data_dir}/train-labels-idx1-ubyte", NTRAIN)
    tex, teY = take(f"{data_dir}/t10k-images-idx3-ubyte", f"{data_dir}/t10k-labels-idx1-ubyte", NTEST)
    return trx, trY, tex, teY


def forward(P, xi8):
    z1 = sat(array_fwd_x(P['W1'], xi8, WSHIFT) + P['b1']); h = leaky(z1, K)
    z2 = sat(array_fwd_h(P['W2'], h, WSHIFT) + P['b2']); y = leaky(z2, K)
    return z1, h, z2, y
def accuracy(P, X, Y):
    return sum(int(np.argmax(forward(P, X[i])[3][:NOUT]) == Y[i]) for i in range(len(Y))) / len(Y)
def init_master(seed=SEED):
    rng = np.random.default_rng(seed)
    def init(shape): return sat(rng.integers(-ONE // INIT_SCALE, ONE // INIT_SCALE + 1, size=shape))
    return {'W1': init((NH, NIN)), 'b1': init((NH,)), 'W2': init((NOUT, NH)), 'b2': init((NOUT,))}


def train(trx, trY, tex, teY, epochs=EPOCHS, verbose=True, init_log=None, lr_shift=LR_SHIFT):
    P = init_master()
    if init_log is not None: init_log.update({n: P[n].copy() for n in P})
    losses, accs = [], []
    for ep in range(epochs):
        aW1 = np.zeros((NH, NIN), np.int64); ab1 = np.zeros(NH, np.int64)
        aW2 = np.zeros((NOUT, NH), np.int64); ab2 = np.zeros(NOUT, np.int64); sse = 0
        for s in range(NTRAIN):
            xi8 = trx[s]; xq = xi8 << 2
            t = np.zeros(NOUT, np.int64); t[trY[s]] = ONE
            z1, h, z2, y = forward(P, xi8)
            err = sat(y[:NOUT] - t, -(1 << 20), (1 << 20) - 1); sse += int(np.sum(q_mul(err, err)))
            d2 = sat(q_mul(err, leaky_d(z2, K)), -(1 << 14), (1 << 14) - 1)
            w2td2 = array_wt_delta(P['W2'], d2, WSHIFT, DSHIFT)
            d1 = sat(q_mul(w2td2, leaky_d(z1, K)), -(1 << 14), (1 << 14) - 1)
            aW2 += q_mul(d2.reshape(NOUT, 1), h.reshape(1, NH)); ab2 += d2
            aW1 += q_mul(d1.reshape(NH, 1), xq.reshape(1, NIN)); ab1 += d1
        P['W2'] = sat(P['W2'] - ((aW2 * LR_MUL) >> lr_shift)); P['b2'] = sat(P['b2'] - ((ab2 * LR_MUL) >> lr_shift))
        P['W1'] = sat(P['W1'] - ((aW1 * LR_MUL) >> lr_shift)); P['b1'] = sat(P['b1'] - ((ab1 * LR_MUL) >> lr_shift))
        losses.append(int(sse)); accs.append(accuracy(P, tex, teY))
        if verbose and (ep % max(1, epochs // 20) == 0 or ep == epochs - 1):
            print(f"  ep{ep:3d} SSE={sse:9d} train={accuracy(P,trx,trY):.3f} test={accs[-1]:.3f}")
    return P, losses, accs


def baked_tiles(P):
    """The two INT8 weight tiles the board ICAP-bakes: L1 = quant(W1) [4x4],
    L2 = quant(W2) padded to [4x4] (rows 2,3 = 0)."""
    L1 = quant_int8(P['W1'], WSHIFT)
    L2 = np.zeros((4, 4), np.int64); L2[:NOUT, :NH] = quant_int8(P['W2'], WSHIFT)
    return L1.astype(int), L2.astype(int)


def _a2(name, a, ct="signed char"):
    rows = ",\n  ".join("{" + ",".join(f"{int(v):d}" for v in r) + "}" for r in a)
    return f"static const {ct} {name}[{a.shape[0]}][{a.shape[1]}] = {{\n  {rows}\n}};\n"
def _a1(name, a, ct="short"):
    return f"static const {ct} {name}[{len(a)}] = {{ " + ",".join(f"{int(v):d}" for v in a) + " };\n"


def dump_header(path, lr_shift=LR_SHIFT):
    trx, trY, tex, teY = load_dataset()
    P, _, accs = train(trx, trY, tex, teY, verbose=False, lr_shift=lr_shift)
    L1, L2 = baked_tiles(P)
    # golden per-digit classification (the board must reproduce these).
    cls = np.array([int(np.argmax(forward(P, tex[i])[3][:NOUT])) for i in range(NTEST)], np.int64)
    acc = float(np.mean(cls == teY))
    print(f"oracle 4-4-2 ({POOL}x{POOL}): test_acc {accs[-1]:.3f}; golden cls acc {acc:.3f}")
    with open(path, "w") as f:
        f.write("// AUTO-GENERATED by sim/oracle_m753.py — DO NOT EDIT.\n")
        f.write(f"// M7.5.3-lite golden: {NIN}-{NH}-{NOUT}, digits {CLASSES}, {POOL}x{POOL} pool, "
                f"seed={SEED}, lr_shift={lr_shift}, test_acc={acc:.3f}\n")
        f.write("#ifndef M753_VECTORS_H\n#define M753_VECTORS_H\n\n")
        for n, v in (("M7M_FRAC", FRAC), ("M7M_K", K), ("M7M_WSHIFT", WSHIFT),
                     ("M7M_XSHIFT", XSHIFT), ("M7M_XSHIFT_H", XSHIFT_H),
                     ("M7M_NIN", NIN), ("M7M_NH", NH), ("M7M_NOUT", NOUT), ("M7M_NTEST", NTEST)):
            f.write(f"#define {n:12s} {v}\n")
        f.write("\n// biases (Q8.8) — firmware does bias+leaky+requant; weights are in the LUT tile.\n")
        f.write(_a1("M753_B1", P['b1'])); f.write(_a1("M753_B2", P['b2']))
        f.write("\n// the two INT8 weight tiles the host ICAP-bakes (L1 pass1, L2 pass2 padded).\n")
        f.write(_a2("M753_L1_TILE", np.array(L1))); f.write(_a2("M753_L2_TILE", np.array(L2)))
        f.write("\n// test set: inputs INT8 (x_q88=v<<XSHIFT), labels, and golden classifications.\n")
        f.write(_a2("M753_TEST_X", tex.astype(np.int64))); f.write(_a1("M753_TEST_Y", teY, "unsigned char"))
        f.write(_a1("M753_GOLD_CLS", cls, "unsigned char"))
        f.write("\n#endif // M753_VECTORS_H\n")
    print(f"wrote {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--lr-shift', type=int, default=LR_SHIFT)
    ap.add_argument('--sweep-lr', action='store_true')
    ap.add_argument('--dump-header', metavar='PATH')
    args = ap.parse_args()
    if args.dump_header:
        dump_header(args.dump_header, lr_shift=args.lr_shift); return
    trx, trY, tex, teY = load_dataset()
    if args.sweep_lr:
        print(f"== LR sweep ({NIN}-{NH}-{NOUT}, digits {CLASSES}, {POOL}x{POOL} pool) ==")
        for ls in range(5, 12):
            _, lo, ac = train(trx, trY, tex, teY, verbose=False, lr_shift=ls)
            print(f"  lr_shift={ls:2d} final={ac[-1]:.3f} peak={max(ac):.3f} SSE {lo[0]}->{lo[-1]}")
        return
    print(f"== M7.5.3-lite oracle ({NIN}-{NH}-{NOUT}, digits {CLASSES}, {POOL}x{POOL} pool) ==")
    P, losses, accs = train(trx, trY, tex, teY, lr_shift=args.lr_shift)
    print(f"\n== test_acc {accs[0]:.3f} -> {accs[-1]:.3f} (peak {max(accs):.3f}) ==")
    L1, L2 = baked_tiles(P)
    print(f"L1 tile (bake pass 1) =\n{np.array(L1)}")
    print(f"L2 tile (bake pass 2, rows 2-3 pad) =\n{np.array(L2)}")


if __name__ == '__main__':
    main()
