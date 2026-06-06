// DFX Reconfigurable Module #1 (RM1): the real 4x4 INT8 TPU.
//
// `tpu_rp` is the reconfigurable-partition cell instantiated by the static
// design (neorv32_soc_dfx). This implementation wraps the real wb_tpu_accel,
// so the firmware's matmul produces RES0=30, RES1=70 -> PS mailbox 0x001E0046.
// (RM2, tpu_rp_rm2_alt.v, is a different implementation of the same module.)
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
    wb_tpu_accel u_tpu (
        .clk        (clk),
        .rst_n      (rst_n),
        .xbus_adr   (xbus_adr),
        .xbus_dat_w (xbus_dat_w),
        .xbus_sel   (xbus_sel),
        .xbus_we    (xbus_we),
        .xbus_stb   (xbus_stb),
        .xbus_cyc   (xbus_cyc),
        .xbus_dat_r (xbus_dat_r),
        .xbus_ack   (xbus_ack),
        .xbus_err   (xbus_err),
        .dbg_leds   (dbg_leds)
    );
endmodule
