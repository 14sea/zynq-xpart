// Processing Element for weight-stationary systolic array
// - Weight is loaded and stays fixed
// - Activation (x) flows top-to-bottom
// - Partial sum flows left-to-right
// - psum_out = psum_in + weight * x_in
//
// Vivado port of rtl_src/neorv32_tpu/rtl/pe.v.
// Only change vs source: the DSP-mapping attribute.
//   Quartus:  (* multstyle = "dsp" *)        (Altera-specific)
//   Vivado:   (* use_dsp = "yes" *)          (XC7Z010 has 80 DSP48E1 — use them)
// Logic is otherwise identical and vendor-neutral.

module pe (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,           // compute enable
    input  wire        load_weight,  // load weight into register
    input  wire signed [7:0]  w_in,       // weight data input
    input  wire signed [7:0]  x_in,       // activation from above
    input  wire signed [31:0] psum_in,    // partial sum from left
    output reg  signed [7:0]  x_out,      // activation to below
    output reg  signed [31:0] psum_out    // partial sum to right
);

    reg signed [7:0] w_reg;

    // Force DSP48E1 for the 8x8 signed multiply.
    (* use_dsp = "yes" *) wire signed [15:0] product = w_reg * x_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_reg    <= 8'sd0;
            x_out    <= 8'sd0;
            psum_out <= 32'sd0;
        end else if (load_weight) begin
            w_reg <= w_in;
        end else if (en) begin
            x_out    <= x_in;
            psum_out <= psum_in + product;
        end
    end

endmodule
