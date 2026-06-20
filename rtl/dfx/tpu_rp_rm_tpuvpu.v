// DFX Reconfigurable Module: full-version accelerator = 4x4 INT8 TPU + VPU (M6).
//
// Same `tpu_rp` interface as RM1/RM2 — drops into the existing partition def
// with zero static-side change (neorv32_soc_dfx).  Internally it wraps the
// real wb_tpu_accel (matmul + legacy RES0-3) and the new 4-lane vpu.v
// (bias -> Leaky ReLU -> requant -> INT8), exposing POST0-3.
//
// Register map (byte offsets within the RP window):
//   --- legacy wb_tpu_accel (forwarded unchanged) ---
//   0x00 CTRL  0x04 STATUS  0x08 W_ADDR  0x0C W_DATA  0x10 X_IN  0x14 W_DATA4
//   0x20-0x2C RES0-3 (INT32, kept readable for parity)
//   --- VPU registers (claimed by this wrapper, NOT forwarded) ---
//   0x30 VPU_CTRL  W  [0]=vpu_en  [1]=act(0=passthrough,1=Leaky ReLU)  [2]=bias_en
//   0x34 VPU_BIAS  W  per-lane INT32 bias; lane = W_ADDR[1:0] (snooped from 0x08)
//   0x38 VPU_SCALE W  requant multiplier (signed INT16)
//   0x3C VPU_SHIFT W  requant arithmetic right shift amount
//   0x40-0x4C POST0-3 R  INT8 post-activation results (one per lane)
//   0x50 VPU_ALPHA W  Leaky-ReLU negative-slope shift k
//
// Note: 0x40-0x50 overlaps wb_tpu_accel's LUT window (0x040-0x43F).  In THIS
// RM the wrapper claims 0x30-0x50 for the VPU, so the LUT-load demo (mode_g)
// is unavailable here — that lives in the separate rm_lut RMs.  Forward-
// inference RM only.
//
// Flow (single firmware "start", per docs/m6_plan.md contract):
//   firmware loads weights/X_IN, sets VPU_CTRL/BIAS/SCALE/SHIFT/ALPHA, pulses
//   CTRL[0]=start.  The wrapper snoops that start; when the matmul finishes it
//   auto-latches RES0-3 and fires the VPU.  STATUS.done only asserts after the
//   VPU pipeline drains (matmul + VPU latency), so firmware polls STATUS.done
//   then reads POST0-3.  When VPU_CTRL[0]=0 the VPU is bypassed and STATUS.done
//   keeps the legacy matmul-only timing.

module tpu_rp (
    input         clk,
    input         rst_n,
    input  [31:0] xbus_adr,
    input  [31:0] xbus_dat_w,
    input  [3:0]  xbus_sel,
    input         xbus_we,
    input         xbus_stb,
    input         xbus_cyc,
    output [31:0] xbus_dat_r,
    output        xbus_ack,
    output        xbus_err,
    output [3:0]  dbg_leds
);
    wire [11:0] off = xbus_adr[11:0];

    // VPU register window claimed by the wrapper (not seen by the accel).
    wire claim = (off >= 12'h030) && (off <= 12'h050);
    wire wr    = xbus_cyc && xbus_stb && xbus_we && (xbus_sel != 4'b0000);

    // ── wb_tpu_accel : matmul + legacy regs (forwarded cycles only) ──────────
    wire [31:0] acc_dat_r;
    wire        acc_ack;
    wire [3:0]  acc_leds;
    wire [31:0] res0, res1, res2, res3;
    wire        mm_done;

    wb_tpu_accel u_accel (
        .clk        (clk),
        .rst_n      (rst_n),
        .xbus_adr   (xbus_adr),
        .xbus_dat_w (xbus_dat_w),
        .xbus_sel   (xbus_sel),
        .xbus_we    (xbus_we),
        .xbus_stb   (xbus_stb && !claim),   // VPU window not forwarded
        .xbus_cyc   (xbus_cyc && !claim),
        .xbus_dat_r (acc_dat_r),
        .xbus_ack   (acc_ack),
        .xbus_err   (),
        .dbg_leds   (acc_leds),
        .res0_o     (res0),
        .res1_o     (res1),
        .res2_o     (res2),
        .res3_o     (res3),
        .mm_done_o  (mm_done)
    );

    // ── VPU config registers (written via the claimed window / snooped) ──────
    reg        vpu_en, vpu_act, vpu_bias_en;
    reg [15:0] vpu_scale;
    reg [5:0]  vpu_shift, vpu_alpha;
    reg [31:0] bias [0:3];
    reg [1:0]  vpu_lane;        // snooped from W_ADDR (0x08) low bits

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpu_en <= 1'b0; vpu_act <= 1'b0; vpu_bias_en <= 1'b0;
            vpu_scale <= 16'd0; vpu_shift <= 6'd0; vpu_alpha <= 6'd0;
            bias[0] <= 32'd0; bias[1] <= 32'd0; bias[2] <= 32'd0; bias[3] <= 32'd0;
            vpu_lane <= 2'd0;
        end else if (wr) begin
            case (off)
                12'h008: vpu_lane    <= xbus_dat_w[1:0];   // snoop W_ADDR for bias lane
                12'h030: {vpu_bias_en, vpu_act, vpu_en} <= xbus_dat_w[2:0];
                12'h034: bias[vpu_lane] <= xbus_dat_w;
                12'h038: vpu_scale   <= xbus_dat_w[15:0];
                12'h03C: vpu_shift   <= xbus_dat_w[5:0];
                12'h050: vpu_alpha   <= xbus_dat_w[5:0];
                default: ;
            endcase
        end
    end

    // ── VPU instance ─────────────────────────────────────────────────────────
    reg         vpu_start;
    reg [127:0] vpu_res;
    wire [31:0] post;
    wire        vpu_done;

    vpu u_vpu (
        .clk(clk), .rst_n(rst_n),
        .start(vpu_start),
        .res_in(vpu_res),
        .bias_in({bias[3], bias[2], bias[1], bias[0]}),
        .bias_en(vpu_bias_en), .act_en(vpu_act),
        .scale(vpu_scale), .shift(vpu_shift), .alpha(vpu_alpha),
        .post_out(post), .done(vpu_done)
    );

    // ── Sequencer: start -> matmul-done -> fire VPU -> done ───────────────────
    reg armed;       // a vpu-enabled compute is pending matmul completion
    reg mm_done_d;
    reg done_vpu;    // STATUS.done shown when vpu_en

    wire ctrl_start = wr && (off == 12'h000) && xbus_dat_w[0];
    wire ctrl_clear = wr && (off == 12'h000) && xbus_dat_w[4];
    wire mm_done_rise = mm_done && !mm_done_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed <= 1'b0; mm_done_d <= 1'b0; done_vpu <= 1'b0; vpu_start <= 1'b0;
            vpu_res <= 128'd0;
        end else begin
            mm_done_d <= mm_done;
            vpu_start <= 1'b0;

            if (ctrl_start && vpu_en) begin
                armed    <= 1'b1;
                done_vpu <= 1'b0;
            end
            if (ctrl_clear) done_vpu <= 1'b0;

            if (armed && mm_done_rise) begin
                vpu_res   <= {res3, res2, res1, res0};
                vpu_start <= 1'b1;
                armed     <= 1'b0;
            end

            if (vpu_done) done_vpu <= 1'b1;
        end
    end

    // ── Local ack for the claimed VPU window (1-cycle, mirror accel latency) ──
    reg local_ack;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)  local_ack <= 1'b0;
        else         local_ack <= xbus_cyc && xbus_stb && claim && !local_ack;

    // POST readback for 0x40-0x4C
    reg [31:0] claim_dat;
    always @(*) begin
        case (off)
            12'h040: claim_dat = {{24{post[7]}},  post[7:0]};
            12'h044: claim_dat = {{24{post[15]}}, post[15:8]};
            12'h048: claim_dat = {{24{post[23]}}, post[23:16]};
            12'h04C: claim_dat = {{24{post[31]}}, post[31:24]};
            default: claim_dat = 32'd0;          // VPU_CTRL/BIAS/SCALE/SHIFT/ALPHA read as 0
        endcase
    end

    // ── Bus response mux ─────────────────────────────────────────────────────
    // STATUS (0x04) read: when VPU enabled, override done bit with done_vpu so
    // the firmware sees "done" only after the VPU has drained; keep accel's
    // lut_busy (bit1).  Otherwise pass the accel response straight through.
    wire status_read = !claim && (off == 12'h004) && !xbus_we;
    wire [31:0] status_dat = {acc_dat_r[31:1], done_vpu};

    assign xbus_ack  = claim ? local_ack : acc_ack;
    assign xbus_dat_r = claim       ? claim_dat :
                        (status_read && vpu_en) ? status_dat :
                        acc_dat_r;
    assign xbus_err  = 1'b0;

    // Distinct-ish LEDs: top bit = vpu done, rest = accel debug.
    assign dbg_leds  = {done_vpu, acc_leds[2:0]};

endmodule
