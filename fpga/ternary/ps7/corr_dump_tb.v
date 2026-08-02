`timescale 1ns/1ps
// Дамп каждого значения коррелятора для посэмпловой сверки с программным эталоном.
module dump_tb;
  localparam integer W=16, ACC=20;
  localparam [1:0] P=2'b01, M=2'b10, Z=2'b00;
  reg clk=0, rst=1, s_valid=0; reg signed [W-1:0] s_data=0;
  reg c_wr=0; reg [2:0] c_addr=0; reg [1:0] c_data=0;
  wire m_valid; wire signed [ACC-1:0] m_data;
  tern_corr8_stream #(.W(W),.ACC(ACC)) uut(.clk(clk),.rst(rst),.s_valid(s_valid),
    .s_data(s_data),.c_wr(c_wr),.c_addr(c_addr),.c_data(c_data),
    .m_valid(m_valid),.m_data(m_data));
  always #5 clk=~clk;
  reg signed [W-1:0] samp [0:255];
  reg [1:0] code [0:7];
  integer k;
  initial begin
    code[0]=P;code[1]=P;code[2]=Z;code[3]=M;code[4]=M;code[5]=M;code[6]=Z;code[7]=P;
    $readmemh("ota/rx_on_raw.hex", samp);
    @(negedge clk); @(negedge clk); rst=0;
    for(k=0;k<8;k=k+1) begin @(negedge clk); c_wr=1; c_addr=k[2:0]; c_data=code[k]; end
    @(negedge clk); c_wr=0;
    for(k=0;k<256;k=k+1) begin
      @(negedge clk); s_valid=1; s_data=samp[k];
      @(posedge clk); #1;
      if(k>0) $display("%0d", m_data);   // результат предыдущего отсчёта
    end
    @(negedge clk); s_valid=0; @(posedge clk); #1; $display("%0d", m_data);
    $finish;
  end
endmodule
