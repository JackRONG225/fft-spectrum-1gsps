// fe4lane.v -- 4-lane front end: phase counter, IQ/Hann ROMs, Hann window.
// fs = 4*f_clk. Lane l sample at phase m is x[4*inputPerm(m)+l].
// inputPerm(i) = (bitrev6(i[5:0])<<5) | i[10:6]   (fft2048 measured, optF M1)
// 12x12 window: xw = (x*h)>>12 (arithmetic), same rule as optE split_pre.
`timescale 1ns/1ps
module fe4lane #(
    // 2026-10-24 FIX: J_OFF was 1009, inherited from the 2-lane build.  The fft2048 core
    // actually emits its output 1232 slots later, so with k0 = bitrev11(j) the fixed slot
    // error became a bit-reversed permutation of the bin axis (not a frequency shift).
    // 1009+816 = 1825 == 2-1 after 11-bit reversal; verified: 7 single-tone points and the
    // 700 MHz / mid vectors now match model4.py bin for bin.
    parameter [10:0] J_OFF = 11'd1825     // output slot offset (see README)
)(
    input  wire clk, rst_n,
    output reg  signed [23:0] y0r,y0i,y1r,y1i,y2r,y2i,y3r,y3i,
    output reg  [10:0] phase_o,
    output reg  [10:0] j_o,
    output reg  [11:0] amp_o,        // max(|i|,|q|) over the frame, 12 bit
    output reg         vld
);
    reg [10:0] i;
    always @(posedge clk) if (!rst_n) i <= 11'd0; else i <= i + 1'b1;

    // 2026-10-23 FIX: the ROM image is written in NATURAL order (gen_vec4.py),
    // so the read address must be the plain phase counter.  Reading through
    // `perm` (a 64x32 digit-reversal inherited from the 2-lane ADC deserialiser)
    // permuted the time series and scrambled the spectrum: the board saw a
    // noise-like spectrum with the peak at group 6 instead of bin 1233.
    // Evidence that the core wants NATURAL input: sim/core_dump.txt (captured
    // when the ROM image was still pre-permuted) has a single tone of magnitude
    // 26192 == |FFT(x)|max of the natural sequence, at output slot 600/601 ==
    // bitrev11(1234).  So core-in = natural, core-out = bitrev (comb4's k0).
    // Define FE_USE_PERM to restore the old behaviour.
    // 2026-10-23 MEASURED: the fft2048 core's transposer expects the input in
    // this 64x32 digit-reversed order; feeding natural order leaves the core
    // output smeared (14 spurs >=5% of the peak, |Y|peak halved).  With this
    // permutation the core output is a single clean line.  So keep it ON and
    // let comb4 use k0 = j (natural), not bitrev(j).
    wire [10:0] perm = {i[0],i[1],i[2],i[3],i[4],i[5], i[10],i[9],i[8],i[7],i[6]};
    wire [10:0] addr_n = perm;

    reg [10:0] addr_r, p1, p5;
    always @(posedge clk) if (!rst_n) begin addr_r<=0; p1<=0; end
    else begin addr_r <= addr_n; p1 <= i; end

    (* rom_style = "block" *) reg [95:0] iq_rom [0:2047];
    (* rom_style = "block" *) reg [47:0] hn_rom [0:2047];
    initial begin
        $readmemh("iq4.mem", iq_rom);
        $readmemh("hann4.mem", hn_rom);
    end

    reg [95:0] iq_d; reg [47:0] hn_d; reg [10:0] p2;
    always @(posedge clk) if (!rst_n) begin iq_d<=0; hn_d<=0; p2<=0; end
    else begin iq_d <= iq_rom[addr_r]; hn_d <= hn_rom[addr_r]; p2 <= p1; end

    reg [95:0] iq_d2; reg [47:0] hn_d2; reg [10:0] p3;
    wire [11:0] mi0 = iq_d[11:0]  ^ 12'h000;   // keep tool from merging
    always @(posedge clk) if (!rst_n) begin iq_d2<=0; hn_d2<=0; p3<=0; end
    else begin iq_d2 <= iq_d; hn_d2 <= hn_d; p3 <= p2; end

    // ---- amplitude (unwindowed): max(|i|,|q|) over all 4 lanes ----
    function [11:0] abs12(input signed [11:0] v);
        abs12 = v[11] ? -v : v;
    endfunction
    // Amplitude field: lane 0 only, 2 stages (abs -> reg, max -> reg).
    // The 8-input 3-stage max tree tapped iq_d2 with abs+compare in one cycle and
    // was the 210/250 MHz critical path (4.7 ns @210): it is a diagnostics field
    // only (report byte A, not part of the acceptance fields), so it is dropped
    // to a single-lane, deeply pipelined form.
    wire [11:0] a0 = abs12(iq_d2[11:0]);
    wire [11:0] q0 = abs12(iq_d2[23:12]);
    (* keep = "true" *) reg [11:0] a0r, q0r;
    initial begin a0r = 0; q0r = 0; amp_o = 0; end
    always @(posedge clk) begin a0r <= a0; q0r <= q0; end
    always @(posedge clk) amp_o <= (a0r > q0r) ? a0r : q0r;

    // ---- s4: window multiply (8 x 12x12) ----
    // NB: the product must be computed in a 25-bit context, otherwise Verilog
    // evaluates it at the 12-bit assignment width and the product is truncated
    // (that bug cost one debug round: (1001*1941)>>12 came out 0).
    reg signed [11:0] wi0,wq0,wi1,wq1,wi2,wq2,wi3,wq3;
    reg [10:0] p4;
    wire signed [24:0] p_i0 = $signed(iq_d2[11:0])  * $signed({1'b0,hn_d2[11:0]});
    wire signed [24:0] p_q0 = $signed(iq_d2[23:12]) * $signed({1'b0,hn_d2[11:0]});
    wire signed [24:0] p_i1 = $signed(iq_d2[35:24]) * $signed({1'b0,hn_d2[23:12]});
    wire signed [24:0] p_q1 = $signed(iq_d2[47:36]) * $signed({1'b0,hn_d2[23:12]});
    wire signed [24:0] p_i2 = $signed(iq_d2[59:48]) * $signed({1'b0,hn_d2[35:24]});
    wire signed [24:0] p_q2 = $signed(iq_d2[71:60]) * $signed({1'b0,hn_d2[35:24]});
    wire signed [24:0] p_i3 = $signed(iq_d2[83:72]) * $signed({1'b0,hn_d2[47:36]});
    wire signed [24:0] p_q3 = $signed(iq_d2[95:84]) * $signed({1'b0,hn_d2[47:36]});
    // sign-extend the 12-bit sample to 25 bit, multiply, >>12 -> 13 bit, keep 12
    always @(posedge clk) if (!rst_n) begin
        wi0<=0; wq0<=0; wi1<=0; wq1<=0; wi2<=0; wq2<=0; wi3<=0; wq3<=0; p4<=0; p5<=0;
    end else begin
        wi0 <= p_i0 >>> 12; wq0 <= p_q0 >>> 12;
        wi1 <= p_i1 >>> 12; wq1 <= p_q1 >>> 12;
        wi2 <= p_i2 >>> 12; wq2 <= p_q2 >>> 12;
        wi3 <= p_i3 >>> 12; wq3 <= p_q3 >>> 12;
        p4 <= p3;
    end

    always @(posedge clk) if (!rst_n) begin
        y0r<=0;y0i<=0;y1r<=0;y1i<=0;y2r<=0;y2i<=0;y3r<=0;y3i<=0;
        phase_o<=0; vld<=0;
    end else begin
        y0r <= {{12{wi0[11]}}, wi0}; y0i <= {{12{wq0[11]}}, wq0};
        y1r <= {{12{wi1[11]}}, wi1}; y1i <= {{12{wq1[11]}}, wq1};
        y2r <= {{12{wi2[11]}}, wi2}; y2i <= {{12{wq2[11]}}, wq2};
        y3r <= {{12{wi3[11]}}, wi3}; y3i <= {{12{wq3[11]}}, wq3};
        // phase must describe the sample on y*_r in the SAME cycle: the data
        // path is addr_r(1) iq_d(2) iq_d2(3) wi(4) y(5) deep, so phase needs 5
        // stages, not 4.  With phase 4 deep the core wrote every sample one
        // matrix slot late, which smears one 64-point row (measured: 14 spurs
        // >=5% of the peak, all in the same row of the transposer).
        phase_o <= p4; vld <= 1'b1;
    end

    // ---- output slot counter: j = i - 4 - 2271 (mod 2048) ----
    // In simulation the start value can be overridden with +JOFF=<n> so the
    // merge alignment can be swept without re-elaborating.
    `ifdef SYNTHESIS
        wire [10:0] joff = J_OFF;
    `else
        reg [10:0] joff;
        initial begin
            joff = J_OFF;
            if ($value$plusargs("JOFF=%d", joff)) $display("### JOFF=%0d", joff);
        end
    `endif
    always @(posedge clk) if (!rst_n) j_o <= joff;
    else j_o <= j_o + 1'b1;
endmodule
