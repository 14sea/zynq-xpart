// DFX Reconfigurable Module: TRAINING accelerator = 4x4 INT8 TPU array + train_unit (M7.2).
//
// Same `tpu_rp` interface as the other RMs (rm_tpuvpu/rm_lut/…) — drops into the
// existing partition def with zero static-side change (neorv32_soc_dfx).  Wraps the
// real wb_tpu_accel (the 4x4 INT8 systolic array: forward W·x AND backward Wᵀ·δ via
// transpose-load, exactly as M7.1) and the new train_unit.v (the tiny-tpu "trio":
// MSE loss + dL/dy, leaky' + δ, and the saturating SGD master-weight update, with
// the 2-4-1 XOR net's master weights resident in train_unit's register file).
//
// Per the M7.2 resource plan this RM has NO inference VPU (training uses the raw
// INT32 accumulators RES0-3 + a SW requant), so peak RP resource = max(train,infer),
// not their sum — train↔infer are DFX-time-multiplexed (rm_train ↔ rm_tpuvpu).
//
// Register map (byte offsets within the RP window):
//   --- array / wb_tpu_accel (forwarded unchanged; the two matmuls) ---
//   0x00 CTRL  0x04 STATUS  0x08 W_ADDR  0x0C W_DATA  0x10 X_IN  0x14 W_DATA4
//   0x20-0x2C RES0-3  (INT32 raw accumulators — the SW forward requant reads these)
//   --- train_unit window (claimed by this wrapper, NOT forwarded) ---
//   base 0x800; train_unit word w  ->  byte 0x800 + w*4.  Notable words:
//     0x800-0x80C INA0-3 (y / w2td2)     0x810-0x81C Z0-3 (z2 / z1)
//     0x820-0x82C T0-3 (target)          0x830-0x84C DW0-7 (SW outer-product gradients)
//     0x850 CMD [0]loss_d2 [1]d1 [2]upd_l2 [3]upd_l1 [4]clr_loss
//     0x880-0x89C W1m0-7   0x8A0-0x8AC b1m0-3   0x8B0-0x8BC W2m0-3   0x8C0 b2m   (master R/W)
//     0x8D0-0x8DC D2_0-3   0x8E0-0x8EC D1_0-3   0x8F0 LOSS_LO   0x8F4 LOSS_HI
//
// Flow (firmware sequences; this RM holds the master + does the element-wise trio):
//   per sample — load array weights (INT8 view of master) + X, pulse CTRL[0] for W·x,
//   read RES0-3, SW-requant+bias+leaky -> z1,h,z2,y; write y/target/z2 + CMD[0] (loss+d2);
//   transpose-load + Wᵀ·δ on the array, SW-requant -> w2td2; write w2td2/z1 + CMD[1] (d1);
//   SW outer products dW2,dW1 -> DW bank; CMD[2]/CMD[3] apply the SGD update to the master.
//   leaky-derivative gating, the loss accumulator, and the saturating master update all
//   happen in hardware (train_unit), bit-exact to sim/oracle_train.py.

module tpu_rp (
    input         clk,
    input         rst_n,
    input  [31:0] xbus_adr,
    input  [31:0] xbus_dat_w,
    input  [3:0]  xbus_sel,
    input         xbus_we,
    input         xbus_stb,
    input         xbus_cyc,
    output [31:0] xbus_dat_r,
    output        xbus_ack,
    output        xbus_err,
    output [3:0]  dbg_leds
);
    // Fixed-point config mirrors sim/oracle_train.py / m7_vectors.h (golden XOR run).
    localparam [5:0] TU_LR = 6'd4;   // LR_SHIFT (power-of-two learning rate)
    localparam [5:0] TU_K  = 6'd2;   // leaky-ReLU negative-slope shift

    wire [11:0] off    = xbus_adr[11:0];
    wire        claim  = (off >= 12'h800) && (off <= 12'h8F4);
    wire        wr_cyc = xbus_cyc && xbus_stb;

    // ── wb_tpu_accel : the 4x4 INT8 array (forwarded cycles only) ────────────
    wire [31:0] acc_dat_r;
    wire        acc_ack;
    wire [3:0]  acc_leds;

    wb_tpu_accel u_accel (
        .clk        (clk),
        .rst_n      (rst_n),
        .xbus_adr   (xbus_adr),
        .xbus_dat_w (xbus_dat_w),
        .xbus_sel   (xbus_sel),
        .xbus_we    (xbus_we),
        .xbus_stb   (xbus_stb && !claim),   // train_unit window not forwarded
        .xbus_cyc   (xbus_cyc && !claim),
        .xbus_dat_r (acc_dat_r),
        .xbus_ack   (acc_ack),
        .xbus_err   (),
        .dbg_leds   (acc_leds),
        .res0_o     (),                      // raw RES read back via 0x20-0x2C (SW requant)
        .res1_o     (),
        .res2_o     (),
        .res3_o     (),
        .mm_done_o  ()
    );

    // ── claimed-window one-shot handshake (1-cycle ack, single-pulse we) ──────
    // CMD writes MUST latch exactly once (a held `we` would re-run the op, e.g.
    // double-accumulate LOSS), so `tu_we` pulses only on the transaction's start
    // cycle; `cpend` then asserts for one cycle as the local ack.
    reg  cpend;
    wire start = wr_cyc && claim && !cpend;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cpend <= 1'b0;
        else        cpend <= start;          // high for exactly one cycle after start

    wire        tu_we   = start && xbus_we && (xbus_sel != 4'b0000);
    // word index within the claimed window: (off - 0x800) >> 2.  In 0x800..0x8F4
    // the 0x800 base is bit 11 only and bits[10:8] are 0, so this is just off[8:2].
    wire [6:0]  tu_addr = off[8:2];
    wire signed [31:0] tu_rdata;

    train_unit u_tu (
        .clk   (clk),
        .rst_n (rst_n),
        .lr    (TU_LR),
        .k     (TU_K),
        .we    (tu_we),
        .addr  (tu_addr),
        .wdata (xbus_dat_w),
        .rdata (tu_rdata)
    );

    // ── bus response mux ──────────────────────────────────────────────────────
    assign xbus_ack   = claim ? cpend     : acc_ack;
    assign xbus_dat_r = claim ? tu_rdata  : acc_dat_r;
    assign xbus_err   = 1'b0;
    assign dbg_leds   = acc_leds;

endmodule
