// DFX Reconfigurable Module: LUT-KCM accelerator = 4x4 baked-weight TPU + VPU
// (M6.5). Same `tpu_rp` interface as rm_tpuvpu/rm_rot — drops into the existing
// partition def with zero static-side change.
//
// This is rm_tpuvpu with the matmul array's weights moved OFF runtime-loadable
// DSP PEs and INTO the logic (LUT-KCM, see lutkcm_pe.v): "the chip's logic IS
// the model". The 16 INT8 weights are baked LUT-INIT constants; a model swap is
// a live ICAP edit of those LUTs (M6.5.2) — no partial reload, no reset.
//
// Functionally identical to rm_tpuvpu for the M6.3 reference tile: the baked
// weights == that tile's weights, so with X={5,4,3,2} and the same VPU params
// the mailbox reads the same 0x1019391F. The firmware's weight writes (W_DATA4)
// are inert here (the array ignores load_weight) — proving the weights live in
// the fabric, not in registers.
//
// Register map: same as tpu_rp_rm_tpuvpu.v (legacy wb regs 0x00-0x2C + VPU regs
// 0x30-0x50, POST0-3 at 0x40-0x4C).

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

    wire claim = (off >= 12'h030) && (off <= 12'h050);
    wire wr    = xbus_cyc && xbus_stb && xbus_we && (xbus_sel != 4'b0000);

    // ── KCM accel : baked-weight matmul + legacy regs (forwarded cycles) ──────
    wire [31:0] acc_dat_r;
    wire        acc_ack;
    wire [3:0]  acc_leds;
    wire [31:0] res0, res1, res2, res3;
    wire        mm_done;

    wb_tpu_accel_kcm u_accel (
        .clk        (clk),
        .rst_n      (rst_n),
        .xbus_adr   (xbus_adr),
        .xbus_dat_w (xbus_dat_w),
        .xbus_sel   (xbus_sel),
        .xbus_we    (xbus_we),
        .xbus_stb   (xbus_stb && !claim),
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
    reg [1:0]  vpu_lane;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpu_en <= 1'b0; vpu_act <= 1'b0; vpu_bias_en <= 1'b0;
            vpu_scale <= 16'd0; vpu_shift <= 6'd0; vpu_alpha <= 6'd0;
            bias[0] <= 32'd0; bias[1] <= 32'd0; bias[2] <= 32'd0; bias[3] <= 32'd0;
            vpu_lane <= 2'd0;
        end else if (wr) begin
            case (off)
                12'h008: vpu_lane    <= xbus_dat_w[1:0];
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
    reg armed;
    reg mm_done_d;
    reg done_vpu;

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

    // ── Local ack for the claimed VPU window ──────────────────────────────────
    reg local_ack;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)  local_ack <= 1'b0;
        else         local_ack <= xbus_cyc && xbus_stb && claim && !local_ack;

    reg [31:0] claim_dat;
    always @(*) begin
        case (off)
            12'h040: claim_dat = {{24{post[7]}},  post[7:0]};
            12'h044: claim_dat = {{24{post[15]}}, post[15:8]};
            12'h048: claim_dat = {{24{post[23]}}, post[23:16]};
            12'h04C: claim_dat = {{24{post[31]}}, post[31:24]};
            default: claim_dat = 32'd0;
        endcase
    end

    wire status_read = !claim && (off == 12'h004) && !xbus_we;
    wire [31:0] status_dat = {acc_dat_r[31:1], done_vpu};

    assign xbus_ack  = claim ? local_ack : acc_ack;
    assign xbus_dat_r = claim       ? claim_dat :
                        (status_read && vpu_en) ? status_dat :
                        acc_dat_r;
    assign xbus_err  = 1'b0;

    // Distinct LED pattern marks the KCM RM (vs rm_tpuvpu / rm_rot).
    assign dbg_leds  = {done_vpu, 1'b1, acc_leds[1:0]};

endmodule
