// tpu_accel_kcm.v (M6.5) — self-contained copy of rtl/tpu_accel.v for the
// LUT-KCM reconfigurable module. IDENTICAL to tpu_accel.v except:
//   - module renamed tpu_accel -> tpu_accel_kcm
//   - the systolic array instance is lutkcm_array (baked-weight KCM) instead of
//     systolic_array_4x4 (DSP, runtime-loaded weights).
// Kept self-contained (own copy) so the rm_lutkcm DFX fileset never shares
// submodules with rm1/rm_tpuvpu (avoids the M6.1 -define_from fileset move).
//
// The weight-load path (W_ADDR/W_DATA/W_DATA4/CTRL[8] LUT-load FSM) and the LUT
// BRAM are retained verbatim so timing + the accumulate FSM are byte-identical,
// but lutkcm_array ignores load_weight — writes to the weight regs are inert.

module tpu_accel_kcm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sel,
    input  wire [11:0] addr,
    input  wire [31:0] wdata,
    input  wire [ 3:0] wstrb,
    output reg  [31:0] rdata,
    output reg         ready,
    output wire [3:0]  debug_led,
    output wire [31:0] res0_o,
    output wire [31:0] res1_o,
    output wire [31:0] res2_o,
    output wire [31:0] res3_o,
    output wire        mm_done_o
);

    wire [9:0] word_addr = addr[11:2];
    wire       in_systolic = (word_addr[9:4] == 6'h00);
    wire       in_lut      = (word_addr >= 10'h010) && (word_addr <= 10'h10F);
    wire [9:0] lut_off10   = word_addr - 10'h010;
    wire [7:0] lut_idx     = lut_off10[7:0];

    reg         sa_en;
    reg         sa_load_weight;
    reg  [1:0]  sa_w_row_sel;
    reg  [1:0]  sa_w_col_sel;
    reg  signed [7:0] sa_w_data;
    reg  [31:0] sa_x_in;
    wire [127:0] sa_result;

    // M6.5: baked-weight KCM array (drop-in, same ports as systolic_array_4x4).
    lutkcm_array sa_inst (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (sa_en),
        .load_weight(sa_load_weight),
        .w_row_sel  (sa_w_row_sel),
        .w_col_sel  (sa_w_col_sel),
        .w_data     (sa_w_data),
        .x_in       (sa_x_in),
        .result     (sa_result)
    );

    wire signed [31:0] sa_res [0:3];
    assign sa_res[0] = sa_result[ 31:  0];
    assign sa_res[1] = sa_result[ 63: 32];
    assign sa_res[2] = sa_result[ 95: 64];
    assign sa_res[3] = sa_result[127: 96];

    reg [31:0] x_in_reg;
    reg [1:0]  w_addr_row;
    reg [1:0]  w_addr_col;

    reg signed [31:0] acc [0:3];

    reg        bulk_active;
    reg [1:0]  bulk_phase;
    reg [31:0] bulk_data;
    reg [1:0]  bulk_row;

    reg        lut_load_active;
    reg [4:0]  lut_load_idx;
    reg        lut_load_phase;

    reg [3:0] compute_cnt;
    reg       done;

    wire computing = (compute_cnt != 4'd0);

    always @(*) begin
        case (compute_cnt)
            4'd1: sa_x_in = {24'd0, x_in_reg[7:0]};
            4'd2: sa_x_in = {16'd0, x_in_reg[15:8], 8'd0};
            4'd3: sa_x_in = {8'd0, x_in_reg[23:16], 16'd0};
            4'd4: sa_x_in = {x_in_reg[31:24], 24'd0};
            default: sa_x_in = 32'd0;
        endcase
    end

    always @(*) begin
        sa_en = computing;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            compute_cnt <= 4'd0;
            done <= 1'b0;
            acc[0] <= 32'sd0;
            acc[1] <= 32'sd0;
            acc[2] <= 32'sd0;
            acc[3] <= 32'sd0;
            bulk_active <= 1'b0;
            bulk_phase <= 2'd0;
            bulk_data <= 32'd0;
            bulk_row <= 2'd0;
            sa_load_weight <= 1'b0;
            w_addr_row <= 2'd0;
            w_addr_col <= 2'd0;
            lut_load_active <= 1'b0;
            lut_load_idx <= 5'd0;
            lut_load_phase <= 1'b0;
        end else begin
            if (sa_load_weight && !bulk_active && !lut_load_active)
                sa_load_weight <= 1'b0;

            if (computing) begin
                if (compute_cnt == 4'd9) begin
                    compute_cnt <= 4'd0;
                    done <= 1'b1;
                end else begin
                    compute_cnt <= compute_cnt + 4'd1;
                end

                if (compute_cnt == 4'd5) acc[0] <= acc[0] + sa_res[0];
                if (compute_cnt == 4'd6) acc[1] <= acc[1] + sa_res[1];
                if (compute_cnt == 4'd7) acc[2] <= acc[2] + sa_res[2];
                if (compute_cnt == 4'd8) acc[3] <= acc[3] + sa_res[3];
            end

            if (bulk_active) begin
                case (bulk_phase)
                    2'd0: begin
                        sa_w_data <= bulk_data[15:8];
                        sa_w_col_sel <= 2'd1;
                        sa_w_row_sel <= bulk_row;
                        sa_load_weight <= 1'b1;
                        bulk_phase <= 2'd1;
                    end
                    2'd1: begin
                        sa_w_data <= bulk_data[23:16];
                        sa_w_col_sel <= 2'd2;
                        sa_w_row_sel <= bulk_row;
                        sa_load_weight <= 1'b1;
                        bulk_phase <= 2'd2;
                    end
                    2'd2: begin
                        sa_w_data <= bulk_data[31:24];
                        sa_w_col_sel <= 2'd3;
                        sa_w_row_sel <= bulk_row;
                        sa_load_weight <= 1'b1;
                        bulk_active <= 1'b0;
                        w_addr_row <= bulk_row + 2'd1;
                    end
                    default: bulk_active <= 1'b0;
                endcase
            end else begin
                if (sa_load_weight && !lut_load_active)
                    sa_load_weight <= 1'b0;
            end

            if (lut_load_active) begin
                if (lut_load_phase == 1'b0) begin
                    lut_load_phase <= 1'b1;
                end else begin
                    sa_w_data    <= lut_rdata_r[23:16];
                    sa_w_col_sel <= lut_load_idx[1:0];
                    sa_w_row_sel <= lut_load_idx[3:2];
                    sa_load_weight <= 1'b1;
                    if (lut_load_idx == 5'd15) begin
                        lut_load_active <= 1'b0;
                    end else begin
                        lut_load_idx <= lut_load_idx + 5'd1;
                        lut_load_phase <= 1'b0;
                    end
                end
            end

            if (sel && (wstrb != 4'b0000) && !bulk_active && !lut_load_active && in_systolic) begin
                case (addr[5:2])
                    4'h0: begin // CTRL
                        if (wdata[0] && !computing) begin
                            compute_cnt <= 4'd1;
                            done <= 1'b0;
                        end
                        if (wdata[4]) begin
                            acc[0] <= 32'sd0;
                            acc[1] <= 32'sd0;
                            acc[2] <= 32'sd0;
                            acc[3] <= 32'sd0;
                            done <= 1'b0;
                        end
                        if (wdata[8] && !computing) begin
                            lut_load_active <= 1'b1;
                            lut_load_idx <= 5'd0;
                            lut_load_phase <= 1'b0;
                        end
                    end
                    4'h2: begin // W_ADDR
                        w_addr_col <= wdata[1:0];
                        w_addr_row <= wdata[3:2];
                    end
                    4'h3: begin // W_DATA
                        sa_w_data <= wdata[7:0];
                        sa_w_row_sel <= w_addr_row;
                        sa_w_col_sel <= w_addr_col;
                        sa_load_weight <= 1'b1;
                    end
                    4'h4: begin // X_IN
                        x_in_reg <= wdata;
                    end
                    4'h5: begin // W_DATA4
                        sa_w_data <= wdata[7:0];
                        sa_w_col_sel <= 2'd0;
                        sa_w_row_sel <= w_addr_row;
                        sa_load_weight <= 1'b1;
                        bulk_data <= wdata;
                        bulk_row <= w_addr_row;
                        bulk_phase <= 2'd0;
                        bulk_active <= 1'b1;
                    end
                endcase
            end
        end
    end

    reg [31:0] lut_mem [0:255];
    reg [31:0] lut_rdata_r;
    wire [7:0] lut_rd_addr_mux = lut_load_active ? {4'd0, lut_load_idx[3:0]}
                                                  : lut_idx;

    always @(posedge clk) begin
        if (sel && (wstrb != 4'b0000) && in_lut && !bulk_active && !lut_load_active) begin
            lut_mem[lut_idx] <= wdata;
        end
        lut_rdata_r <= lut_mem[lut_rd_addr_mux];
    end

    always @(*) begin
        if (in_lut) begin
            rdata = lut_rdata_r;
        end else begin
            case (addr[5:2])
                4'h1:    rdata = {30'd0, lut_load_active, done};
                4'h8:    rdata = acc[0];
                4'h9:    rdata = acc[1];
                4'hA:    rdata = acc[2];
                4'hB:    rdata = acc[3];
                default: rdata = 32'd0;
            endcase
        end
    end

    reg ready_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) ready_r <= 1'b0;
        else        ready_r <= sel && !ready_r && !bulk_active;

    always @(*) ready = ready_r;

    assign debug_led = {done, computing, 2'b00};

    assign res0_o    = acc[0];
    assign res1_o    = acc[1];
    assign res2_o    = acc[2];
    assign res3_o    = acc[3];
    assign mm_done_o = done;

endmodule
