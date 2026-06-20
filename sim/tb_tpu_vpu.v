// tb_tpu_vpu.v — M6.0 evidence testbench for rtl/vpu.v
//
// Validates POST0-3 (INT8) against an INDEPENDENT software golden oracle that
// re-implements the bit-exact VPU arithmetic contract from docs/m6_plan.md
// (bias -> Leaky ReLU -> 48-bit requant round-half-up -> INT8 saturate).
//
// The 4x4 matmul itself is already validated in M2 (RES0=30,RES1=70), so we
// feed the systolic array's known RES0-3 directly into the VPU rather than
// re-driving the array here — this isolates the VPU arithmetic under test.
//
// Coverage: the four required corners (x<0 leaky path, saturate-high,
// saturate-low, shift==0), one M2 MNIST-tile vector, plus randomized fuzzing.
//
// Run:  iverilog -o /tmp/tb_tpu_vpu.vvp rtl/vpu.v sim/tb_tpu_vpu.v && vvp /tmp/tb_tpu_vpu.vvp

`timescale 1ns/1ps
module tb_tpu_vpu;

    reg         clk = 0, rst_n = 0;
    reg         start = 0;
    reg [127:0] res_in = 0, bias_in = 0;
    reg         bias_en = 0, act_en = 0;
    reg [15:0]  scale = 0;
    reg [5:0]   shift = 0, alpha = 0;
    wire [31:0] post_out;
    wire        done;

    integer pass = 0, fail = 0;

    vpu dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .res_in(res_in), .bias_in(bias_in),
        .bias_en(bias_en), .act_en(act_en),
        .scale(scale), .shift(shift), .alpha(alpha),
        .post_out(post_out), .done(done)
    );

    always #5 clk = ~clk;

    // ── Independent golden oracle (same widths as RTL, for bit-exactness) ─────
    function signed [7:0] oracle;
        input signed [31:0] res;
        input signed [31:0] bias;
        input               be;     // bias_en
        input               ae;     // act_en
        input signed [15:0] sc;     // scale
        input [5:0]         sft;    // shift
        input [5:0]         alp;    // alpha
        reg signed [31:0] acc;      // 32-bit: bias add wraps here, like the RTL
        reg signed [31:0] act;
        reg signed [47:0] prod, rnd, shd;
        begin
            acc = res;
            if (be) acc = acc + bias;                  // wrapping INT32 add
            if (!ae)            act = acc;             // passthrough
            else if (acc >= 0)  act = acc;             // leaky: positive path
            else                act = acc - (acc >>> alp); // leaky: negative path
            prod = act * sc;                           // signed 48-bit
            if (sft != 6'd0) rnd = prod + (48'sd1 <<< (sft - 6'd1)); // round-half-up
            else             rnd = prod;
            shd = rnd >>> sft;                         // arithmetic shift
            if      (shd > 48'sd127)  oracle = 8'sd127;
            else if (shd < -48'sd128) oracle = -8'sd128;
            else                      oracle = shd[7:0];
        end
    endfunction

    // ── Drive one case and compare all 4 lanes against the oracle ────────────
    task run_case;
        input [127:0] res_v;
        input [127:0] bias_v;
        input         be, ae;
        input [15:0]  sc;
        input [5:0]   sft, alp;
        input [255:0] label;       // ascii tag
        integer k;
        reg signed [7:0] exp, got;
        reg ok;
        begin
            @(negedge clk);
            res_in=res_v; bias_in=bias_v; bias_en=be; act_en=ae;
            scale=sc; shift=sft; alpha=alp;
            start=1; @(negedge clk); start=0;
            // 4-cycle pipeline; wait for done
            wait (done == 1'b1); @(negedge clk);
            ok = 1;
            for (k = 0; k < 4; k = k + 1) begin
                exp = oracle(res_v[32*k +: 32], bias_v[32*k +: 32], be, ae, sc, sft, alp);
                got = post_out[8*k +: 8];
                if (exp !== got) begin
                    ok = 0;
                    $display("  [FAIL] %0s lane%0d: res=%0d bias=%0d be=%b ae=%b sc=%0d sft=%0d alp=%0d  exp=%0d got=%0d",
                             label, k, $signed(res_v[32*k +: 32]), $signed(bias_v[32*k +: 32]),
                             be, ae, $signed(sc), sft, alp, exp, got);
                end
            end
            if (ok) begin
                pass = pass + 1;
                $display("  [pass] %0s  POST = %0d %0d %0d %0d",
                         label, $signed(post_out[7:0]),  $signed(post_out[15:8]),
                                $signed(post_out[23:16]), $signed(post_out[31:24]));
            end else fail = fail + 1;
        end
    endtask

    integer n;
    reg [127:0] rr, bb;
    reg [15:0] sc; reg [5:0] sft, alp; reg be, ae;

    initial begin
        rst_n = 0; repeat (4) @(negedge clk); rst_n = 1; @(negedge clk);

        $display("== tb_tpu_vpu : VPU vs golden oracle ==");

        // --- Required corner cases ---
        // C1: x<0 leaky path (negative RES, act on, alpha=4 -> slope 0.9375), no saturate
        run_case({-32'sd16, -32'sd8, -32'sd4, -32'sd2}, 128'd0, 0, 1,
                 16'sd1, 6'd0, 6'd4, "C1 leaky-neg shift0");
        // C2: saturate-high (large positive product clamps to +127)
        run_case({32'sd1000, 32'sd2000, 32'sd5000, 32'sd9999}, 128'd0, 0, 0,
                 16'sd100, 6'd0, 6'd0, "C2 saturate-high");
        // C3: saturate-low (large negative product clamps to -128)
        run_case({-32'sd1000, -32'sd2000, -32'sd5000, -32'sd9999}, 128'd0, 0, 0,
                 16'sd100, 6'd0, 6'd0, "C3 saturate-low");
        // C4: shift==0 (no rounding add, no shift)
        run_case({32'sd3, 32'sd10, 32'sd50, -32'sd7}, 128'd0, 1, 1,
                 16'sd2, 6'd0, 6'd3, "C4 shift0+bias");
        // C4b: shift>0 round-half-up exercised
        run_case({32'sd30, 32'sd70, 32'sd125, -32'sd33}, 128'd0, 0, 1,
                 16'sd6, 6'd3, 6'd4, "C4b round shift3");

        // --- M2 MNIST tile (RES0=30, RES1=70 from M2; full lane set + requant) ---
        run_case({-32'sd45, 32'sd120, 32'sd70, 32'sd30},
                 {32'sd5, -32'sd10, 32'sd0, 32'sd8}, 1, 1,
                 16'sd181, 6'd7, 6'd4, "M2 MNIST tile");

        // --- Randomized fuzz ---
        for (n = 0; n < 300; n = n + 1) begin
            rr  = {$random, $random, $random, $random};
            // keep RES magnitudes moderate so we hit both saturate and clean regions
            rr[31:0]   = $signed(rr[31:0])   % 4000;
            rr[63:32]  = $signed(rr[63:32])  % 4000;
            rr[95:64]  = $signed(rr[95:64])  % 4000;
            rr[127:96] = $signed(rr[127:96]) % 4000;
            bb  = {$random, $random, $random, $random};
            bb[31:0]   = $signed(bb[31:0])   % 500;
            bb[63:32]  = $signed(bb[63:32])  % 500;
            bb[95:64]  = $signed(bb[95:64])  % 500;
            bb[127:96] = $signed(bb[127:96]) % 500;
            sc  = $signed($random) % 400;
            sft = $unsigned($random) % 12;
            alp = ($unsigned($random) % 6) + 1;   // 1..6
            be  = $random;
            ae  = $random;
            run_case(rr, bb, be, ae, sc, sft, alp, "rand");
        end

        $display("== RESULT: %0d passed, %0d failed ==", pass, fail);
        if (fail == 0) $display("== M6.0 VPU arithmetic: ALL MATCH oracle ==");
        else           $display("== M6.0 VPU: MISMATCH ==");
        $finish;
    end

    // safety timeout
    initial begin #2000000; $display("TIMEOUT"); $finish; end

endmodule
