// LUT-KCM 4x4 systolic array (M6.5) — drop-in replacement for
// systolic_array_4x4.v with the SAME port list, but the 16 weights are baked
// into the logic (lutkcm_pe constants) instead of being loaded over the bus.
//
// load_weight / w_row_sel / w_col_sel / w_data are kept on the port list for a
// zero-change drop-in into tpu_accel_kcm, but are IGNORED (weights are fixed in
// LUTs and only change via ICAP). Topology + timing match systolic_array_4x4
// exactly: x flows down columns, psum flows right along rows;
// result[r] = sum_c W[r][c] * x[c].
//
// Baked weight matrix W[row][col] = the M6.3 reference tile (tb_rm_tpuvpu T1):
//   row0: 1 1 1 1   row1: 1 2 3 4   row2: 2 2 2 2   row3: 1 0 1 0
// With X = {x3,x2,x1,x0} = 5,4,3,2 -> RES = 14,40,28,6 (then VPU -> 0x1019391F).

module lutkcm_array (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire        load_weight,   // ignored (weights baked in LUTs)
    input  wire [1:0]  w_row_sel,     // ignored
    input  wire [1:0]  w_col_sel,     // ignored
    input  wire signed [7:0] w_data,  // ignored
    input  wire [31:0] x_in,          // packed {x3,x2,x1,x0} signed[7:0]
    output wire [127:0] result        // packed {r3,r2,r1,r0} signed[31:0]
);
    // Baked weights, row-major: WPACK[(r*4+c)*8 +: 8] = W[r][c].
    // {r3c3,r3c2,r3c1,r3c0, r2.., r1.., r0c3,r0c2,r0c1,r0c0}
    localparam [127:0] WPACK = {
        8'd0, 8'd1, 8'd0, 8'd1,   // row3: c3..c0 = 0,1,0,1
        8'd2, 8'd2, 8'd2, 8'd2,   // row2
        8'd4, 8'd3, 8'd2, 8'd1,   // row1: c3..c0 = 4,3,2,1
        8'd1, 8'd1, 8'd1, 8'd1    // row0
    };

    // x[row][col]: row 0 = top input, rows 1..4 = PE pass-down.
    wire signed [7:0]  xw [0:4][0:3];
    // psum[row][col]: col 0 = left zero, cols 1..4 = PE outputs.
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
                lutkcm_pe #(.WEIGHT(WPACK[(r*4+c)*8 +: 8])) pe_i (
                    .clk(clk), .rst_n(rst_n), .en(en),
                    .x_in(xw[r][c]), .psum_in(pw[r][c]),
                    .x_out(xw[r+1][c]), .psum_out(pw[r][c+1])
                );
            end
        end
        for (r = 0; r < 4; r = r + 1) begin : g_res
            assign result[r*32 +: 32] = pw[r][4];
        end
    endgenerate

    // Silence unused-input lint (kept for drop-in compatibility).
    wire _unused = &{1'b0, load_weight, w_row_sel, w_col_sel, w_data};
endmodule
