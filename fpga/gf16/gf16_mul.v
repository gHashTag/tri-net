module gf16_mul (
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] result
);

    localparam BIAS = 6'd31;
    localparam EXP_MAX = 6'd63;

    wire        sign_a   = a[15];
    wire [5:0]  exp_a    = a[14:9];
    wire [8:0]  mant_a   = a[8:0];
    wire        sign_b   = b[15];
    wire [5:0]  exp_b    = b[14:9];
    wire [8:0]  mant_b   = b[8:0];

    wire is_zero_a    = (exp_a == 6'd0) && (mant_a == 9'd0);
    wire is_zero_b    = (exp_b == 6'd0) && (mant_b == 9'd0);
    wire is_special_a = (exp_a == EXP_MAX);
    wire is_special_b = (exp_b == EXP_MAX);
    wire is_inf_a     = is_special_a && (mant_a == 9'd0);
    wire is_inf_b     = is_special_b && (mant_b == 9'd0);
    wire is_nan_a     = is_special_a && (mant_a != 9'd0);
    wire is_nan_b     = is_special_b && (mant_b != 9'd0);

    wire result_sign = sign_a ^ sign_b;
    wire [9:0] full_mant_a = {1'b1, mant_a};
    wire [9:0] full_mant_b = {1'b1, mant_b};
    wire [19:0] mant_prod  = full_mant_a * full_mant_b;
    wire [6:0]  exp_sum    = {1'b0, exp_a} + {1'b0, exp_b};

    reg [6:0]  raw_exp;
    reg [8:0]  mant_out;
    reg [19:0] prod;
    reg        guard_bit, round_bit, sticky;
    reg [9:0]  mant_rounded;
    reg [6:0]  final_exp;
    reg [8:0]  final_mant;
    reg [15:0] final_result;

    always @(*) begin
        raw_exp = 0;
        mant_out = 0;
        prod = 0;
        guard_bit = 0;
        round_bit = 0;
        sticky = 0;
        mant_rounded = 0;
        final_exp = 0;
        final_mant = 0;
        final_result = 0;

        if (is_nan_a || is_nan_b) begin
            result = 16'hFE01;
        end else if ((is_zero_a && is_inf_b) || (is_zero_b && is_inf_a)) begin
            result = 16'hFE01;
        end else if (is_zero_a || is_zero_b) begin
            result = result_sign ? 16'h8000 : 16'h0000;
        end else if (is_inf_a || is_inf_b) begin
            result = result_sign ? 16'hFE00 : 16'h7E00;
        end else begin
            prod = mant_prod;
            raw_exp = exp_sum - BIAS;

            if (prod[19]) begin
                raw_exp = raw_exp + 7'd1;
                mant_out = prod[18:10];
                guard_bit = prod[9];
                round_bit = prod[8];
                sticky = |prod[7:0];
            end else if (prod[18]) begin
                mant_out = prod[17:9];
                guard_bit = prod[8];
                round_bit = prod[7];
                sticky = |prod[6:0];
            end else if (prod[17]) begin
                raw_exp = raw_exp - 7'd1;
                mant_out = prod[16:8];
                guard_bit = prod[7];
                round_bit = prod[6];
                sticky = |prod[5:0];
            end else begin
                raw_exp = raw_exp - 7'd2;
                mant_out = prod[15:7];
                guard_bit = prod[6];
                round_bit = prod[5];
                sticky = |prod[4:0];
            end

            if (guard_bit && (round_bit || sticky))
                mant_rounded = mant_out + 9'd1;
            else
                mant_rounded = mant_out;

            if (mant_rounded[9]) begin
                final_exp = raw_exp + 7'd1;
                final_mant = 9'd0;
            end else begin
                final_exp = raw_exp;
                final_mant = mant_rounded;
            end

            if (final_exp[6]) begin
                final_result = result_sign ? 16'h8000 : 16'h0000;
            end else if (final_exp[5:0] >= EXP_MAX) begin
                final_result = result_sign ? 16'hFE00 : 16'h7E00;
            end else begin
                final_result = {result_sign, final_exp[5:0], final_mant};
            end

            result = final_result;
        end
    end

endmodule
