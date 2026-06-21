// DFX Reconfigurable Module: boot-time Root-of-Trust marker (Model B, M6.4).
//
// Same `tpu_rp` interface as the other RMs. It does no compute — it is the RP's
// "boot identity": always STATUS.done=1, and it returns a fixed RoT attestation
// marker on the POST registers so the UNCHANGED tpu_vpu_firmware (which packs
// {POST3,POST2,POST1,POST0} into the mailbox) publishes 0x600DB007 — visibly
// distinct from the TPU+VPU inference result 0x1019391F.
//
// Model B sequence: boot loads the RP with rm_rot (RoT state) -> measured-boot
// gate passes -> loadbp swaps the RP to rm_tpuvpu (-> 0x1019391F), reclaiming the
// same fabric for inference. The live RoT-marker -> TPU-result transition on the
// mailbox is the M6.4 "measure-then-yield" observable.
//
// Marker layout (firmware packs POST bytes as {P3,P2,P1,P0}):
//   POST0(0x40)=0x07  POST1(0x44)=0xB0  POST2(0x48)=0x0D  POST3(0x4C)=0x60
//   -> mailbox = 0x600DB007 ("good boot")
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
    assign dbg_leds = 4'b0110;   // distinct LED pattern for the RoT module

    wire [11:0] off = xbus_adr[11:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            xbus_ack   <= 1'b0;
            xbus_dat_r <= 32'h0;
        end else begin
            xbus_ack <= xbus_cyc & xbus_stb;        // ack any access (1-cycle)
            case (off)
                12'h004: xbus_dat_r <= 32'h0000_0001;  // STATUS.done = 1 (no compute stall)
                12'h020: xbus_dat_r <= 32'h600D_B007;  // RES0 = RoT marker (UART self-check)
                12'h040: xbus_dat_r <= 32'h0000_0007;  // POST0
                12'h044: xbus_dat_r <= 32'h0000_00B0;  // POST1
                12'h048: xbus_dat_r <= 32'h0000_000D;  // POST2
                12'h04C: xbus_dat_r <= 32'h0000_0060;  // POST3
                default: xbus_dat_r <= 32'h0000_0000;
            endcase
        end
    end
endmodule
