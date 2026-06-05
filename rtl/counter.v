// Phase-1 Hello-PL: free-running 32-bit counter in PL.
// Driven by PS FCLK_CLK0; its value is exposed to the PS through an
// AXI-GPIO (input) so the ARM side can read an incrementing PL register
// over AXI -> proves the PS<->PL path and a self-made bitstream on the board.
module counter (
    input  wire        clk,
    input  wire        resetn,
    output reg  [31:0] cnt
);
    always @(posedge clk) begin
        if (!resetn) cnt <= 32'd0;
        else         cnt <= cnt + 32'd1;
    end
endmodule
