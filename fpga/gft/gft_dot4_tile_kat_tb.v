`timescale 1ns / 1ps
// Same golden as gft_dot4 (composition of over-wire-verified mul+add), narrow ports:
//   four (41,256)^2 -> (45,64);  mixed {1.5^2, phi^2, 1.5^2, phi^2} -> (44,320)
module gft_dot4_tile_kat_tb;
    reg [27:0] aoff, boff; reg [35:0] amant, bmant;
    wire [6:0] oo; wire [8:0] om;
    integer fails = 0;
    gft_dot4_tile dut (aoff, amant, boff, bmant, oo, om);
    task chk(input [95:0] n, input [6:0] eo, input [8:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,%0d)", n, oo, om);
        end
    endtask
    initial begin
        aoff = {7'd41,7'd41,7'd41,7'd41}; boff = {7'd41,7'd41,7'd41,7'd41};
        amant = {9'd256,9'd256,9'd256,9'd256}; bmant = {9'd256,9'd256,9'd256,9'd256};
        #1 chk("tile 4x1.5^2", 45, 64);
        amant = {9'd256,9'd0,9'd256,9'd0}; bmant = {9'd256,9'd0,9'd256,9'd0};
        #1 chk("tile mixed", 44, 320);
        if (fails==0) $display("KAT PASS: gft_dot4_tile matches gft_dot4 (narrow)"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
