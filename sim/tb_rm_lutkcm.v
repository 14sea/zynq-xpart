// tb_rm_lutkcm.v (M6.5.0) — sim for the LUT-KCM RM.
//
// The whole point: NO weights are loaded over the bus. The 16 weights live in
// the fabric (lutkcm_pe constants). We only drive X_IN + VPU params + start,
// then assert the matmul produced the M6.3 reference tile's RES (14,40,28,6)
// and the VPU produced the same packed mailbox value 0x1019391F. If the baked
// weights were wrong (or the load path were secretly needed), RES would differ.
//
// Run: iverilog -g2012 -o /tmp/tb_kcm.vvp \
//        rtl/dfx/lutkcm_pe.v rtl/dfx/lutkcm_array.v rtl/dfx/tpu_accel_kcm.v \
//        rtl/dfx/wb_tpu_accel_kcm.v rtl/vpu.v rtl/dfx/tpu_rp_rm_lutkcm.v \
//        sim/tb_rm_lutkcm.v && vvp /tmp/tb_kcm.vvp

`timescale 1ns/1ps
module tb_rm_lutkcm;

    reg         clk = 0, rst_n = 0;
    reg  [31:0] xadr = 0, xdw = 0;
    reg  [3:0]  xsel = 0;
    reg         xwe = 0, xstb = 0, xcyc = 0;
    wire [31:0] xdr;
    wire        xack, xerr;
    wire [3:0]  leds;

    integer pass = 0, fail = 0;

    tpu_rp dut (
        .clk(clk), .rst_n(rst_n),
        .xbus_adr(xadr), .xbus_dat_w(xdw), .xbus_sel(xsel),
        .xbus_we(xwe), .xbus_stb(xstb), .xbus_cyc(xcyc),
        .xbus_dat_r(xdr), .xbus_ack(xack), .xbus_err(xerr), .dbg_leds(leds)
    );

    always #5 clk = ~clk;

    task bus_write(input [31:0] addr, input [31:0] data);
        integer g;
        begin
            @(negedge clk);
            xadr=addr; xdw=data; xsel=4'hF; xwe=1'b1; xstb=1'b1; xcyc=1'b1;
            @(negedge clk);
            g=0;
            while (!xack && g<1000) begin @(negedge clk); g=g+1; end
            @(negedge clk);
            xstb=1'b0; xcyc=1'b0; xwe=1'b0;
            @(negedge clk);
        end
    endtask

    task bus_read(input [31:0] addr, output [31:0] data);
        integer g;
        begin
            @(negedge clk);
            xadr=addr; xdw=32'd0; xsel=4'hF; xwe=1'b0; xstb=1'b1; xcyc=1'b1;
            @(negedge clk);
            g=0;
            while (!xack && g<1000) begin @(negedge clk); g=g+1; end
            data = xdr;
            @(negedge clk);
            xstb=1'b0; xcyc=1'b0;
            @(negedge clk);
        end
    endtask

    reg [31:0] res [0:3];
    reg [31:0] post_rd [0:3];
    reg [31:0] st;
    reg [31:0] mbox;
    integer i, g;
    reg signed [31:0] bias_v [0:3];
    reg [15:0] SC; reg [5:0] SFT, ALP;

    // Expected: M6.3 reference tile.
    localparam signed [31:0] EXP_RES0 = 32'sd14, EXP_RES1 = 32'sd40,
                             EXP_RES2 = 32'sd28, EXP_RES3 = 32'sd6;
    localparam [31:0] EXP_MBOX = 32'h1019391F;   // {P3,P2,P1,P0}={16,25,57,31}

    initial begin
        rst_n=0; repeat(5) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);
        $display("== tb_rm_lutkcm : LUT-KCM RM (baked weights, NO load) ==");

        // ---- NO weight load. Just X_IN + VPU params + start. ----
        bus_write(32'h10, 32'h05_04_03_02);     // X_IN = x0=2,x1=3,x2=4,x3=5

        bias_v[0]=32'sd8; bias_v[1]=32'sd0; bias_v[2]=-32'sd10; bias_v[3]=32'sd5;
        SC=16'sd181; SFT=6'd7; ALP=6'd4;
        bus_write(32'h08, 32'd0); bus_write(32'h34, bias_v[0]);
        bus_write(32'h08, 32'd1); bus_write(32'h34, bias_v[1]);
        bus_write(32'h08, 32'd2); bus_write(32'h34, bias_v[2]);
        bus_write(32'h08, 32'd3); bus_write(32'h34, bias_v[3]);
        bus_write(32'h38, {16'd0, SC});
        bus_write(32'h3C, {26'd0, SFT});
        bus_write(32'h50, {26'd0, ALP});
        bus_write(32'h30, 32'h7);               // VPU_CTRL: en|act|bias_en

        bus_write(32'h00, 32'h1);               // CTRL.start

        g=0; st=0;
        while (!st[0] && g<2000) begin bus_read(32'h04, st); g=g+1; end
        if (!st[0]) begin $display("  [FAIL] STATUS.done never asserted"); fail=fail+1; end

        for (i=0;i<4;i=i+1) bus_read(32'h20 + i*4, res[i]);
        for (i=0;i<4;i=i+1) bus_read(32'h40 + i*4, post_rd[i]);

        // ---- TEST 1: baked-weight matmul RES ----
        if ($signed(res[0])===EXP_RES0 && $signed(res[1])===EXP_RES1 &&
            $signed(res[2])===EXP_RES2 && $signed(res[3])===EXP_RES3) begin
            pass=pass+1;
            $display("  [pass] T1 baked matmul RES = %0d %0d %0d %0d (no weights loaded)",
                $signed(res[0]),$signed(res[1]),$signed(res[2]),$signed(res[3]));
        end else begin
            fail=fail+1;
            $display("  [FAIL] T1 RES = %0d %0d %0d %0d  expected 14 40 28 6",
                $signed(res[0]),$signed(res[1]),$signed(res[2]),$signed(res[3]));
        end

        // ---- TEST 2: VPU POST packs to the same mailbox value ----
        mbox = {post_rd[3][7:0], post_rd[2][7:0], post_rd[1][7:0], post_rd[0][7:0]};
        if (mbox === EXP_MBOX) begin
            pass=pass+1;
            $display("  [pass] T2 mailbox = 0x%08X (POST=%0d %0d %0d %0d)", mbox,
                $signed(post_rd[0][7:0]),$signed(post_rd[1][7:0]),
                $signed(post_rd[2][7:0]),$signed(post_rd[3][7:0]));
        end else begin
            fail=fail+1;
            $display("  [FAIL] T2 mailbox = 0x%08X  expected 0x%08X", mbox, EXP_MBOX);
        end

        $display("== RESULT: %0d passed, %0d failed ==", pass, fail);
        if (fail==0) $display("== M6.5.0 LUT-KCM sim: PASS ==");
        else         $display("== M6.5.0 LUT-KCM sim: FAIL ==");
        $finish;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end

endmodule
