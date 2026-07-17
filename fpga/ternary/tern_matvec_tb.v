`timescale 1ns/1ps
// Verify the ZeroDSP ternary NN layer against a software reference over random
// weights/activations: for each of M neurons, out[m] must equal
// sum_k decode(w[m][k]) * act[k]. If every trial matches, the multiplier-free
// matrix engine is bit-exact.
module tern_matvec_tb;
    localparam integer M=4, K=27, W=8, ACC=16;
    localparam [1:0] P=2'b01, Mn=2'b10, Z=2'b00;

    reg  [K*W-1:0]   act;
    reg  [M*K*2-1:0] wts;
    wire [M*ACC-1:0] out;
    tern_matvec #(.M(M),.K(K),.W(W),.ACC(ACC)) dut(.act(act),.wts(wts),.out(out));

    integer trial, m, k, a, wcode, ref_dot, hw, fails;
    reg signed [W-1:0] av;
    reg signed [ACC-1:0] hwv;
    initial begin
        fails=0;
        for (trial=0; trial<20; trial=trial+1) begin
            // random activations (-100..100) and ternary weights
            for (k=0;k<K;k=k+1) begin
                a = ($random % 201) - 100;
                act[k*W +: W] = a[W-1:0];
            end
            for (m=0;m<M;m=m+1)
                for (k=0;k<K;k=k+1) begin
                    wcode = $random % 3;   // 0->Z, 1->P, 2->M
                    wts[(m*K+k)*2 +: 2] = (wcode==1)?P : (wcode==2)?Mn : Z;
                end
            #1;
            // check each neuron against a software dot product
            for (m=0;m<M;m=m+1) begin
                ref_dot = 0;
                for (k=0;k<K;k=k+1) begin
                    av = act[k*W +: W];
                    case (wts[(m*K+k)*2 +: 2])
                        P:  ref_dot = ref_dot + av;
                        Mn: ref_dot = ref_dot - av;
                        default: ;
                    endcase
                end
                hwv = out[m*ACC +: ACC];
                hw  = hwv;
                if (hw !== ref_dot) begin
                    fails = fails + 1;
                    $display("  MISMATCH trial %0d neuron %0d: hw=%0d ref=%0d", trial, m, hw, ref_dot);
                end
            end
        end
        $display("tern_matvec: %0d trials x %0d neurons, %0d mismatches", 20, M, fails);
        if (fails==0) $display("TERNARY MATVEC: bit-exact vs reference -> ZeroDSP edge-AI layer works");
        else          $display("TERNARY MATVEC: FAILED");
        $finish;
    end
endmodule
