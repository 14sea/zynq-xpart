// diag4.c — M7.2 flat-flow root-cause discriminator (2026-07-02).
// Context: flat non-DFX 3-roll control reproduced the exact {-5,-3,-8,-3} failure
// (docs/m7_2_dcpdiff.md) → fault is deterministic-with-firmware-size, flow-independent.
// DCP INIT of the 4x RAMB36(4Kx9) IMEM is byte-perfect vs the image, so the two
// remaining suspects are (a) IMEM data-port readout on silicon, (b) the array datapath.
// One build answers it:
//   r[0] = 24-bit sum of the first 0x2800 bytes of IMEM read as DATA (volatile loads
//          through a register-hidden pointer) — host computes the same sum from the
//          image; mismatch ⇒ IMEM readout corrupt (suspect (a) confirmed).
//   r[1] = raw RES0 of W·x with weights loaded FROM .rodata      (expect 14)
//   r[2] = raw RES0 of W·x with weights built from immediates    (expect 14)
//          r[1] wrong + r[2] right ⇒ (a); both wrong ⇒ (b).
//   r[3] = RES1|RES2<<8|RES3<<16 of the immediate-weight matmul  (expect 40,28,6 = 0x061C28)
//   r[4] = SGD-update check                                       (expect 999)
//   r[5] = INIT-forward y[0] pattern 0, as diag2 r[0]             (expect 19)
// Keeps diag2pad's PAD_RO so the binary stays in the failing size class.
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
#define TU_DW(i)  TU_REG(12 + (i))
#define TU_CMD    TU_REG(20)
#define TU_MW(i)  TU_REG(32 + (i))
#define TU_D2(i)  TU_REG(52 + (i))
#define TU_D1(i)  TU_REG(56 + (i))
#define TU_LOSS   TU_REG(60)
#define FENCE __asm__ volatile("fence" ::: "memory")
#define M7_BOARD
typedef int64_t i64;

// same inert padding as diag2pad — keeps the binary in the failing size class
__attribute__((used)) static const uint8_t PAD_RO[6030] = { 1,2,3,4,5,6,7,8,9 };
__attribute__((used,noinline)) static uint32_t pad_fn0(uint32_t x){ volatile uint32_t a=x; a^=0x5a5a5a5au; a+=0x12345678u; a^=(a<<3); a-=0x9e3779b9u; a^=(a>>7); return a; }
__attribute__((used,noinline)) static uint32_t pad_fn1(uint32_t x){ volatile uint32_t a=x; a+=0xdeadbeefu; a^=(a<<5); a-=0x7f4a7c15u; a^=(a>>11); a+=0x85ebca6bu; return a; }
__attribute__((used,noinline)) static uint32_t pad_fn2(uint32_t x){ volatile uint32_t a=x; a^=0xc2b2ae35u; a+=(a<<9); a^=0x27d4eb2fu; a-=(a>>6); a^=0x165667b1u; return a; }
static uint32_t pad_consume(void){ uint32_t s=PAD_RO[0]; for(int i=1;i<6030;i++) s+=PAD_RO[i]; return pad_fn0(s)^pad_fn1(s)^pad_fn2(s); }

// .rodata copy of the known test matmul (forced real loads via hidden pointer)
static const signed char WRO[4][4] = {{1,1,1,1},{1,2,3,4},{2,2,2,2},{1,0,1,0}};
static const signed char XRO[4]    = {2,3,4,5};

static void hw_flush(void) {
    for (int r=0;r<4;r++){TPU_W_ADDR=(uint32_t)(r<<2);TPU_W_DATA4=0;}
    TPU_CTRL=0x10; TPU_X_IN=0; FENCE; TPU_CTRL=0x01; while(!(TPU_STATUS&1)){} TPU_CTRL=0x10;
}
void array_macc(const signed char Wi[4][4], const signed char xi[4], int32_t acc[4]) {
    hw_flush();
    for (int r=0;r<4;r++){TPU_W_ADDR=(uint32_t)(r<<2);
        TPU_W_DATA4=((uint32_t)(uint8_t)Wi[r][3]<<24)|((uint32_t)(uint8_t)Wi[r][2]<<16)|
                    ((uint32_t)(uint8_t)Wi[r][1]<<8)|(uint32_t)(uint8_t)Wi[r][0];}
    TPU_CTRL=0x10;
    TPU_X_IN=((uint32_t)(uint8_t)xi[3]<<24)|((uint32_t)(uint8_t)xi[2]<<16)|
             ((uint32_t)(uint8_t)xi[1]<<8)|(uint32_t)(uint8_t)xi[0];
    FENCE; TPU_CTRL=0x01; while(!(TPU_STATUS&1)){}
    for(int i=0;i<4;i++) acc[i]=(int32_t)TPU_RES(i);
}
// train_unit accessors (identical to main.c)
void tu_master_load(const i64 W1[4][4], const i64 b1[4], const i64 W2[4][4], const i64 b2[4]) {
    for (int i=0;i<4;i++) for(int j=0;j<2;j++) TU_MW(i*2+j)=(uint32_t)(int32_t)W1[i][j];
    for (int i=0;i<4;i++) TU_MW(8+i)=(uint32_t)(int32_t)b1[i];
    for (int j=0;j<4;j++) TU_MW(12+j)=(uint32_t)(int32_t)W2[0][j];
    TU_MW(16)=(uint32_t)(int32_t)b2[0];
}
void tu_master_read(i64 W1[4][4], i64 b1[4], i64 W2[4][4], i64 b2[4]) {
    for (int i=0;i<4;i++){ for(int j=0;j<2;j++) W1[i][j]=(i64)(int32_t)TU_MW(i*2+j);
        W1[i][2]=0; W1[i][3]=0; b1[i]=(i64)(int32_t)TU_MW(8+i); }
    for (int j=0;j<4;j++) W2[0][j]=(i64)(int32_t)TU_MW(12+j);
    for (int i=1;i<4;i++) for(int j=0;j<4;j++) W2[i][j]=0;
    b2[0]=(i64)(int32_t)TU_MW(16); b2[1]=0;b2[2]=0;b2[3]=0;
}
void tu_clr_loss(void){ FENCE; TU_CMD=0x10; }
i64  tu_get_loss(void){ return (i64)(int32_t)TU_LOSS; }
void tu_loss_d2(const i64 y[4], const i64 z2[4], const i64 t[4], i64 d2[4]) {
    for(int i=0;i<4;i++){TU_INA(i)=(uint32_t)(int32_t)y[i];TU_Z(i)=(uint32_t)(int32_t)z2[i];TU_T(i)=(uint32_t)(int32_t)t[i];}
    FENCE; TU_CMD=0x01; for(int i=0;i<4;i++) d2[i]=(i64)(int32_t)TU_D2(i);
}
void tu_d1(const i64 w2td2[4], const i64 z1[4], i64 d1[4]) {
    for(int i=0;i<4;i++){TU_INA(i)=(uint32_t)(int32_t)w2td2[i];TU_Z(i)=(uint32_t)(int32_t)z1[i];}
    FENCE; TU_CMD=0x02; for(int i=0;i<4;i++) d1[i]=(i64)(int32_t)TU_D1(i);
}
void tu_upd_l2(const i64 dw2[4]){ for(int j=0;j<4;j++) TU_DW(j)=(uint32_t)(int32_t)dw2[j]; FENCE; TU_CMD=0x04; }
void tu_upd_l1(const i64 dw1[8]){ for(int n=0;n<8;n++) TU_DW(n)=(uint32_t)(int32_t)dw1[n]; FENCE; TU_CMD=0x08; }
#include "m7_kernel_hw.h"

int main(void) {
    neorv32_rte_setup();
    neorv32_uart0_setup(BAUD_RATE,0);

    uint32_t r[8];
    i64 W1[4][4],W2[4][4],b1[4],b2[4];
    int32_t a[4];

    // r[0]: IMEM-as-data checksum — sum of the first 0x2800 bytes read as words.
    // Pointer hidden from the optimizer so these are real data-bus loads of IMEM.
    { volatile const uint32_t *p = (volatile const uint32_t *)4;  // skip word 0 (NULL-deref UB)
      __asm__ volatile("" : "+r"(p));
      uint32_t s = 0;
      for (uint32_t i = 1; i < 0x2800/4; i++) { s += *p; p++; }
      r[0] = s; }

    // r[1]: array W·x with weights/x loaded FROM .rodata (hidden pointers → real loads)
    { const signed char (*w)[4] = WRO; const signed char *x = XRO;
      __asm__ volatile("" : "+r"(w), "+r"(x));
      array_macc(w, x, a); r[1] = (uint32_t)a[0]; }        // expect 14

    // r[2]/r[3]: same matmul with weights materialized from immediates on the stack
    { signed char Wi[4][4]; signed char xi[4];
      volatile signed char *q = &Wi[0][0];
      q[0]=1;q[1]=1;q[2]=1;q[3]=1; q[4]=1;q[5]=2;q[6]=3;q[7]=4;
      q[8]=2;q[9]=2;q[10]=2;q[11]=2; q[12]=1;q[13]=0;q[14]=1;q[15]=0;
      volatile signed char *qx = xi; qx[0]=2;qx[1]=3;qx[2]=4;qx[3]=5;
      array_macc(Wi, xi, a);
      r[2] = (uint32_t)a[0];                               // expect 14
      r[3] = ((uint32_t)a[3]<<16)|((uint32_t)a[2]<<8)|(uint32_t)a[1]; } // expect 0x061C28

    // r[4]: SGD-update check (1000 - 16>>4 = 999)
    TU_MW(12)=1000; TU_DW(0)=16; FENCE; TU_CMD=0x04; FENCE; r[4]=TU_MW(12);

    // r[5]: INIT-forward y[0] pattern 0 (diag2 r[0], expect 19)
    m7_init(W1,b1,W2,b2);
    { i64 z1[4],h[4],z2[4],y[4];
      m7_forward(W1,b1,W2,b2,M7_XP[0],z1,h,z2,y); r[5]=(uint32_t)(int32_t)y[0]; }

    r[6]=pad_consume();   // keep PAD_RO + pad_fn* linked; runs after everything
    r[7]=r[6];
    neorv32_uart0_printf("diag4 done\n");
    while(1){ for(int i=0;i<6;i++){ MBOX=((uint32_t)(0xB0+i)<<24)|((uint32_t)r[i]&0x00FFFFFF);
        for(volatile uint32_t d=0;d<15000000u;d++){} } }
    return 0;
}
