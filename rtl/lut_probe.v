// T2.2 observable LUT probe for the HWICAP single-frame write proof.
// A single DONT_TOUCH LUT6 with all inputs tied to 0, so O = INIT[0].
// O is surfaced on bit 0 of a 32-bit bus that feeds an AXI-GPIO input, so the PS
// can read the LUT truth-table output. Flipping INIT[0] in CRAM (live, via HWICAP)
// flips this readable bit -- the visible proof that an ICAP frame write landed.
module lut_probe(output [31:0] q);
    wire o;
    (* DONT_TOUCH = "TRUE" *)
    LUT6 #(.INIT(64'h0000000000000000)) l_probe (
        .O(o), .I0(1'b0), .I1(1'b0), .I2(1'b0), .I3(1'b0), .I4(1'b0), .I5(1'b0));
    assign q = {31'b0, o};
endmodule
