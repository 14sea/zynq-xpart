// vpu.v — 4-lane post-systolic Vector Processing Unit (M6.0)
//
// Per lane, applies the post-matmul element-wise ops that the RISC-V firmware
// used to do in software:  RES(INT32) -> [+bias] -> [Leaky ReLU] -> requant -> sat INT8.
//
// Leaky-ReLU + requant *algorithm* is referenced from tiny-tpu-v2/tiny-tpu
// (src/vpu.sv, leaky_relu, fixedpoint.sv), https://github.com/tiny-tpu-v2/tiny-tpu.
// NO tiny-tpu RTL is vendored — this is written from scratch to the bit-exact
// contract in docs/m6_plan.md. Verify tiny-tpu's license before copying any
// code/constants (see docs/m6_plan.md "Licensing / attribution").
//
// Bit-exact datapath order (the golden oracle MUST match every step):
//   1. acc = RES_n                                   (INT32)
//   2. if bias_en:  acc = acc + bias_n               (INT32, wrapping add, no saturate)
//   3. if act:      Leaky ReLU
//                     y = (acc >= 0) ? acc : acc - (acc >>> alpha)
//                     (arithmetic shift; negatives keep sign, reduced magnitude;
//                      slope = 1 - 2^-alpha, e.g. alpha=4 -> 0.9375)
//                   else passthrough (y = acc)
//   3b. saturate activation y to SIGNED 25-bit [-2^24, 2^24-1] (clamp, not wrap).
//       This bounds the requant multiplicand so the multiply maps to a single
//       DSP48E1 (25x18) -> 4 DSP for the VPU, 20 total with the 16 PE DSPs, i.e.
//       it fits the RP pblock's 20-DSP budget. Defined design limit: a 4x4 INT8
//       systolic result (|RES| <= ~64K per output group) plus a reasonable bias
//       never reaches +/-2^24 (~16.7M), so this is loss-free for the M6 INT8
//       forward-inference range; the clamp only bites on pathological inputs.
//   4. prod = y25(SIGNED 25) * scale(INT16)          (one DSP48E1, signed)
//   5. requant shift:
//        if shift>0:  prod = prod + (1 << (shift-1)) (round-half-up), prod >>>= shift
//        if shift==0: prod unchanged
//      (arithmetic shift, sign-preserving)
//   6. saturate to INT8 [-128,127] (clamp, not wrap) -> POST_n
//
// Timing: fixed 4-cycle pipeline.  `start` (1-cycle pulse) latches all inputs;
// `done` pulses one cycle when POST_out is valid.  The wrapper combines this
// `done` with the matmul's done so STATUS.done only asserts after POST settles.
// When `vpu_en` is low the wrapper bypasses this block entirely (legacy timing).

module vpu (
    input              clk,
    input              rst_n,

    input              start,        // 1-cycle pulse: latch inputs, begin pipeline
    input      [127:0] res_in,       // {RES3,RES2,RES1,RES0}, each signed INT32
    input      [127:0] bias_in,      // {BIAS3,..BIAS0},        each signed INT32

    input              bias_en,      // VPU_CTRL[2]
    input              act_en,       // VPU_CTRL[1] : 1=Leaky ReLU, 0=passthrough
    input      [15:0]  scale,        // VPU_SCALE (signed INT16 requant multiplier)
    input      [5:0]   shift,        // VPU_SHIFT (arithmetic right shift amount)
    input      [5:0]   alpha,        // VPU_ALPHA (Leaky-ReLU negative-slope shift k)

    output reg [31:0]  post_out,     // {POST3,..POST0}, each signed INT8
    output reg         done          // 1-cycle pulse: post_out valid
);

    // ── Stage-0: latch all inputs on start ───────────────────────────────────
    reg         vA;
    reg [127:0] res_l, bias_l;
    reg         bias_en_l, act_en_l;
    reg [15:0]  scale_l;
    reg [5:0]   shift_l, alpha_l;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vA <= 1'b0;
            res_l <= 128'd0; bias_l <= 128'd0;
            bias_en_l <= 1'b0; act_en_l <= 1'b0;
            scale_l <= 16'd0; shift_l <= 6'd0; alpha_l <= 6'd0;
        end else begin
            vA <= start;
            if (start) begin
                res_l     <= res_in;
                bias_l    <= bias_in;
                bias_en_l <= bias_en;
                act_en_l  <= act_en;
                scale_l   <= scale;
                shift_l   <= shift;
                alpha_l   <= alpha;
            end
        end
    end

    // ── Per-lane datapath (4 lanes) ──────────────────────────────────────────
    reg         v1, v2;
    reg  signed [24:0] leaky_r [0:3];   // stage-1 result (after bias + leaky + 25-bit sat)
    reg  signed [47:0] prod_r  [0:3];   // stage-2 result (after multiply)

    // 25-bit signed activation clamp bounds (keeps the requant mult to 1 DSP48E1)
    localparam signed [31:0] ACT_MAX =  32'sd16777215;   //  2^24 - 1
    localparam signed [31:0] ACT_MIN = -32'sd16777216;   // -2^24

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : LANE
            // -- stage 1: bias add (wrapping) + leaky ReLU + 25-bit saturate --
            wire signed [31:0] res_i  = res_l [32*i +: 32];
            wire signed [31:0] bias_i = bias_l[32*i +: 32];
            wire signed [31:0] biased = bias_en_l ? (res_i + bias_i) : res_i;
            wire signed [31:0] leaky  = (!act_en_l)     ? biased :
                                        (biased >= 0)   ? biased :
                                        (biased - (biased >>> alpha_l));
            wire signed [24:0] act25  = (leaky > ACT_MAX) ? 25'sh0FFFFFF :
                                        (leaky < ACT_MIN) ? 25'sh1000000 :
                                        leaky[24:0];

            // -- stage 2: single-DSP signed multiply (25 x 16) --
            (* use_dsp = "yes" *) wire signed [47:0] prod = leaky_r[i] * $signed(scale_l);

            // -- stage 3: round-half-up, arithmetic shift, saturate INT8 --
            wire signed [47:0] rnd = (shift_l != 6'd0)
                                     ? (prod_r[i] + (48'sd1 <<< (shift_l - 6'd1)))
                                     : prod_r[i];
            wire signed [47:0] sh  = rnd >>> shift_l;
            wire signed [7:0]  sat = (sh > 48'sd127)  ? 8'sd127  :
                                     (sh < -48'sd128) ? -8'sd128 :
                                     sh[7:0];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    leaky_r[i] <= 25'sd0;
                    prod_r[i]  <= 48'sd0;
                    post_out[8*i +: 8] <= 8'd0;
                end else begin
                    leaky_r[i] <= act25;        // s1 (bias+leaky, clamped to 25-bit)
                    prod_r[i]  <= prod;         // s2
                    post_out[8*i +: 8] <= sat;  // s3
                end
            end
        end
    endgenerate

    // ── valid / done pipeline (matches the 4-cycle datapath) ─────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; v2 <= 1'b0; done <= 1'b0;
        end else begin
            v1   <= vA;   // s1 valid
            v2   <= v1;   // s2 valid
            done <= v2;   // s3 valid -> post_out settled this cycle
        end
    end

endmodule
