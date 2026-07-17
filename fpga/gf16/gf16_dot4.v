module gf16_dot4 (
    input  wire [15:0] a0,
    input  wire [15:0] a1,
    input  wire [15:0] a2,
    input  wire [15:0] a3,
    input  wire [15:0] b0,
    input  wire [15:0] b1,
    input  wire [15:0] b2,
    input  wire [15:0] b3,
    output wire [15:0] result
);

    wire [15:0] p0, p1, p2, p3;
    wire [15:0] s01, s23;

    gf16_mul m0 (.a(a0), .b(b0), .result(p0));
    gf16_mul m1 (.a(a1), .b(b1), .result(p1));
    gf16_mul m2 (.a(a2), .b(b2), .result(p2));
    gf16_mul m3 (.a(a3), .b(b3), .result(p3));

    gf16_add a01 (.a(p0), .b(p1), .result(s01));
    gf16_add a23 (.a(p2), .b(p3), .result(s23));

    gf16_add a_final (.a(s01), .b(s23), .result(result));

endmodule
