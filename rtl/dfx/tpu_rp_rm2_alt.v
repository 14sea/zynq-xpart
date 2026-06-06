// DFX Reconfigurable Module #2 (RM2): an alternate "accelerator".
//
// Same `tpu_rp` interface as RM1, but a deliberately different, tiny behaviour:
// it ignores the weights/inputs, always reports STATUS.done=1, and returns
// fixed RES0=0xBB, RES1=0xCC. Running the same firmware sequence then yields
// PS mailbox 0x00BB00CC -- clearly different from RM1's 0x001E0046, so a live
// partial-reconfiguration swap is unmistakable on the PS side.
//
// Register map (subset of wb_tpu_accel, byte offsets within the RP):
//   0x004 STATUS -> 0x00000001 (always done)
//   0x020 RES0   -> 0x000000BB
//   0x024 RES1   -> 0x000000CC
//   others       -> 0
module tpu_rp (
    input             clk,
    input             rst_n,
    input      [31:0] xbus_adr,
    input      [31:0] xbus_dat_w,
    input      [3:0]  xbus_sel,
    input             xbus_we,
    input             xbus_stb,
    input             xbus_cyc,
    output reg [31:0] xbus_dat_r,
    output reg        xbus_ack,
    output            xbus_err,
    output     [3:0]  dbg_leds
);
    assign xbus_err  = 1'b0;
    assign dbg_leds  = 4'b1010;   // distinct LED pattern for RM2

    wire [11:0] off = xbus_adr[11:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            xbus_ack   <= 1'b0;
            xbus_dat_r <= 32'h0;
        end else begin
            xbus_ack <= xbus_cyc & xbus_stb;   // ack any access (1-cycle)
            case (off)
                12'h004: xbus_dat_r <= 32'h0000_0001;  // STATUS.done = 1
                12'h020: xbus_dat_r <= 32'h0000_00BB;  // RES0
                12'h024: xbus_dat_r <= 32'h0000_00CC;  // RES1
                default: xbus_dat_r <= 32'h0000_0000;
            endcase
        end
    end
endmodule
