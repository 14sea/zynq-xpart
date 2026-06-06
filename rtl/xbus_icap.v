// INVESTIGATION ARTIFACT (task #8 part 1) -- see docs/icap_investigation.md.
// Not in the active DFX build; the proven live LUT edit uses PCAP/loadbp (docs/lut_surgery.md).
// This custom controller proved the ICAP is electrically reachable from NEORV32 (it can
// perturb the LUT live) but could not do a clean/deterministic single-frame write on this board.
//
// XBUS -> ICAPE2 self-reconfiguration + readback port (Zynq-7, static region).
//
// NEORV32 fills a buffer with a config-word sequence, then triggers a burst that
// streams it to ICAPE2 at one word/clock with CSIB held low (a CSIB de-assert
// aborts config). A read op additionally captures ICAPE2.O[] after the command
// burst, so the soft-core can read the config STATUS register (or frame data)
// back through ICAP -- the diagnostic for whether the ICAP interface is alive.
//
// Register map (XBUS @ 0xF3000000):
//   0x00 W data -> buf[wptr++]            (fill)
//   0x04 W x     -> wptr = 0
//   0x08 W N     -> write-burst buf[0..N-1] (RDWRB=0)
//   0x0C W m     -> swap mode (0=none 1=byte-bitrev 2=byteswap 3=byteswap+bitrev)
//   0x10 W {wlen|rlen<<8} -> burst wlen words then capture rlen O[] words (RDWRB=1)
//   0x14 R       -> rdbuf[rdaddr++]       (read captured words)
//   0x18 W x     -> rdaddr = 0
//   other R      -> {state, swmode}       (status)
module xbus_icap (
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
    output            xbus_err
);
    assign xbus_err = 1'b0;

    wire sel       = xbus_cyc & xbus_stb;
    wire sel_we    = sel & xbus_we;
    wire sel_rd    = sel & ~xbus_we;
    reg  prev_sel;
    wire new_acc   = sel & ~prev_sel;        // one pulse per XBUS access
    wire new_write = new_acc & xbus_we;
    wire new_read  = new_acc & ~xbus_we;

    localparam IDLE = 2'd0, WRITING = 2'd1, READING = 2'd2;
    reg [1:0]  state;
    reg [31:0] buffer [0:255];
    reg [31:0] rdbuf  [0:127];
    reg [7:0]  wptr, sptr, slen, rlen, rptr;
    reg [6:0]  rdaddr;
    reg [1:0]  swmode;
    reg        csib, rdwrb;
    reg [31:0] idata;
    wire [31:0] odata;

    function [31:0] br8;
        input [31:0] d; integer i;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                br8[0+i]=d[7-i]; br8[8+i]=d[15-i]; br8[16+i]=d[23-i]; br8[24+i]=d[31-i];
            end
        end
    endfunction

    function [31:0] swap;
        input [1:0] m; input [31:0] d;
        reg [31:0] bs;
        begin
            bs = {d[7:0], d[15:8], d[23:16], d[31:24]};
            case (m)
                2'd0: swap = d;
                2'd1: swap = br8(d);
                2'd2: swap = bs;
                default: swap = br8(bs);
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_sel<=0; state<=IDLE; wptr<=0; sptr<=0; slen<=0; rlen<=0; rptr<=0;
            rdaddr<=0; swmode<=2'd1; csib<=1; rdwrb<=1; idata<=0; xbus_ack<=0; xbus_dat_r<=0;
        end else begin
            prev_sel <= sel;
            xbus_ack <= sel;

            // default read response = status
            xbus_dat_r <= {29'h0, state, swmode[0]};

            case (state)
                WRITING: begin
                    csib  <= 1'b0; rdwrb <= 1'b0;
                    idata <= swap(swmode, buffer[sptr]);
                    sptr  <= sptr + 8'd1;
                    if (sptr == slen - 8'd1) state <= (rlen != 0) ? READING : IDLE;
                end
                READING: begin
                    csib  <= 1'b0; rdwrb <= 1'b1;     // read from ICAP
                    rdbuf[rptr[6:0]] <= odata;        // capture raw O[]
                    rptr  <= rptr + 8'd1;
                    if (rptr == rlen - 8'd1) state <= IDLE;
                end
                default: begin                        // IDLE
                    csib <= 1'b1; rdwrb <= 1'b1;
                    if (new_read && xbus_adr[4:0] == 5'h14) begin
                        xbus_dat_r <= rdbuf[rdaddr];
                        rdaddr <= rdaddr + 7'd1;
                    end
                    if (new_write) begin
                        case (xbus_adr[4:0])
                            5'h00: begin buffer[wptr] <= xbus_dat_w; wptr <= wptr + 8'd1; end
                            5'h04: wptr <= 8'd0;
                            5'h08: begin sptr<=0; slen<=xbus_dat_w[7:0]; rlen<=8'd0; state<=WRITING; end
                            5'h0C: swmode <= xbus_dat_w[1:0];
                            5'h10: begin sptr<=0; rptr<=0; slen<=xbus_dat_w[7:0];
                                         rlen<=xbus_dat_w[15:8]; state<=WRITING; end
                            5'h18: rdaddr <= 5'd0;
                            default: ;
                        endcase
                    end
                end
            endcase
        end
    end

    ICAPE2 #(.ICAP_WIDTH("X32"), .SIM_CFG_FILE_NAME("NONE"), .DEVICE_ID(32'h13722093))
      icap_i (.O(odata), .CLK(clk), .CSIB(csib), .I(idata), .RDWRB(rdwrb));
endmodule
