// wb_tpu_accel_kcm.v (M6.5) — self-contained copy of rtl/wb_tpu_accel.v for the
// LUT-KCM RM. IDENTICAL to wb_tpu_accel.v except module renamed and it wraps
// tpu_accel_kcm (baked-weight KCM array) instead of tpu_accel.

module wb_tpu_accel_kcm (
    input         clk,
    input         rst_n,
    input  [31:0] xbus_adr,
    input  [31:0] xbus_dat_w,
    input  [3:0]  xbus_sel,
    input         xbus_we,
    input         xbus_stb,
    input         xbus_cyc,
    output reg [31:0] xbus_dat_r,
    output reg    xbus_ack,
    output        xbus_err,
    output [3:0]  dbg_leds,
    output [31:0] res0_o,
    output [31:0] res1_o,
    output [31:0] res2_o,
    output [31:0] res3_o,
    output        mm_done_o
);

    wire [31:0] tpu_rdata;
    wire        tpu_ready;
    wire [3:0]  tpu_debug;

    reg pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending    <= 1'b0;
            xbus_ack   <= 1'b0;
            xbus_dat_r <= 32'd0;
        end else begin
            xbus_ack <= 1'b0;

            if (xbus_cyc && xbus_stb && !pending) begin
                pending <= 1'b1;
            end

            if (pending && tpu_ready) begin
                xbus_dat_r <= tpu_rdata;
                xbus_ack   <= 1'b1;
                pending    <= 1'b0;
            end
        end
    end

    assign xbus_err = 1'b0;
    assign dbg_leds = tpu_debug;

    tpu_accel_kcm u_tpu (
        .clk       (clk),
        .rst_n     (rst_n),
        .sel       (pending),
        .addr      (xbus_adr[11:0]),
        .wdata     (xbus_dat_w),
        .wstrb     (xbus_we ? xbus_sel : 4'b0000),
        .rdata     (tpu_rdata),
        .ready     (tpu_ready),
        .debug_led (tpu_debug),
        .res0_o    (res0_o),
        .res1_o    (res1_o),
        .res2_o    (res2_o),
        .res3_o    (res3_o),
        .mm_done_o (mm_done_o)
    );

endmodule
