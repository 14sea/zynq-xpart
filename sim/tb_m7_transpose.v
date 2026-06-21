// tb_m7_transpose.v — reproduce the M7.1 board divergence in simulation.
//
// Drives wb_tpu_accel with the EXACT firmware array_macc() sequence (bulk
// W_DATA4 load per row, CTRL clear, X_IN, CTRL start, poll done, read RES0-3),
// for two patterns:
//   (A) dense  : W=[[1,1,1,1],[1,2,3,4],[2,2,2,2],[1,0,1,0]] X=[2,3,4,5]
//                -> expect RES = [14,40,28,6]            (forward, M7.0-proven)
//   (B) transpose pattern : Wcol0=[1,2,3,4] (col0 only), X=[5,0,0,0]
//                -> expect RES = [5,10,15,20]            (the Wᵀ·δ data pattern)
// (B) is the single-nonzero-input-lane pattern the forward never exercised.
//
// Run: iverilog -g2012 -o /tmp/tbm7.vvp \
//        rtl/pe.v rtl/systolic_array_4x4.v rtl/tpu_accel.v rtl/wb_tpu_accel.v \
//        sim/tb_m7_transpose.v && vvp /tmp/tbm7.vvp

`timescale 1ns/1ps
module tb_m7_transpose;
    reg         clk = 0, rst_n = 0;
    reg  [31:0] xadr = 0, xdw = 0;
    reg  [3:0]  xsel = 0;
    reg         xwe = 0, xstb = 0, xcyc = 0;
    wire [31:0] xdr;
    wire        xack, xerr;
    wire [3:0]  leds;
    integer pass = 0, fail = 0;

    wb_tpu_accel dut (
        .clk(clk), .rst_n(rst_n),
        .xbus_adr(xadr), .xbus_dat_w(xdw), .xbus_sel(xsel),
        .xbus_we(xwe), .xbus_stb(xstb), .xbus_cyc(xcyc),
        .xbus_dat_r(xdr), .xbus_ack(xack), .xbus_err(xerr), .dbg_leds(leds),
        .res0_o(), .res1_o(), .res2_o(), .res3_o(), .mm_done_o()
    );

    always #5 clk = ~clk;

    task bus_write(input [31:0] addr, input [31:0] data);
        integer g; begin
            @(negedge clk); xadr=addr; xdw=data; xsel=4'hF; xwe=1; xstb=1; xcyc=1;
            @(negedge clk); g=0;
            while (!xack && g<1000) begin @(negedge clk); g=g+1; end
            @(negedge clk); xstb=0; xcyc=0; xwe=0; @(negedge clk);
        end
    endtask
    task bus_read(input [31:0] addr, output [31:0] data);
        integer g; begin
            @(negedge clk); xadr=addr; xdw=0; xsel=4'hF; xwe=0; xstb=1; xcyc=1;
            @(negedge clk); g=0;
            while (!xack && g<1000) begin @(negedge clk); g=g+1; end
            data = xdr;
            @(negedge clk); xstb=0; xcyc=0; @(negedge clk);
        end
    endtask

    // EXACT array_macc(): load 4 rows via W_DATA4, clear, X_IN, start, poll, read.
    reg [31:0] st; integer g; reg [31:0] res [0:3];
    task array_macc(input [31:0] r0, input [31:0] r1, input [31:0] r2,
                    input [31:0] r3, input [31:0] xpk);
        begin
            bus_write(32'h08, 32'h0); bus_write(32'h14, r0);   // W_ADDR row0, W_DATA4
            bus_write(32'h08, 32'h4); bus_write(32'h14, r1);   // row1 (W_ADDR[3:2]=1)
            bus_write(32'h08, 32'h8); bus_write(32'h14, r2);   // row2
            bus_write(32'h08, 32'hC); bus_write(32'h14, r3);   // row3
            bus_write(32'h00, 32'h10);                          // clear acc+done
            bus_write(32'h10, xpk);                             // X_IN
            bus_write(32'h00, 32'h01);                          // start
            g=0; st=0;
            while (!(st & 32'h1) && g<200) begin bus_read(32'h04, st); g=g+1; end
            bus_read(32'h20, res[0]); bus_read(32'h24, res[1]);
            bus_read(32'h28, res[2]); bus_read(32'h2C, res[3]);
        end
    endtask

    task check(input [31:0] e0, input [31:0] e1, input [31:0] e2, input [31:0] e3,
               input [127:0] name);
        begin
            $display("  %0s: RES = %0d %0d %0d %0d  (expect %0d %0d %0d %0d)",
                     name, $signed(res[0]), $signed(res[1]), $signed(res[2]),
                     $signed(res[3]), $signed(e0), $signed(e1), $signed(e2), $signed(e3));
            if (res[0]==e0 && res[1]==e1 && res[2]==e2 && res[3]==e3) pass=pass+1;
            else begin fail=fail+1; $display("    ^^ MISMATCH"); end
        end
    endtask

    initial begin
        rst_n=0; repeat(5) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);
        $display("== tb_m7_transpose : array_macc dense vs transpose pattern ==");

        // (A) dense forward — W rows packed {w3,w2,w1,w0}
        array_macc(32'h01010101, 32'h04030201, 32'h02020202, 32'h00010001, 32'h05040302);
        check(14, 40, 28, 6, "dense   ");

        // (B) transpose pattern — col0 = [1,2,3,4], X = [5,0,0,0]
        array_macc(32'h00000001, 32'h00000002, 32'h00000003, 32'h00000004, 32'h00000005);
        check(5, 10, 15, 20, "transp  ");

        // (C) negative weights/δ (real training values). col0=[-26,50,-100,13],
        //     X=[-40,0,0,0] -> [1040,-2000,4000,-520]. Bytes: -26=0xE6,50=0x32,
        //     -100=0x9C,13=0x0D ; X0=-40=0xD8.
        array_macc(32'h000000E6, 32'h00000032, 32'h0000009C, 32'h0000000D, 32'h000000D8);
        check(1040, -2000, 4000, -520, "transN  ");

        // (D) three consecutive calls (forward, forward, transpose) as each
        //     training sample does — verify the 3rd (transpose) is not corrupted.
        array_macc(32'h01010101, 32'h04030201, 32'h02020202, 32'h00010001, 32'h05040302);
        array_macc(32'h01010101, 32'h04030201, 32'h02020202, 32'h00010001, 32'h05040302);
        array_macc(32'h00000001, 32'h00000002, 32'h00000003, 32'h00000004, 32'h00000005);
        check(5, 10, 15, 20, "3calls  ");

        // (E) ZERO-ROW pattern — exactly the main.c on-board probe: row0=[5,6,7,8]
        //     nonzero, rows1-3 all zero, X=[1,1,1,1] -> expect [26,0,0,0]. The
        //     firmware comment claims lanes1-3 show garbage on board ("zero-row bug").
        array_macc(32'h08070605, 32'h00000000, 32'h00000000, 32'h00000000, 32'h01010101);
        check(26, 0, 0, 0, "zerorow ");

        // (F) WORST-CASE residual leak: first a matmul that drives big values into
        //     all 4 lanes, THEN the zero-row matmul. If CTRL[4] clear / PE psum
        //     reset is incomplete, lanes1-3 keep the stale 100/100/100 here.
        array_macc(32'h64646464, 32'h64646464, 32'h64646464, 32'h64646464, 32'h01010101);
        check(400, 400, 400, 400, "fill4   ");
        array_macc(32'h08070605, 32'h00000000, 32'h00000000, 32'h00000000, 32'h01010101);
        check(26, 0, 0, 0, "zr-after");

        $display("== %0d passed, %0d failed ==", pass, fail);
        $finish;
    end
endmodule
