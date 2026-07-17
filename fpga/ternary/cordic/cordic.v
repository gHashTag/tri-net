`default_nettype none

// cordic -- Q15 pipelined CORDIC sin/cos (IGLA-RACE cordic_fixed). Computes
// cos/sin of a binary-angle input (2*pi == 65536 units) using only shifts and
// adds -- the transformer's RoPE / activation transcendentals with ZERO
// multipliers, complementing the ternary MAC. 16 rotation stages, one register
// each: latency 17, throughput one result per clock.
//
// SSOT: t27/specs/igla/race/cordic_fixed.t27, cordic_top.t27.
module cordic (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire signed [15:0] theta,     // binary angle, 2*pi = 65536
    output reg                out_valid,
    output reg signed [15:0]  cos_o,      // Q15
    output reg signed [15:0]  sin_o       // Q15
);
    localparam signed [16:0] HALF_PI = 17'sd16384;   // pi/2 in angle units
    localparam signed [16:0] PI      = 17'sd32768;
    localparam signed [16:0] X0      = 17'sd19898;   // CORDIC gain K in Q15

    // atan(2^-i) in binary-angle units
    function signed [16:0] atan_i; input integer i; begin
        case (i)
            0: atan_i=17'sd8192; 1: atan_i=17'sd4836; 2: atan_i=17'sd2555; 3: atan_i=17'sd1297;
            4: atan_i=17'sd651;  5: atan_i=17'sd326;  6: atan_i=17'sd163;  7: atan_i=17'sd81;
            8: atan_i=17'sd41;   9: atan_i=17'sd20;  10: atan_i=17'sd10;  11: atan_i=17'sd5;
           12: atan_i=17'sd3;   13: atan_i=17'sd1;   14: atan_i=17'sd1;   15: atan_i=17'sd0;
            default: atan_i=17'sd0;
        endcase
    end endfunction

    // ---- input quadrant fold into [-pi/2, pi/2]; remember a sign flip ----
    reg signed [16:0] xf, yf, zf; reg flipf, vf;
    always @(posedge clk) begin
        if (rst) begin vf<=0; flipf<=0; xf<=0; yf<=0; zf<=0; end
        else begin
            vf <= in_valid;
            if ($signed(theta) > HALF_PI) begin
                zf <= $signed(theta) - PI; flipf <= 1'b1;
            end else if ($signed(theta) < -HALF_PI) begin
                zf <= $signed(theta) + PI; flipf <= 1'b1;
            end else begin
                zf <= $signed(theta); flipf <= 1'b0;
            end
            xf <= X0; yf <= 17'sd0;
        end
    end

    // ---- 16 pipelined rotation stages ----
    reg signed [16:0] xs [0:16];
    reg signed [16:0] ys [0:16];
    reg signed [16:0] zs [0:16];
    reg               fl [0:16];
    reg               vl [0:16];
    integer s;
    always @(posedge clk) begin
        xs[0] <= xf; ys[0] <= yf; zs[0] <= zf; fl[0] <= flipf; vl[0] <= vf;
        for (s = 0; s < 16; s = s + 1) begin
            if (zs[s] >= 0) begin
                xs[s+1] <= xs[s] - (ys[s] >>> s);
                ys[s+1] <= ys[s] + (xs[s] >>> s);
                zs[s+1] <= zs[s] - atan_i(s);
            end else begin
                xs[s+1] <= xs[s] + (ys[s] >>> s);
                ys[s+1] <= ys[s] - (xs[s] >>> s);
                zs[s+1] <= zs[s] + atan_i(s);
            end
            fl[s+1] <= fl[s]; vl[s+1] <= vl[s];
        end
    end

    // ---- output: saturate to Q15 [-32767,32767], then apply the sign flip ----
    function signed [15:0] sat; input signed [16:0] v; begin
        if (v > 17'sd32767)       sat = 16'sd32767;
        else if (v < -17'sd32767) sat = -16'sd32767;
        else                      sat = v[15:0];
    end endfunction
    reg signed [15:0] xc, ys16;
    always @(posedge clk) begin
        out_valid <= vl[16];
        xc   = sat(xs[16]);
        ys16 = sat(ys[16]);
        cos_o <= fl[16] ? -xc : xc;
        sin_o <= fl[16] ? -ys16 : ys16;
    end
endmodule

`default_nettype wire
