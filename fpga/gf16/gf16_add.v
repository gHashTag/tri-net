module gf16_add (
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] result
);

    localparam BIAS    = 6'd31;
    localparam EXP_MAX = 6'd63;

    wire        sign_a = a[15];
    wire [5:0]  exp_a  = a[14:9];
    wire [8:0]  mant_a = a[8:0];
    wire        sign_b = b[15];
    wire [5:0]  exp_b  = b[14:9];
    wire [8:0]  mant_b = b[8:0];

    wire is_zero_a    = (exp_a == 6'd0) && (mant_a == 9'd0);
    wire is_zero_b    = (exp_b == 6'd0) && (mant_b == 9'd0);
    wire is_special_a = (exp_a == EXP_MAX);
    wire is_special_b = (exp_b == EXP_MAX);
    wire is_inf_a     = is_special_a && (mant_a == 9'd0);
    wire is_inf_b     = is_special_b && (mant_b == 9'd0);
    wire is_nan_a     = is_special_a && (mant_a != 9'd0);
    wire is_nan_b     = is_special_b && (mant_b != 9'd0);

    wire a_larger = (exp_a > exp_b) || ((exp_a == exp_b) && (mant_a >= mant_b));

    reg [6:0]  big_exp, shift, result_exp;
    reg [10:0] big_fm, small_fm;
    reg [11:0] sum_m;
    reg        big_sign, small_sign, result_sign;
    reg [9:0]  norm;
    reg        g_bit, r_bit, s_bit;
    reg [9:0]  rounded;
    reg [6:0]  final_exp;
    reg [8:0]  final_mant;
    reg [15:0] fr;
    reg        cancel;

    always @(*) begin
        cancel = 0;
        result_exp = 0;
        norm = 0;
        g_bit = 0;
        r_bit = 0;
        s_bit = 0;
        rounded = 0;
        final_exp = 0;
        final_mant = 0;
        fr = 0;
        result_sign = 0;
        big_exp = 0;
        big_fm = 0;
        big_sign = 0;
        small_fm = 0;
        small_sign = 0;
        shift = 0;
        sum_m = 0;
        if (is_nan_a || is_nan_b)
            result = 16'hFE01;
        else if (is_inf_a && is_inf_b && (sign_a != sign_b))
            result = 16'hFE01;
        else if (is_inf_a)
            result = sign_a ? 16'hFE00 : 16'h7E00;
        else if (is_inf_b)
            result = sign_b ? 16'hFE00 : 16'h7E00;
        else if (is_zero_a && is_zero_b)
            result = 16'h0000;
        else if (is_zero_a)
            result = b;
        else if (is_zero_b)
            result = a;
        else begin
            if (a_larger) begin
                big_exp    = {1'b0, exp_a};
                big_fm     = {1'b1, mant_a};
                big_sign   = sign_a;
                small_fm   = {1'b1, mant_b};
                small_sign = sign_b;
            end else begin
                big_exp    = {1'b0, exp_b};
                big_fm     = {1'b1, mant_b};
                big_sign   = sign_b;
                small_fm   = {1'b1, mant_a};
                small_sign = sign_a;
            end

            shift = big_exp - {1'b0, (a_larger ? exp_b : exp_a)};
            result_exp = big_exp;

            case (shift)
                7'd0:  small_fm = small_fm;
                7'd1:  small_fm = {1'b0, small_fm[10:1]};
                7'd2:  small_fm = {2'b00, small_fm[10:2]};
                7'd3:  small_fm = {3'b000, small_fm[10:3]};
                7'd4:  small_fm = {4'b0000, small_fm[10:4]};
                7'd5:  small_fm = {5'b00000, small_fm[10:5]};
                7'd6:  small_fm = {6'b000000, small_fm[10:6]};
                7'd7:  small_fm = {7'b0000000, small_fm[10:7]};
                7'd8:  small_fm = {8'b00000000, small_fm[10:8]};
                7'd9:  small_fm = {9'b000000000, small_fm[10:9]};
                7'd10: small_fm = {10'b0000000000, small_fm[10]};
                default: small_fm = 11'd0;
            endcase

            if (big_sign == small_sign) begin
                sum_m = {1'b0, big_fm} + {1'b0, small_fm};
                result_sign = big_sign;
            end else begin
                sum_m = {1'b0, big_fm} - {1'b0, small_fm};
                result_sign = big_sign;
                if (sum_m == 12'd0)
                    cancel = 1;
            end

            if (!cancel) begin
                if (sum_m[11]) begin
                    result_exp = result_exp + 7'd1;
                    norm  = sum_m[10:1];
                    g_bit = sum_m[0];
                    r_bit = 1'b0;
                    s_bit = 1'b0;
                end else if (sum_m[10]) begin
                    result_exp = result_exp + 7'd1;
                    norm  = sum_m[10:1];
                    g_bit = sum_m[0];
                    r_bit = 1'b0;
                    s_bit = 1'b0;
                end else begin
                    if (sum_m[9]) begin
                        norm = sum_m[9:0];
                    end else if (sum_m[8]) begin
                        norm = {sum_m[8:0], 1'b0};
                        result_exp = result_exp - 7'd1;
                    end else if (sum_m[7]) begin
                        norm = {sum_m[7:0], 2'b00};
                        result_exp = result_exp - 7'd2;
                    end else if (sum_m[6]) begin
                        norm = {sum_m[6:0], 3'b000};
                        result_exp = result_exp - 7'd3;
                    end else if (sum_m[5]) begin
                        norm = {sum_m[5:0], 4'b0000};
                        result_exp = result_exp - 7'd4;
                    end else if (sum_m[4]) begin
                        norm = {sum_m[4:0], 5'b00000};
                        result_exp = result_exp - 7'd5;
                    end else if (sum_m[3]) begin
                        norm = {sum_m[3:0], 6'b000000};
                        result_exp = result_exp - 7'd6;
                    end else if (sum_m[2]) begin
                        norm = {sum_m[2:0], 7'b0000000};
                        result_exp = result_exp - 7'd7;
                    end else if (sum_m[1]) begin
                        norm = {sum_m[1:0], 8'b00000000};
                        result_exp = result_exp - 7'd8;
                    end else begin
                        norm = {sum_m[0], 9'b000000000};
                        result_exp = result_exp - 7'd9;
                    end
                    g_bit = 1'b0;
                    r_bit = 1'b0;
                    s_bit = 1'b0;
                end

                if (g_bit && (r_bit || s_bit))
                    rounded = norm + 10'd1;
                else
                    rounded = norm;

                if (rounded < norm) begin
                    final_exp  = result_exp + 7'd1;
                    final_mant = 9'd0;
                end else begin
                    final_exp  = result_exp;
                    final_mant = norm[8:0];
                end

                if (final_exp[6])
                    fr = result_sign ? 16'h8000 : 16'h0000;
                else if (final_exp[5:0] >= EXP_MAX)
                    fr = result_sign ? 16'hFE00 : 16'h7E00;
                else
                    fr = {result_sign, final_exp[5:0], final_mant};

                result = fr;
            end else begin
                result = 16'h0000;
            end
        end
    end

endmodule
