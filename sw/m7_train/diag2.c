// diag2.c — M7.2 comprehensive diagnostic, one build answers everything:
//   r[0..3] = isolated INIT-forward y[0] for the 4 XOR patterns (expect 19,2,10,-1)
//   r[4]    = SGD-update check: W2m[0]=1000, DW0=16, upd_l2 -> 999
//   r[5]    = a full real epoch-0 loss via m7_epoch_hw (expect oracle 469)
// Reported over the mailbox, tags 0xB0..0xB5. Discriminates array/forward bug vs
// update/sequence bug vs all-correct.
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

    // r[0..3]: isolated INIT-forward y[0] (no training, mirror=init)
    m7_init(W1,b1,W2,b2);
    for (int s=0;s<4;s++){ i64 z1[4],h[4],z2[4],y[4];
        m7_forward(W1,b1,W2,b2,M7_XP[s],z1,h,z2,y); r[s]=(uint32_t)(int32_t)y[0]; }

    // r[4]: SGD-update check (1000 - 16>>4 = 999)
    TU_MW(12)=1000; TU_DW(0)=16; FENCE; TU_CMD=0x04; FENCE; r[4]=TU_MW(12);

    // r[5]: a real full epoch-0 loss (forward+loss+d1+update in HW) — expect 469
    m7_init_hw(W1,b1,W2,b2);
    // brief settle (mirror M7.1 finding) before the SGD step
    { const signed char Ww[4][4]={{1,1,1,1},{1,2,3,4},{2,2,2,2},{1,0,1,0}}; const signed char Xw[4]={2,3,4,5};
      int32_t a[4]; for(int w=0;w<16;w++) array_macc(Ww,Xw,a);
      for(volatile uint32_t d=0;d<30000000u;d++){} }
    r[5]=(uint32_t)(int32_t)m7_epoch_hw(0,W1,b1,W2,b2);

    neorv32_uart0_printf("diag2 done\n");
    while(1){ for(int i=0;i<6;i++){ MBOX=((uint32_t)(0xB0+i)<<24)|((uint32_t)r[i]&0x00FFFFFF);
        for(volatile uint32_t d=0;d<15000000u;d++){} } }
    return 0;
}
