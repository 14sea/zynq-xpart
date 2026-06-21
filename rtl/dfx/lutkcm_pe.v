// LUT-KCM Processing Element (M6.5): weight-stationary PE whose weight is a
// COMPILE-TIME CONSTANT baked into LUT logic — "the model is the logic".
//
// vs the DSP PE (rtl/pe.v):
//   - no w_reg / load_weight path: WEIGHT is a parameter, not loaded at runtime.
//   - (* use_dsp = "no" *) forces the weight*activation multiply into LUTs
//     (KCM = constant-coefficient multiplier) instead of a DSP48E1.
//   - (* dont_touch *) on the weight constant keeps it as a locatable LUT-INIT
//     so M6.5.2 can ICAP-edit a weight live (prjxray controlled-diff +
//     lut-surgery / hwicap-uart), no partial reload, no reset.
//
// Pipeline structure is IDENTICAL to pe.v (one reg stage: x_out = reg(x_in),
// psum_out = reg(psum_in + WEIGHT*x_in)) so the systolic timing — and thus
// tpu_accel's skewed-injection + accumulate FSM — is byte-for-byte unchanged.

module lutkcm_pe #(
    parameter signed [7:0] WEIGHT = 8'sd0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire signed [7:0]  x_in,
    input  wire signed [31:0] psum_in,
    output reg  signed [7:0]  x_out,
    output reg  signed [31:0] psum_out
);
    // Weight held as a DONT_TOUCH constant so its LUT-INIT bits survive synth
    // (not folded into routing) and are locatable for live ICAP edit.
    (* dont_touch = "true" *) wire signed [7:0] w_const = WEIGHT;

    // KCM multiply in LUTs (no DSP).
    (* use_dsp = "no" *) wire signed [15:0] product = w_const * x_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_out    <= 8'sd0;
            psum_out <= 32'sd0;
        end else if (en) begin
            x_out    <= x_in;
            psum_out <= psum_in + product;
        end
    end
endmodule
