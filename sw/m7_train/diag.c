// diag.c — M7.2 on-board train_unit DIAGNOSTIC (not training). Probes the train_unit
// XBUS path directly and publishes each result over the PS mailbox (0x41200000),
// cycling with a tag in the high byte so the host can sample each. Used to root-cause
// the "board reads ~0 loss" symptom that neither the standalone nor the wrapper sim
// reproduces. Build: make APP_SRC=diag.c ... clean install ; then rebuild the static.
#include <neorv32.h>
#include <stdint.h>

#define BAUD_RATE 115200
#define TPU_BASE  0xF0000000U
#define TPU_CTRL   (*(volatile uint32_t *)(TPU_BASE + 0x00))
#define TPU_STATUS (*(volatile uint32_t *)(TPU_BASE + 0x04))
#define TPU_W_ADDR (*(volatile uint32_t *)(TPU_BASE + 0x08))
#define TPU_W_DATA4 (*(volatile uint32_t *)(TPU_BASE + 0x14))
#define TPU_X_IN   (*(volatile uint32_t *)(TPU_BASE + 0x10))
#define TPU_RES(r) (*(volatile uint32_t *)(TPU_BASE + 0x20 + (r)*4))
#define MBOX       (*(volatile uint32_t *)0xF1000000U)

#define TU_BASE   (TPU_BASE + 0x800U)
#define TU_REG(w) (*(volatile uint32_t *)(TU_BASE + (w)*4))
#define TU_INA(i) TU_REG(0 + (i))
#define TU_Z(i)   TU_REG(4 + (i))
#define TU_T(i)   TU_REG(8 + (i))
#define TU_CMD    TU_REG(20)
#define TU_MW(i)  TU_REG(32 + (i))
#define TU_D2(i)  TU_REG(52 + (i))
#define TU_LOSS   TU_REG(60)

#define FENCE __asm__ volatile("fence" ::: "memory")

static void array_macc(const signed char Wi[4][4], const signed char xi[4], int32_t acc[4]) {
    for (int r = 0; r < 4; r++) { TPU_W_ADDR = (uint32_t)(r << 2);
        TPU_W_DATA4 = ((uint32_t)(uint8_t)Wi[r][3] << 24) | ((uint32_t)(uint8_t)Wi[r][2] << 16) |
                      ((uint32_t)(uint8_t)Wi[r][1] <<  8) |  (uint32_t)(uint8_t)Wi[r][0]; }
    TPU_CTRL = 0x10;
    TPU_X_IN = ((uint32_t)(uint8_t)xi[3] << 24) | ((uint32_t)(uint8_t)xi[2] << 16) |
               ((uint32_t)(uint8_t)xi[1] <<  8) |  (uint32_t)(uint8_t)xi[0];
    FENCE; TPU_CTRL = 0x01;
    while (!(TPU_STATUS & 1)) { }
    for (int i = 0; i < 4; i++) acc[i] = (int32_t)TPU_RES(i);
}

int main(void) {
    neorv32_rte_setup();
    neorv32_uart0_setup(BAUD_RATE, 0);

    uint32_t r[8];

    // T1: raw train_unit master-register write/read-back (word 32, readable).
    TU_MW(0) = 0x00001234; FENCE; r[0] = TU_MW(0);            // expect 0x00001234
    // T2: a second register, negative value (word 36).
    TU_MW(4) = 0xFFFFFFEE; FENCE; r[1] = TU_MW(4);            // expect 0xFFFFFFEE

    // T3: loss_d2 with known operands: y0=256, z2_0=256(>=0), t=0 -> LOSS=256, D2_0=256.
    TU_CMD = 0x10; FENCE;                                     // clr_loss
    for (int i = 0; i < 4; i++) { TU_INA(i) = (i==0)?256:0;
                                  TU_Z(i)   = (i==0)?256:0;
                                  TU_T(i)   = 0; }
    FENCE; TU_CMD = 0x01; FENCE;
    r[2] = TU_LOSS;                                           // expect 256
    r[3] = TU_D2(0);                                          // expect 256

    // T4: array self-check (forward path). expect RES0 = 14.
    {
        const signed char W[4][4] = {{1,1,1,1},{1,2,3,4},{2,2,2,2},{1,0,1,0}};
        const signed char X[4] = {2,3,4,5};
        int32_t acc[4]; array_macc(W, X, acc); r[4] = (uint32_t)acc[0];   // expect 14
    }

    // T5: read a train_unit reg that was never written after a fresh clr, to see if
    // reads return a stable known value — read LOSS again (should still be 256).
    r[5] = TU_LOSS;

    neorv32_uart0_printf("diag done\n");

    // publish forever: tag (0xA1..0xA6) in bits[31:24], value in [23:0], held ~2.5 s.
    while (1) {
        for (int i = 0; i < 6; i++) {
            MBOX = ((uint32_t)(0xA1 + i) << 24) | (r[i] & 0x00FFFFFF);
            for (volatile uint32_t d = 0; d < 15000000u; d++) { }
        }
    }
    return 0;
}
