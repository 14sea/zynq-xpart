// main.c — NEORV32 bare-metal firmware for the M6 full-version RM (4x4 TPU + VPU).
//
// Drives the rm_tpuvpu Reconfigurable Partition over the XBUS at 0xF0000000:
// loads weights + inputs, programs the VPU (bias -> Leaky ReLU -> requant), runs
// one matmul, and reads back POST0-3 (INT8 post-activation) — the work the RISC-V
// used to do in software now happens in fabric. The packed POST result is
// published to the mailbox at 0xF1000000 (PS reads it over AXI-GPIO at 0x41200000)
// so a live DFX swap to this RM is observable from the PS with no CPU reset.
//
// VPU register map (within the RP window; see rtl/dfx/tpu_rp_rm_tpuvpu.v):
//   0x30 VPU_CTRL  [0]=vpu_en [1]=act(1=Leaky ReLU) [2]=bias_en
//   0x34 VPU_BIAS  per-lane INT32 bias; lane = W_ADDR[1:0] (snooped)
//   0x38 VPU_SCALE INT16 requant multiplier
//   0x3C VPU_SHIFT requant arithmetic right shift
//   0x40..0x4C POST0-3 (R) INT8 post-activation results
//   0x50 VPU_ALPHA Leaky-ReLU negative-slope shift k
//
// Reference vectors (match sim/tb_rm_tpuvpu.v T1, bit-exact):
//   W = [[1,1,1,1],[1,2,3,4],[2,2,2,2],[1,0,1,0]],  X = [2,3,4,5]
//     -> RES = [14, 40, 28, 6]
//   bias=[8,0,-10,5]  scale=181  shift=7  alpha=4  (leaky+bias enabled)
//     -> POST = [31, 57, 25, 16]
//   mailbox = {POST3,POST2,POST1,POST0} bytes = 0x10_19_39_1F = 0x1019391F
// On board, a live swap from a non-VPU RM (e.g. rm2 -> 0x00BB00CC) to rm_tpuvpu
// flips the mailbox to 0x1019391F — the headline M6.3 observable.

#include <neorv32.h>

#define BAUD_RATE 115200

#define TPU_BASE    0xF0000000U

#define TPU_CTRL    (*(volatile uint32_t *)(TPU_BASE + 0x00))
#define TPU_STATUS  (*(volatile uint32_t *)(TPU_BASE + 0x04))
#define TPU_W_ADDR  (*(volatile uint32_t *)(TPU_BASE + 0x08))
#define TPU_W_DATA  (*(volatile uint32_t *)(TPU_BASE + 0x0C))
#define TPU_X_IN    (*(volatile uint32_t *)(TPU_BASE + 0x10))
#define TPU_W_DATA4 (*(volatile uint32_t *)(TPU_BASE + 0x14))
#define TPU_RES(r)  (*(volatile uint32_t *)(TPU_BASE + 0x20 + (r)*4))

#define VPU_CTRL    (*(volatile uint32_t *)(TPU_BASE + 0x30))
#define VPU_BIAS    (*(volatile uint32_t *)(TPU_BASE + 0x34))
#define VPU_SCALE   (*(volatile uint32_t *)(TPU_BASE + 0x38))
#define VPU_SHIFT   (*(volatile uint32_t *)(TPU_BASE + 0x3C))
#define VPU_POST(r) (*(volatile uint32_t *)(TPU_BASE + 0x40 + (r)*4))
#define VPU_ALPHA   (*(volatile uint32_t *)(TPU_BASE + 0x50))

// mailbox the PS reads over AXI (neorv32_soc 0xF1000000 -> mbox_o -> 0x41200000)
#define MBOX        (*(volatile uint32_t *)0xF1000000U)

// VPU_CTRL bits
#define VPU_EN      0x1
#define VPU_ACT     0x2   // 1 = Leaky ReLU, 0 = passthrough
#define VPU_BIAS_EN 0x4

static void load_weight_row(int row, int8_t w0, int8_t w1, int8_t w2, int8_t w3) {
    TPU_W_ADDR  = (uint32_t)(row << 2);   // row, col ignored for W_DATA4
    TPU_W_DATA4 = ((uint32_t)(uint8_t)w3 << 24) | ((uint32_t)(uint8_t)w2 << 16) |
                  ((uint32_t)(uint8_t)w1 <<  8) |  (uint32_t)(uint8_t)w0;
}

// Reference weight matrix W. Re-loaded every pass: a live DFX loadbp does a
// RESET_AFTER_RECONFIG of the RP, which wipes the PE weight registers, so the
// loop MUST reload them or the post-swap matmul runs on zeroed weights.
static void load_weights(void) {
    load_weight_row(0, 1, 1, 1, 1);
    load_weight_row(1, 1, 2, 3, 4);
    load_weight_row(2, 2, 2, 2, 2);
    load_weight_row(3, 1, 0, 1, 0);
}

static void set_bias(int lane, int32_t bias) {
    TPU_W_ADDR = (uint32_t)lane;          // wrapper snoops W_ADDR[1:0] = bias lane
    VPU_BIAS   = (uint32_t)bias;
}

// Program the VPU, load X, run one matmul+VPU pass, return packed POST0-3.
static uint32_t run_vpu(int8_t x0, int8_t x1, int8_t x2, int8_t x3,
                        int32_t b0, int32_t b1, int32_t b2, int32_t b3,
                        uint16_t scale, uint8_t shift, uint8_t alpha) {
    // requant params first
    VPU_SCALE = scale;
    VPU_SHIFT = shift;
    VPU_ALPHA = alpha;
    set_bias(0, b0); set_bias(1, b1); set_bias(2, b2); set_bias(3, b3);
    VPU_CTRL  = VPU_EN | VPU_ACT | VPU_BIAS_EN;

    TPU_CTRL = 0x10;   // clear accumulators (and done)
    TPU_X_IN = ((uint32_t)(uint8_t)x3 << 24) | ((uint32_t)(uint8_t)x2 << 16) |
               ((uint32_t)(uint8_t)x1 <<  8) |  (uint32_t)(uint8_t)x0;
    TPU_CTRL = 0x01;   // start: matmul then VPU; STATUS.done covers VPU drain
    while (!(TPU_STATUS & 1)) { }

    return (((uint32_t)VPU_POST(3) & 0xFF) << 24) |
           (((uint32_t)VPU_POST(2) & 0xFF) << 16) |
           (((uint32_t)VPU_POST(1) & 0xFF) <<  8) |
            ((uint32_t)VPU_POST(0) & 0xFF);
}

int main(void) {
    neorv32_rte_setup();
    neorv32_uart0_setup(BAUD_RATE, 0);

    neorv32_uart0_printf("\n=====================================\n");
    neorv32_uart0_printf("  NEORV32 RoT  ->  4x4 TPU + VPU (M6) \n");
    neorv32_uart0_printf("  RoT element alive, measured OK       \n");
    neorv32_uart0_printf("=====================================\n");

    // One pass for the UART self-check + report RES and POST.
    load_weights();
    uint32_t packed = run_vpu(2, 3, 4, 5,  8, 0, -10, 5,  181, 7, 4);
    neorv32_uart0_printf("RES = %d %d %d %d\n",
        (int32_t)TPU_RES(0), (int32_t)TPU_RES(1), (int32_t)TPU_RES(2), (int32_t)TPU_RES(3));
    neorv32_uart0_printf("POST= %d %d %d %d  (expect 31 57 25 16)\n",
        (int8_t)VPU_POST(0), (int8_t)VPU_POST(1), (int8_t)VPU_POST(2), (int8_t)VPU_POST(3));
    neorv32_uart0_printf("mailbox = 0x%x  (expect 0x1019391F)\n", packed);

    // Publish CONTINUOUSLY so a live DFX swap to this RM is visible to the PS
    // with no CPU reset (mailbox flips e.g. rm2 0x00BB00CC -> 0x1019391F).
    uint32_t led = 0xF;
    while (1) {
        load_weights();   // reload every pass — survives a live DFX RP reset
        MBOX = run_vpu(2, 3, 4, 5,  8, 0, -10, 5,  181, 7, 4);
        neorv32_gpio_port_set(led);
        led ^= 0xF;
        for (volatile uint32_t d = 0; d < 200000; d++) { }
    }
    return 0;
}
