// LUT-KCM Processing Element (M6.5): weight-stationary PE whose INT8 weight is a
// COMPILE-TIME CONSTANT held in editable LUT-INIT — "the model is the logic".
//
// vs the DSP PE (rtl/pe.v):
//   - no w_reg / load_weight path: WEIGHT is a parameter, not loaded at runtime.
//   - (* use_dsp = "no" *) forces the weight*activation multiply into LUTs
//     (KCM = constant-coefficient multiplier) instead of a DSP48E1.
//
// Editable-weight structure (M6.5.2): each of the 8 weight bits is held in its
// OWN LUT6 with all 6 inputs tied to 0, so its output = INIT[0] = WEIGHT[b].
// This is the M4/T2.2 single-physical-bit pattern: flipping one weight bit live
// is a ONE-bit, ONE-frame ICAP edit of that LUT's INIT[0] (located by prjxray
// controlled-diff, written by hwicap-uart.py) — no partial reload, no reset.
// (A plain `(* dont_touch *) wire = WEIGHT` instead became LUT1 *buffers* fed by
//  VCC/GND ties, whose 2-bit INIT replicates to 32 physical bits across 4 frames
//  — not a clean single-frame edit; hence the explicit LUT6-per-bit form here.)
//
// Pipeline structure is IDENTICAL to pe.v (one reg stage) so the systolic timing
// — and tpu_accel_kcm's skewed-injection + accumulate FSM — is byte-unchanged.
//
// `SIM` selects a behavioral weight (iverilog has no LUT6 primitive); Vivado
// (SIM undefined) instantiates the real editable LUT6 cells.

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
    wire signed [7:0] w_const;

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : g_wbit
`ifdef SIM
            assign w_const[b] = WEIGHT[b];
`else
            // Output = INIT[0] (all inputs 0). INIT[0] = WEIGHT[b]; the other 63
            // INIT bits are don't-care (kept 0). dont_touch so the bit survives
            // synth as a locatable, ICAP-editable LUT-INIT.
            (* dont_touch = "true" *)
            LUT6 #(.INIT(WEIGHT[b] ? 64'h0000_0000_0000_0001 : 64'h0)) wlut (
                .O(w_const[b]),
                .I0(1'b0), .I1(1'b0), .I2(1'b0), .I3(1'b0), .I4(1'b0), .I5(1'b0)
            );
`endif
        end
    endgenerate

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
