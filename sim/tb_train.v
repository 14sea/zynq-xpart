// tb_train.v — M7.2 bit-exact testbench for train_unit.v (the tiny-tpu trio in HW).
//
// Drives train_unit through the full per-sample training sequence the firmware will
// run, feeding the operands the unit consumes (y/target/z2 for loss+d2, w2td2/z1 for
// d1, the SW outer-product gradients dW2/dW1 for the SGD update), and checks LOSS,
// the two δ vectors, and the post-update master register file BIT-EXACT against the
// numpy oracle's golden trace (sim/tb_train_golden.{mem,_init.mem,.vh}, produced by
//   python3 sim/oracle_train.py --dump-tu sim/tb_train_golden --tu-samples 64 ).
//
// Run:  iverilog -g2012 -o /tmp/tb_train rtl/train_unit.v sim/tb_train.v && vvp /tmp/tb_train
`timescale 1ns/1ps
`include "tb_train_golden.vh"

module tb_train;
    reg clk = 0, rst_n = 0, we = 0;
    reg [6:0]  taddr = 0;
    reg signed [31:0] twdata = 0;
    wire signed [31:0] rdata;

    train_unit DUT (.clk(clk), .rst_n(rst_n), .lr(6'd`TU_LR), .k(6'd`TU_K),
                    .we(we), .addr(taddr), .wdata(twdata), .rdata(rdata));

    always #5 clk = ~clk;

    // golden: NSAMP records of STRIDE 32-bit values + 17 init-master values
    reg [31:0] gold [0:`TU_NSAMP*`TU_STRIDE-1];
    reg [31:0] init [0:16];

    integer errors = 0, s, b, n;

    task wr(input [6:0] a, input signed [31:0] d);
        begin @(negedge clk); we = 1; taddr = a; twdata = d; @(posedge clk); #1 we = 0; end
    endtask

    // combinational read-back
    task rd(input [6:0] a, output signed [31:0] v);
        begin taddr = a; #1 v = rdata; end
    endtask

    task chk(input [127:0] tag, input integer idx, input signed [31:0] got, input signed [31:0] exp);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("  MISMATCH %0s[%0d]: got %0d  exp %0d  (s=%0d)", tag, idx, got, exp, s);
            end
        end
    endtask

    reg signed [31:0] v;
    integer base;

    initial begin
        $readmemh("tb_train_golden.mem", gold);
        $readmemh("tb_train_golden_init.mem", init);

        rst_n = 0; repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);

        // preload the master register file (window addr 32..48 == init order)
        for (n = 0; n < 17; n = n + 1) wr(7'd32 + n[6:0], init[n]);

        for (s = 0; s < `TU_NSAMP; s = s + 1) begin
            base = s * `TU_STRIDE;

            // epoch boundary every 4 samples: clear the LOSS accumulator
            if (s % 4 == 0) wr(7'd20, 32'h10);   // CMD[4]=clr_loss

            // ---- (1)+(2) output layer: loss + d2 ----
            for (b = 0; b < 4; b = b + 1) wr(7'd0 + b[6:0],  gold[base + `TU_O_Y  + b]); // INA = y
            for (b = 0; b < 4; b = b + 1) wr(7'd4 + b[6:0],  gold[base + `TU_O_Z2 + b]); // Z   = z2
            for (b = 0; b < 4; b = b + 1) wr(7'd8 + b[6:0],  gold[base + `TU_O_T  + b]); // T
            wr(7'd20, 32'h01);                                                            // CMD[0]=loss_d2
            rd(7'd60, v); chk("LOSS", 0, v, gold[base + `TU_O_SSE]);
            for (b = 0; b < 4; b = b + 1) begin
                rd(7'd52 + b[6:0], v); chk("D2", b, v, gold[base + `TU_O_D2 + b]);
            end

            // ---- (2) hidden layer: d1 ----
            for (b = 0; b < 4; b = b + 1) wr(7'd0 + b[6:0], gold[base + `TU_O_W2TD2 + b]); // INA = w2td2
            for (b = 0; b < 4; b = b + 1) wr(7'd4 + b[6:0], gold[base + `TU_O_Z1    + b]); // Z   = z1
            wr(7'd20, 32'h02);                                                              // CMD[1]=d1
            for (b = 0; b < 4; b = b + 1) begin
                rd(7'd56 + b[6:0], v); chk("D1", b, v, gold[base + `TU_O_D1 + b]);
            end

            // ---- (3) SGD update, output layer (dW2 row0 + d2) ----
            for (b = 0; b < 4; b = b + 1) wr(7'd12 + b[6:0], gold[base + `TU_O_DW2 + b]);   // DW0-3 = dW2
            wr(7'd20, 32'h04);                                                              // CMD[2]=upd_l2

            // ---- (3) SGD update, hidden layer (dW1 flat + d1) ----
            for (b = 0; b < 8; b = b + 1) wr(7'd12 + b[6:0], gold[base + `TU_O_DW1 + b]);   // DW0-7 = dW1
            wr(7'd20, 32'h08);                                                              // CMD[3]=upd_l1

            // ---- check post-update master (window addr 32..48 == record W1A..B2A) ----
            for (n = 0; n < 17; n = n + 1) begin
                rd(7'd32 + n[6:0], v); chk("MSTR", n, v, gold[base + `TU_O_W1A + n]);
            end
        end

        if (errors == 0)
            $display("tb_train: PASS — %0d samples bit-exact (LOSS + d2 + d1 + master) vs oracle",
                     `TU_NSAMP);
        else
            $display("tb_train: FAIL — %0d mismatches", errors);
        $finish;
    end
endmodule
