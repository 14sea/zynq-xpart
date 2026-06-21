// train_unit.v — M7.2 on-chip TRAINING unit: the tiny-tpu "trio" in hardware.
//
// Implements, bit-exactly to sim/oracle_train.py (the golden), the three pieces
// the M7.0/M7.1 firmware did in NEORV32 software:
//   (1) MSE loss  : LOSS += qmul(err0, err0),  err = clamp(y - t)
//   (2) leaky' + δ: δ = clamp(qmul(·, leaky'(z)))  for the output (d2) and hidden (d1) layers
//   (3) SGD update: master ← sat16(master − (grad >>ₐ LR))  on a small master register file
// The master weights of the 2-4-1 XOR net live HERE (17 Q8.8 values), in registers.
//
// SCOPE (M7.2, user-confirmed): the trio + master update are in HW; the forward
// requant+bias+leaky stays in NEORV32 SW (unchanged from M7.1, no regression), and
// the rank-1 outer products dW = δ⊗xᵀ stay a 16-MAC NEORV32 sequence (the gradient
// banks DW0-7 are written by firmware; this unit only applies them). The two matmuls
// (forward W·x, backward Wᵀ·δ) stay on the 4×4 INT8 systolic array (M7.1).
//
// Fixed-point contract (must match m7_kernel.h / oracle_train.py EXACTLY):
//   FRAC=8 (Q8.8), qmul(a,b) = (a*b + 128) >>>ₐ 8     (round-half-up, arith shift)
//   leaky'(z)  = (z>=0) ? 256(=1.0) : 256>>>k         (k = LEAKY shift, =2)
//   err clamp  = ±(1<<20),  δ clamp = ±(1<<14),  master sat = INT16 [-32768,32767]
//   SGD shift  = arithmetic right shift by LR  (power-of-two lr, no divider)
//
// MSE-loss / leaky-derivative / SGD-update *algorithm* referenced from
// tiny-tpu-v2/tiny-tpu src/{loss,leaky_relu,gradient_descent}.sv (reference only,
// no RTL vendored — verify license before copying any code/constants).
//
// Simple synchronous register interface (the DFX wrapper maps XBUS onto it; the
// testbench drives it directly).  Writing the CMD register triggers an op the same
// cycle; results land in the D2/D1/LOSS/master registers and are read back combinationally.

module train_unit (
    input              clk,
    input              rst_n,

    input  [5:0]       lr,        // LR_SHIFT (arithmetic right shift for SGD), =4
    input  [5:0]       k,         // leaky-ReLU negative-slope shift, =2

    // register-file access (word-addressed)
    input              we,
    input  [6:0]       addr,      // see map below
    input  signed [31:0] wdata,
    output reg signed [31:0] rdata
);
    // ── word-address map ─────────────────────────────────────────────────────
    //  0.. 3  INA0-3  (W)  generic 4-lane input: y (for loss/d2) or w2td2 (for d1)
    //  4.. 7  Z0-3    (W)  z of the layer whose leaky' we gate by: z2 (d2) or z1 (d1)
    //  8..11  T0-3    (W)  per-lane target t (loss/d2; only lane0 is nonzero for XOR)
    // 12..19  DW0-7   (W)  SW-computed outer-product gradient bank (dW2:[0..3], dW1:[0..7])
    // 20      CMD     (W)  [0]=loss_d2  [1]=d1  [2]=upd_l2  [3]=upd_l1  [4]=clr_loss
    // 32..39  W1m0-7  (R/W) master W1[i][j], layout n=i*2+j  (cols 2,3 ≡ 0, not stored)
    // 40..43  b1m0-3  (R/W) master b1[i]
    // 44..47  W2m0-3  (R/W) master W2 row0[j]   (rows 1..3 ≡ 0, not stored)
    // 48      b2m     (R/W) master b2[0]        (lanes 1..3 ≡ 0, not stored)
    // 52..55  D2_0-3  (R)   output-layer δ (after loss_d2)
    // 56..59  D1_0-3  (R)   hidden-layer δ (after d1)
    // 60      LOSS_LO (R)   accumulated SSE (low 32)
    // 61      LOSS_HI (R)   accumulated SSE (high 32)
    localparam A_CMD     = 7'd20;
    localparam A_M_BASE  = 7'd32;   // 32..48 master window

    // ── state ────────────────────────────────────────────────────────────────
    reg signed [31:0] ina  [0:3];
    reg signed [31:0] zin  [0:3];
    reg signed [31:0] tin  [0:3];
    reg signed [31:0] dw   [0:7];
    reg signed [31:0] w1m  [0:7];
    reg signed [31:0] b1m  [0:3];
    reg signed [31:0] w2m  [0:3];
    reg signed [31:0] b2m;
    reg signed [31:0] d2r  [0:3];
    reg signed [31:0] d1r  [0:3];
    reg signed [31:0] loss;   // per-epoch SSE; small for XOR, fits 32-bit (saves a 64-bit adder)

    integer i;

    // ── fixed-point primitives (bit-exact to the oracle) ─────────────────────
    // 32-bit-wide (all operands fit: err ≤ ±2^20, δ ≤ ±2^14, master ≤ ±2^15).
    function signed [31:0] sat16(input signed [31:0] v);
        sat16 = (v > 32'sd32767)  ? 32'sd32767  :
                (v < -32'sd32768) ? -32'sd32768 : v;
    endfunction
    function signed [31:0] clampd(input signed [31:0] v);        // ±(1<<14)
        clampd = (v > 32'sd16383)  ? 32'sd16383  :
                 (v < -32'sd16384) ? -32'sd16384 : v;
    endfunction
    function signed [31:0] clamperr(input signed [31:0] v);      // ±(1<<20)
        clamperr = (v > 32'sd1048575)  ? 32'sd1048575  :
                   (v < -32'sd1048576) ? -32'sd1048576 : v;
    endfunction
    // leaky' applied to x, gated by the sign of z. Because the leaky negative slope
    // is a power of two (2^-k), qmul(x, leaky'(z)) ≡ x (z>=0) or round(x / 2^k) — a
    // rounding right SHIFT, NOT a multiply. This keeps train_unit off the scarce DSP
    // column (the 4x4 array already uses 16 of the pblock's 20 DSP48E1). Bit-exact to
    // the oracle: (z<0) → (x*(256>>k)+128)>>8 == (x + 2^(k-1)) >>>ₐ k.
    function signed [31:0] leaky_apply(input signed [31:0] x, input signed [31:0] z);
        leaky_apply = (z >= 0) ? x : ((x + (32'sd1 <<< (k - 6'd1))) >>> k);
    endfunction
    // MSE term round(err^2 / 256). err is clamped to ±2^20 so it fits 22-bit signed —
    // the ONLY multiplier in train_unit (a 22x22 signed multiply, ≤2 DSP48E1).
    function signed [31:0] qmul_sq(input signed [21:0] a);
        reg signed [43:0] p;
        begin p = a * a; qmul_sq = (p + 44'sd128) >>> 8; end       // round-half-up, arith
    endfunction

    // ── write / command engine ───────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                ina[i] <= 0; zin[i] <= 0; tin[i] <= 0;
                d2r[i] <= 0; d1r[i] <= 0; b1m[i] <= 0; w2m[i] <= 0;
            end
            for (i = 0; i < 8; i = i + 1) begin dw[i] <= 0; w1m[i] <= 0; end
            b2m <= 0; loss <= 0;
        end else if (we) begin
            // operand / master writes
            if (addr <= 7'd3)                       ina[addr[1:0]]        <= wdata;
            else if (addr >= 7'd4  && addr <= 7'd7) zin[addr[1:0]]        <= wdata;
            else if (addr >= 7'd8  && addr <= 7'd11) tin[addr[1:0]]       <= wdata;
            else if (addr >= 7'd12 && addr <= 7'd19) dw[addr - 7'd12]     <= wdata;
            else if (addr >= 7'd32 && addr <= 7'd39) w1m[addr - 7'd32]    <= wdata;
            else if (addr >= 7'd40 && addr <= 7'd43) b1m[addr - 7'd40]    <= wdata;
            else if (addr >= 7'd44 && addr <= 7'd47) w2m[addr - 7'd44]    <= wdata;
            else if (addr == 7'd48)                  b2m                  <= wdata;

            // command: execute the op this cycle
            if (addr == A_CMD) begin
                // (1)+(2) output layer: err = clamp(y - t), LOSS += qmul(err0,err0),
                //         d2 = clamp(qmul(err, leaky'(z2)))
                if (wdata[0]) begin
                    loss <= loss + qmul_sq(clamperr($signed(ina[0]) - $signed(tin[0])));
                    for (i = 0; i < 4; i = i + 1)
                        d2r[i] <= clampd(leaky_apply(clamperr($signed(ina[i]) - $signed(tin[i])),
                                                     zin[i]));
                end
                // (2) hidden layer: d1 = clamp(qmul(w2td2, leaky'(z1)))
                if (wdata[1]) begin
                    for (i = 0; i < 4; i = i + 1)
                        d1r[i] <= clampd(leaky_apply($signed(ina[i]), zin[i]));
                end
                // (3) SGD update, output layer: W2 ← sat(W2 − dW2>>ₐLR), b2 ← sat(b2 − d2[0]>>ₐLR)
                if (wdata[2]) begin
                    for (i = 0; i < 4; i = i + 1)
                        w2m[i] <= sat16($signed(w2m[i]) - ($signed(dw[i]) >>> lr));
                    b2m <= sat16($signed(b2m) - ($signed(d2r[0]) >>> lr));
                end
                // (3) SGD update, hidden layer: W1 ← sat(W1 − dW1>>ₐLR), b1 ← sat(b1 − d1>>ₐLR)
                if (wdata[3]) begin
                    for (i = 0; i < 8; i = i + 1)
                        w1m[i] <= sat16($signed(w1m[i]) - ($signed(dw[i]) >>> lr));
                    for (i = 0; i < 4; i = i + 1)
                        b1m[i] <= sat16($signed(b1m[i]) - ($signed(d1r[i]) >>> lr));
                end
                // clear the loss accumulator (epoch boundary). Exclusive of the above
                // in firmware; placed last so a stray combined write still clears.
                if (wdata[4]) loss <= 0;
            end
        end
    end

    // ── read mux ──────────────────────────────────────────────────────────────
    always @(*) begin
        if      (addr >= 7'd32 && addr <= 7'd39) rdata = w1m[addr - 7'd32];
        else if (addr >= 7'd40 && addr <= 7'd43) rdata = b1m[addr - 7'd40];
        else if (addr >= 7'd44 && addr <= 7'd47) rdata = w2m[addr - 7'd44];
        else if (addr == 7'd48)                  rdata = b2m;
        else if (addr >= 7'd52 && addr <= 7'd55) rdata = d2r[addr - 7'd52];
        else if (addr >= 7'd56 && addr <= 7'd59) rdata = d1r[addr - 7'd56];
        else if (addr == 7'd60)                  rdata = loss;       // 32-bit SSE
        else                                     rdata = 32'd0;
    end

endmodule
