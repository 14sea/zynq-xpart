// tb_rm_train.v — integration sim of the rm_train DFX wrapper (tpu_rp_rm_train.v)
// driven by a Wishbone-style master doing the firmware's exact write→CMD→read
// sequence through the XBUS. The standalone tb_train.v proves train_unit; THIS
// proves the wrapper handshake (claim window, single-pulse CMD, ack/read mux) that
// the board actually exercises — the layer that was previously only elaborated.
`timescale 1ns/1ps
module tb_rm_train;
    reg clk = 0, rst_n = 0;
    reg [31:0] adr = 0, dat_w = 0;
    reg [3:0]  sel = 0;
    reg we = 0, stb = 0, cyc = 0;
    wire [31:0] dat_r;
    wire ack, err;
    wire [3:0] leds;

    tpu_rp DUT (.clk(clk), .rst_n(rst_n),
        .xbus_adr(adr), .xbus_dat_w(dat_w), .xbus_sel(sel),
        .xbus_we(we), .xbus_stb(stb), .xbus_cyc(cyc),
        .xbus_dat_r(dat_r), .xbus_ack(ack), .xbus_err(err), .dbg_leds(leds));

    always #5 clk = ~clk;

    localparam TU = 32'hF0000800;   // train_unit window base (matches main.c TU_BASE)

    task wb_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk); adr=a; dat_w=d; sel=4'hF; we=1; stb=1; cyc=1;
            @(posedge clk); while (!ack) @(posedge clk);
            @(negedge clk); stb=0; cyc=0; we=0;
        end
    endtask
    task wb_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk); adr=a; we=0; sel=4'hF; stb=1; cyc=1;
            @(posedge clk); while (!ack) @(posedge clk);
            d = dat_r;
            @(negedge clk); stb=0; cyc=0;
        end
    endtask

    integer errors = 0;
    task chk(input [127:0] tag, input [31:0] got, input [31:0] exp);
        begin if (got !== exp) begin errors=errors+1;
            $display("  MISMATCH %0s: got %0d exp %0d", tag, got, exp); end
        end
    endtask

    reg [31:0] v;
    initial begin
        rst_n=0; repeat(3) @(posedge clk); rst_n=1; @(posedge clk);

        // 1. master write/read-back through the wrapper (word 44 = W2m[0])
        wb_write(TU + 44*4, 32'd123);
        wb_read (TU + 44*4, v); chk("W2m0 rb", v, 32'd123);
        wb_write(TU + 32*4, -32'sd77 & 32'hFFFFFFFF);   // W1m[0]
        wb_read (TU + 32*4, v); chk("W1m0 rb", v, -32'sd77 & 32'hFFFFFFFF);

        // 2. loss_d2 sequence: y=[256,0,0,0], z2=[256,..], t=0  -> LOSS=256, D2[0]=256
        wb_write(TU + 20*4, 32'h10);                    // CMD clr_loss
        wb_write(TU + 0*4, 32'd256);                    // INA0 = y0
        wb_write(TU + 1*4, 0); wb_write(TU + 2*4, 0); wb_write(TU + 3*4, 0);
        wb_write(TU + 4*4, 32'd256);                    // Z0 = z2 (>=0)
        wb_write(TU + 5*4, 0); wb_write(TU + 6*4, 0); wb_write(TU + 7*4, 0);
        wb_write(TU + 8*4, 0); wb_write(TU + 9*4, 0);   // T = 0
        wb_write(TU +10*4, 0); wb_write(TU +11*4, 0);
        wb_write(TU + 20*4, 32'h01);                    // CMD loss_d2
        wb_read (TU + 60*4, v); chk("LOSS", v, 32'd256);
        wb_read (TU + 52*4, v); chk("D2_0", v, 32'd256);
        wb_read (TU + 53*4, v); chk("D2_1", v, 32'd0);

        // 3. second loss_d2 accumulates: another err0=256 -> LOSS=512
        wb_write(TU + 0*4, 32'd256); wb_write(TU + 4*4, 32'd256);
        wb_write(TU + 8*4, 0);
        wb_write(TU + 20*4, 32'h01);
        wb_read (TU + 60*4, v); chk("LOSS acc", v, 32'd512);

        if (errors==0) $display("tb_rm_train: PASS — wrapper bus path OK (master rw + loss/d2 through XBUS)");
        else           $display("tb_rm_train: FAIL — %0d mismatches", errors);
        $finish;
    end
endmodule
