// DFX Reconfigurable Module for Phase 4 (M4-scaled): a LUT-table unit whose
// "weights" live directly in LUT6 INIT bits -- the literal JBits/XPART use case.
//
// Same `tpu_rp` partition interface as the other RMs. The existing firmware loop
// (run_mac) writes the packed inputs to X_IN (0x10) and reads RES0 (0x20); here
// RES0 returns an 8-bit table output Y indexed by X_IN[5:0], and RES1 (0x24) is a
// constant marker 0x4D ('M'). With the firmware's X_IN = 0x04030201, the index is
// X=1, so Y = byte assembled from bit[1] of each of the 8 LUT6 INITs.
//
// The 8 LUT6 are DONT_TOUCH so they survive synthesis and are locatable. Editing
// a LUT6 INIT bit host-side in the partial bitstream changes Y, and `fpga loadbp`
// applies it LIVE (no resynthesis, no cold boot) -- LUT-truth-table surgery.
//
// Initial table for X=1: Y = 0x5A  ->  PS mailbox = (0x5A<<16)|0x4D = 0x005A004D.
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
    assign xbus_err = 1'b0;
    assign dbg_leds = 4'b0011;

    reg  [5:0]  x_reg;
    wire [7:0]  y;
    wire [11:0] off = xbus_adr[11:0];

    // 8 LUT6 holding the table. INIT bit[i] is Y[k] for index X=i.
    // Only entry X=1 is meaningful here (the firmware drives X=1); bit[1] of each
    // INIT spells the target byte 0x5A = 0b0101_1010 (LSB = y[0]).
    //   y[0]=0  y[1]=1  y[2]=0  y[3]=1  y[4]=1  y[5]=0  y[6]=1  y[7]=0
    (* DONT_TOUCH="yes" *) LUT6 #(.INIT(64'h0000_0000_0000_0002)) l0 (.O(y[0]),.I0(x_reg[0]),.I1(x_reg[1]),.I2(x_reg[2]),.I3(x_reg[3]),.I4(x_reg[4]),.I5(x_reg[5]));
    (* DONT_TOUCH="yes" *) LUT6 #(.INIT(64'h0000_0000_0000_0002)) l1 (.O(y[1]),.I0(x_reg[0]),.I1(x_reg[1]),.I2(x_reg[2]),.I3(x_reg[3]),.I4(x_reg[4]),.I5(x_reg[5]));
    (* DONT_TOUCH="yes" *) LUT6 #(.INIT(64'h0000_0000_0000_0000)) l2 (.O(y[2]),.I0(x_reg[0]),.I1(x_reg[1]),.I2(x_reg[2]),.I3(x_reg[3]),.I4(x_reg[4]),.I5(x_reg[5]));
    (* DONT_TOUCH="yes" *) LUT6 #(.INIT(64'h0000_0000_0000_0002)) l3 (.O(y[3]),.I0(x_reg[0]),.I1(x_reg[1]),.I2(x_reg[2]),.I3(x_reg[3]),.I4(x_reg[4]),.I5(x_reg[5]));
    (* DONT_TOUCH="yes" *) LUT6 #(.INIT(64'h0000_0000_0000_0002)) l4 (.O(y[4]),.I0(x_reg[0]),.I1(x_reg[1]),.I2(x_reg[2]),.I3(x_reg[3]),.I4(x_reg[4]),.I5(x_reg[5]));
    (* DONT_TOUCH="yes" *) LUT6 #(.INIT(64'h0000_0000_0000_0000)) l5 (.O(y[5]),.I0(x_reg[0]),.I1(x_reg[1]),.I2(x_reg[2]),.I3(x_reg[3]),.I4(x_reg[4]),.I5(x_reg[5]));
    (* DONT_TOUCH="yes" *) LUT6 #(.INIT(64'h0000_0000_0000_0002)) l6 (.O(y[6]),.I0(x_reg[0]),.I1(x_reg[1]),.I2(x_reg[2]),.I3(x_reg[3]),.I4(x_reg[4]),.I5(x_reg[5]));
    (* DONT_TOUCH="yes" *) LUT6 #(.INIT(64'h0000_0000_0000_0000)) l7 (.O(y[7]),.I0(x_reg[0]),.I1(x_reg[1]),.I2(x_reg[2]),.I3(x_reg[3]),.I4(x_reg[4]),.I5(x_reg[5]));

    always @(posedge clk) begin
        if (!rst_n) begin
            x_reg      <= 6'd0;
            xbus_ack   <= 1'b0;
            xbus_dat_r <= 32'h0;
        end else begin
            xbus_ack <= xbus_cyc & xbus_stb;
            if ((xbus_cyc & xbus_stb & xbus_we) && off == 12'h010)
                x_reg <= xbus_dat_w[5:0];           // X_IN -> table index
            case (off)
                12'h004: xbus_dat_r <= 32'h0000_0001;       // STATUS.done = 1
                12'h020: xbus_dat_r <= {24'h0, y};          // RES0 = Y(X)
                12'h024: xbus_dat_r <= 32'h0000_004D;       // RES1 = marker 'M'
                default: xbus_dat_r <= 32'h0000_0000;
            endcase
        end
    end
endmodule
