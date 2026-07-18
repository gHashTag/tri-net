`default_nettype none
// Adaptive clock recovery in RTL (Balyberdin AC-2 / ITU-T G.8261): recover the
// source sample clock from FIFO fill level, deterministic, hard-real-time.
// An NCO (phase accumulator) is the recovered oscillator; a PI loop steers its
// increment to hold the FIFO fill at its setpoint. In lock the NCO overflow rate
// (drain) equals the arrival rate (source clock). The phase accumulator IS an
// exact rate integrator -- no floating-point mean artifact.
module clkrec #(
    parameter integer PW  = 28,   // phase accumulator width (recovered-freq resolution)
    parameter integer FW  = 10,   // FIFO fill counter width; setpoint = 2^(FW-1)
    parameter integer IW  = 40,   // integrator width
    parameter integer KP  = 8,    // proportional gain: err << KP into inc
    parameter integer KIS = 12    // integral gain shift: integ >>> KIS into inc
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 arrive,     // 1-cycle strobe: a sample arrived from the SSI channel
    input  wire [PW-1:0]        inc_base,   // sink free-running increment (its own clock)
    output reg                  drain,      // 1-cycle strobe: NCO tick -> drain a sample (recovered clk)
    output reg  [FW-1:0]        fill,       // FIFO fill level (the phase detector)
    output wire signed [PW:0]   inc_now     // current NCO increment = recovered frequency
);
    localparam [FW-1:0] SETPT = {1'b1,{(FW-1){1'b0}}};  // midpoint = 2^(FW-1)

    reg  [PW-1:0]       phase;
    reg  signed [IW-1:0] integ;

    wire signed [FW:0]  err  = $signed({1'b0, fill}) - $signed({1'b0, SETPT});
    // PI: proportional (err scaled up into phase units) + integral (accumulated err, scaled down)
    wire signed [PW:0]  ucorr = ($signed(err) <<< KP) + $signed(integ >>> KIS);
    assign inc_now = $signed({1'b0, inc_base}) + ucorr;

    wire [PW:0] phase_next = phase + inc_now[PW-1:0];   // NCO step (wrap = overflow tick)
    wire        tick = phase_next[PW];                  // carry-out of the accumulator = drain event
    wire        do_drain = tick && (fill != 0);

    always @(posedge clk) begin
        if (rst) begin
            phase <= {PW{1'b0}};
            fill  <= SETPT;
            integ <= {IW{1'b0}};
            drain <= 1'b0;
        end else begin
            phase <= phase_next[PW-1:0];
            drain <= do_drain;
            integ <= integ + err;                       // integral action
            case ({arrive, do_drain})
                2'b10: fill <= fill + 1'b1;              // write only
                2'b01: fill <= fill - 1'b1;              // read only
                default: fill <= fill;                   // both or neither: net zero
            endcase
        end
    end
endmodule
`default_nettype wire
