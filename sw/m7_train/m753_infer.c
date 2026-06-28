// m753_infer.c — M7.5.3-lite: whole 4-4-2 net classified on ONE LUT-KCM tile,
// the two layers TIME-FOLDED via ICAP weight bakes. PS/NEORV32 never reset.
//
// The spatial whole-net LUT-KCM doesn't fit XC7Z010 (one 4x4 tile = 80% of the RP
// LUTs). So fold: L1 W1[4][4] and L2 W2[2][4] each = one tile. The board runs the
// forward in TWO array passes over the SAME LUT-KCM tile, the host ICAP-baking the
// tile to the trained W1 (pass 1) then W2 (pass 2). Every weight of the 2-layer
// classifier is computed in hardwired, ICAP-editable LUT logic. Batched over the
// whole test set: only TWO ICAP bakes total (L1, L2), two handshake windows.
//
// Handshake (no host->board channel — use the FABRIC as the signal, closed-loop):
// the firmware probes the tile with a fixed x={1,1,1,1} and WAITS until the raw RES
// equals that layer's expected row-sums (L1 -> {-5,71,-7,-4}, L2 -> {30,18,0,0};
// baseline -> {4,10,8,2}, all distinct), i.e. until the host's ICAP bake has landed.
// The host in turn waits for the board's A_DONE marker before baking L2. No fragile
// fixed-time windows: board waits for each bake, host waits for each compute.
//
// Inference math = m7_mnist_kernel's per-layer path (raw INT8 MAC from the tile ->
// requant -> +bias -> leaky -> quant), here read from the BAKED tile (no weight load).
//   L1: res = W1tile @ x_i8;   down=8-WSHIFT-XSHIFT=4;   h=leaky(req+b1); hi8=q8(h,XSHIFT_H)
//   L2: res = W2tile @ hi8;     down=8-WSHIFT-XSHIFT_H=3; y=leaky(req+b2);  class=argmax(y0,y1)
//
// Mailbox protocol (PS polls 0x41200000):
//   0x7Axxxxxx / 0x7Cxxxxxx : boot / settle heartbeats
//   0x5A1Axxxx / 0x5A2Axxxx : waiting-for-L1-bake / waiting-for-L2-bake heartbeat;
//                             low 16 bits = incrementing tick (proves the loop is live)
//   0xAD0xxxxx              : A_DONE — layer-1 finished (low bytes = hi8[0][0..2] spot-check)
//   0xDEAD00xx              : a bake never landed (probe timeout)
//   0xB1.. / 0xB2..         : classifications bitmap, digits 0..23 / 24..39 (looped)
//
// Build: make APP_SRC=m753_infer.c NEORV32_HOME=../../rtl_src/neorv32_tpu/neorv32 \
//        RISCV_PREFIX=riscv64-unknown-elf- USER_FLAGS+="-specs=picolibc.specs" clean install

#include <neorv32.h>
#include <stdint.h>

#define TPU_BASE  0xF0000000U
#define TPU_CTRL   (*(volatile uint32_t *)(TPU_BASE + 0x00))
#define TPU_STATUS (*(volatile uint32_t *)(TPU_BASE + 0x04))
#define TPU_X_IN   (*(volatile uint32_t *)(TPU_BASE + 0x10))
#define TPU_RES(r) (*(volatile uint32_t *)(TPU_BASE + 0x20 + (r)*4))
#define MBOX       (*(volatile uint32_t *)0xF1000000U)

#include "m753_vectors.h"

// expected probe (x={1,1,1,1}) raw RES per baked layer = the tile's row sums.
static const int32_t PROBE_L1[4] = {-5, 71, -7, -4};
static const int32_t PROBE_L2[4] = {30, 18, 0, 0};
#define HOLD       1500000u

static int leaky(int z) { return z >= 0 ? z : (z >> M7M_K); }
static int sat16(int x) { return x < -32768 ? -32768 : (x > 32767 ? 32767 : x); }
static int q8(int v, int s) { int r = (v + (1 << (s - 1))) >> s; return r < -128 ? -128 : (r > 127 ? 127 : r); }

// one LUT-KCM tile pass: res[0..3] = baked_W @ x_i8 (raw INT8 MAC; weights are the LUTs).
static void tile_mac(const signed char x[4], int32_t res[4]) {
    TPU_CTRL = 0x10;             // clear accumulators
    TPU_X_IN = ((uint32_t)(uint8_t)x[3] << 24) | ((uint32_t)(uint8_t)x[2] << 16) |
               ((uint32_t)(uint8_t)x[1] <<  8) |  (uint32_t)(uint8_t)x[0];
    __asm__ volatile("fence" ::: "memory");
    TPU_CTRL = 0x01;             // run
    while (!(TPU_STATUS & 1)) { }
    for (int r = 0; r < 4; r++) res[r] = (int32_t)TPU_RES(r);
}

// closed-loop wait: probe the tile with x={1,1,1,1} until RES == this layer's row
// sums (the host's ICAP bake has landed). Waits INDEFINITELY — the host controls
// when to bake, so there must be no timeout race. The heartbeat carries an
// INCREMENTING counter in its low 16 bits (hb | tick), so two successive md reads
// prove the probe loop is LIVE (not silently hung) even before any bake lands.
static void wait_baked(const int32_t want[4], uint32_t hb) {
    const signed char probe[4] = {1, 1, 1, 1};
    int32_t res[4];
    uint32_t it = 0, tick = 0;
    for (;;) {
        tile_mac(probe, res);
        if (res[0] == want[0] && res[1] == want[1] && res[2] == want[2] && res[3] == want[3])
            return;
        if ((++it & 0x1FFFF) == 0) MBOX = hb | (++tick & 0xFFFF);
    }
}

int main(void) {
    MBOX = 0x7A000000u;
    neorv32_rte_setup();
    for (uint32_t kk = 0; kk < 20; kk++) { MBOX = 0x7C000000u | kk;
        for (volatile uint32_t d = 0; d < 500000u; d++) { } }   // post-config settle

    static signed char hi8[M7M_NTEST][4];

    // ── LAYER 1: wait until host has ICAP-baked W1, then compute all hidden acts ──
    wait_baked(PROBE_L1, 0x5A1A0000u);
    for (int d = 0; d < M7M_NTEST; d++) {
        int32_t res[4];
        tile_mac(M753_TEST_X[d], res);
        for (int r = 0; r < M7M_NH; r++) {
            int hp = (res[r] + (1 << 3)) >> 4;          // down = 8-WSHIFT-XSHIFT = 4
            int z  = sat16(hp + M753_B1[r]);
            hi8[d][r] = (signed char)q8(leaky(z), M7M_XSHIFT_H);
        }
    }
    // A_DONE: layer 1 finished (host may now bake W2). low bytes = hi8[0][0..2] spot-check.
    for (int k = 0; k < 8; k++) {                        // publish a few times so host catches it
        MBOX = 0xAD000000u | ((uint32_t)(uint8_t)hi8[0][0] << 16) |
               ((uint32_t)(uint8_t)hi8[0][1] << 8) | (uint32_t)(uint8_t)hi8[0][2];
        for (volatile uint32_t d = 0; d < HOLD; d++) { }
    }

    // ── LAYER 2: wait until host has ICAP-baked W2, then classify ──
    wait_baked(PROBE_L2, 0x5A2A0000u);
    uint64_t bitmap = 0;
    for (int d = 0; d < M7M_NTEST; d++) {
        int32_t res[4];
        tile_mac(hi8[d], res);
        int y0 = leaky(sat16(((res[0] + (1 << 2)) >> 3) + M753_B2[0]));  // down = 3
        int y1 = leaky(sat16(((res[1] + (1 << 2)) >> 3) + M753_B2[1]));
        if (y1 > y0) bitmap |= ((uint64_t)1 << d);
    }

    // publish the 40-bit classification bitmap (looped so the poller catches both).
    uint32_t lo = (uint32_t)(bitmap & 0xFFFFFF);
    uint32_t hi = (uint32_t)((bitmap >> 24) & 0xFFFF);
    uint32_t led = 0xF;
    while (1) {
        MBOX = 0xB1000000u | lo;
        for (volatile uint32_t d = 0; d < HOLD; d++) { }
        MBOX = 0xB2000000u | hi;
        neorv32_gpio_port_set(led); led ^= 0xF;
        for (volatile uint32_t d = 0; d < HOLD; d++) { }
    }
    return 0;
}
