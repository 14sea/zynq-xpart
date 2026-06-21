// M6.5 LUT-KCM fit-check (worst-case upper bound).
//
// Models the 4x4 multiply array of rm_lutkcm with the 16 PE multiplies moved
// OFF the DSP48E1s and into LUTs (use_dsp="no"), plus the 32-bit psum accumulate
// (which the DSP currently absorbs in its post-adder) also in LUTs.
//
// Weights are driven as a *variable* input bus so synth CANNOT constant-fold the
// multiplier -> this is the UPPER BOUND on LUT cost. The real rm_lutkcm bakes
// each weight as a (DONT_TOUCH) LUT-INIT constant, which is between a folded
// constant-KCM (small) and this full variable multiply (large). So:
//   if THIS fits the RP headroom, the ICAP-editable rm_lutkcm definitely fits.
//
// GATE: rm_lutkcm total must fit the RP pblock (~4400 LUT). wb_tpu_accel+VPU
// already cost ~2799 LUT, so the 4x4 array here must be <= ~1600 LUT.
//
// Same weight-stationary topology as systolic_array_4x4.v: x flows down columns,
// psum flows left->right along rows; result[r] = sum_c W[r][c]*x[c].

module m65_fit (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,
    input  wire [127:0] w_flat,   // 16 x signed[7:0] weights, {w[15],...,w[0]}
    input  wire [31:0]  x_in,     // packed {x3,x2,x1,x0} signed[7:0]
    output wire [127:0] result    // packed {r3,r2,r1,r0} signed[31:0]
);
    // x[row][col]: row 0 = top input, rows 1..4 = PE pass-down outputs
    wire signed [7:0]  xw [0:4][0:3];
    // psum[row][col]: col 0 = left zero, cols 1..4 = PE outputs
    wire signed [31:0] pw [0:3][0:4];

    genvar r, c;
    generate
        for (c = 0; c < 4; c = c + 1) begin : g_xin
            assign xw[0][c] = x_in[c*8 +: 8];
        end
        for (r = 0; r < 4; r = r + 1) begin : g_left
            assign pw[r][0] = 32'sd0;
        end
        for (r = 0; r < 4; r = r + 1) begin : g_row
            for (c = 0; c < 4; c = c + 1) begin : g_col
                wire signed [7:0]  w   = w_flat[(r*4+c)*8 +: 8];
                (* use_dsp = "no" *) wire signed [15:0] prod = w * xw[r][c];
                reg  signed [7:0]  xo;
                reg  signed [31:0] po;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        xo <= 8'sd0;
                        po <= 32'sd0;
                    end else if (en) begin
                        xo <= xw[r][c];
                        po <= pw[r][c] + prod;
                    end
                end
                assign xw[r+1][c] = xo;
                assign pw[r][c+1] = po;
            end
        end
        for (r = 0; r < 4; r = r + 1) begin : g_res
            assign result[r*32 +: 32] = pw[r][4];
        end
    endgenerate
endmodule
