// comb4.v -- radix-4 combine of 4 lane spectra into 8192-point bins.
// X[k0+2048q] = sum_l Y_l[k0] * W_8192^(l*k0) * W_4^(l*q)
//   Z0 = Y0, Zl = (Yl * Wl)>>16 for l=1..3  (17+1 bit twiddles, unity 2^16)
//   A=Z0+Z2 B=Z0-Z2 C=Z1+Z3 D=Z1-Z3
//   X0=A+C, X2=A-C, X1=B-jD, X3=B+jD ; then >>2 saturate to 24 bit
// Lane scaling: core gain 1/32, >>2 gives 1/128 overall (== optE 2-lane gain).
`timescale 1ns/1ps
module comb4 (
    input  wire clk, rst_n,
    input  wire signed [23:0] y0r,y0i,y1r,y1i,y2r,y2i,y3r,y3i,
    input  wire [10:0] j,
    input  wire vld,
    output reg  signed [23:0] x0r,x0i,x1r,x1i,x2r,x2i,x3r,x3i,
    output reg  [10:0] k0_o,
    output reg         vld_o
);
    // 2026-10-23 MEASURED: with fe4lane's input permutation applied (which the
    // fft2048 transposer requires) the core emits bins in NATURAL order, so the
    // merge index is k0 = j directly.  bitrev(j) was correct only for a
    // natural-order input, which smeared the core output.
    wire [10:0] k0 = {j[0],j[1],j[2],j[3],j[4],j[5],j[6],j[7],j[8],j[9],j[10]};

    (* rom_style = "block" *) reg [35:0] wt1 [0:2047];
    (* rom_style = "block" *) reg [35:0] wt2 [0:2047];
    (* rom_style = "block" *) reg [35:0] wt3 [0:2047];
    initial begin
        $readmemh("wt1.mem", wt1);
        $readmemh("wt2.mem", wt2);
        $readmemh("wt3.mem", wt3);
    end

    // s1: register core outputs + address
    reg signed [23:0] ar0,ai0,ar1,ai1,ar2,ai2,ar3,ai3;
    reg [10:0] k1;
    always @(posedge clk) if (!rst_n) begin
        ar0<=0;ai0<=0;ar1<=0;ai1<=0;ar2<=0;ai2<=0;ar3<=0;ai3<=0; k1<=0;
    end else begin
        ar0<=y0r;ai0<=y0i; ar1<=y1r;ai1<=y1i; ar2<=y2r;ai2<=y2i; ar3<=y3r;ai3<=y3i;
        k1 <= k0;
    end

    // s2: twiddle ROM output + data aligned
    reg [35:0] w1,w2,w3;
    reg signed [23:0] br0,bi0,br1,bi1,br2,bi2,br3,bi3;
    reg [10:0] k2;
    always @(posedge clk) if (!rst_n) begin
        w1<=0;w2<=0;w3<=0; br0<=0;bi0<=0;br1<=0;bi1<=0;br2<=0;bi2<=0;br3<=0;bi3<=0; k2<=0;
    end else begin
        w1<=wt1[k1]; w2<=wt2[k1]; w3<=wt3[k1];
        br0<=ar0;bi0<=ai0; br1<=ar1;bi1<=ai1; br2<=ar2;bi2<=ai2; br3<=ar3;bi3<=ai3;
        k2 <= k1;
    end

    // s3..s7: three complex multiplies (5 cycle each)
    wire signed [23:0] z1r,z1i,z2r,z2i,z3r,z3i;
    complex_mul u_m1(.clk(clk), .ar(w1[17:0]), .ai(w1[35:18]), .br(br1), .bi(bi1), .pr(z1r), .pi(z1i));
    complex_mul u_m2(.clk(clk), .ar(w2[17:0]), .ai(w2[35:18]), .br(br2), .bi(bi2), .pr(z2r), .pi(z2i));
    complex_mul u_m3(.clk(clk), .ar(w3[17:0]), .ai(w3[35:18]), .br(br3), .bi(bi3), .pr(z3r), .pi(z3i));

    // delay Z0 and k0 by 5
    reg signed [23:0] z0r_d [0:5]; reg signed [23:0] z0i_d [0:5];
    reg [10:0] kd [0:5]; reg vd [0:5];
    integer n;
    always @(posedge clk) begin
        z0r_d[0] <= br0; z0i_d[0] <= bi0; kd[0] <= k2; vd[0] <= vld;
        for (n=1;n<6;n=n+1) begin
            z0r_d[n] <= z0r_d[n-1]; z0i_d[n] <= z0i_d[n-1];
            kd[n] <= kd[n-1]; vd[n] <= vd[n-1];
        end
    end

    // s8: butterfly stage 1
    wire signed [24:0] a_re = {z0r_d[4][23],z0r_d[4]} + {z2r[23],z2r};
    wire signed [24:0] a_im = {z0i_d[4][23],z0i_d[4]} + {z2i[23],z2i};
    wire signed [24:0] b_re = {z0r_d[4][23],z0r_d[4]} - {z2r[23],z2r};
    wire signed [24:0] b_im = {z0i_d[4][23],z0i_d[4]} - {z2i[23],z2i};
    wire signed [24:0] c_re = {z1r[23],z1r} + {z3r[23],z3r};
    wire signed [24:0] c_im = {z1i[23],z1i} + {z3i[23],z3i};
    wire signed [24:0] d_re = {z1r[23],z1r} - {z3r[23],z3r};
    wire signed [24:0] d_im = {z1i[23],z1i} - {z3i[23],z3i};

    reg signed [24:0] A_r,A_i,B_r,B_i,C_r,C_i,D_r,D_i;
    reg [10:0] k3; reg v3;
    always @(posedge clk) if (!rst_n) begin
        A_r<=0;A_i<=0;B_r<=0;B_i<=0;C_r<=0;C_i<=0;D_r<=0;D_i<=0; k3<=0; v3<=0;
    end else begin
        A_r<=a_re;A_i<=a_im; B_r<=b_re;B_i<=b_im; C_r<=c_re;C_i<=c_im; D_r<=d_re;D_i<=d_im;
        k3 <= kd[4]; v3 <= vd[4];
    end

    // s9..s10: X = butterfly stage 2, then >>2 saturate
    wire signed [25:0] x0r_c = {A_r[24],A_r} + {C_r[24],C_r};
    wire signed [25:0] x0i_c = {A_i[24],A_i} + {C_i[24],C_i};
    wire signed [25:0] x2r_c = {A_r[24],A_r} - {C_r[24],C_r};
    wire signed [25:0] x2i_c = {A_i[24],A_i} - {C_i[24],C_i};
    wire signed [25:0] x1r_c = {B_r[24],B_r} + {D_i[24],D_i};
    wire signed [25:0] x1i_c = {B_i[24],B_i} - {D_r[24],D_r};
    wire signed [25:0] x3r_c = {B_r[24],B_r} - {D_i[24],D_i};
    wire signed [25:0] x3i_c = {B_i[24],B_i} + {D_r[24],D_r};

    function signed [23:0] sat24(input signed [25:0] v);
        begin
            if (v > 26'sd8388607) sat24 = 24'sd8388607;
            else if (v < -26'sd8388608) sat24 = -24'sd8388608;
            else sat24 = v[25:2];
        end
    endfunction

    reg signed [25:0] q0r,q0i,q1r,q1i,q2r,q2i,q3r,q3i;
    reg [10:0] k4; reg v4;
    always @(posedge clk) if (!rst_n) begin
        q0r<=0;q0i<=0;q1r<=0;q1i<=0;q2r<=0;q2i<=0;q3r<=0;q3i<=0; k4<=0; v4<=0;
    end else begin
        q0r<=x0r_c;q0i<=x0i_c; q1r<=x1r_c;q1i<=x1i_c;
        q2r<=x2r_c;q2i<=x2i_c; q3r<=x3r_c;q3i<=x3i_c;
        k4<=k3; v4<=v3;
    end

    always @(posedge clk) if (!rst_n) begin
        x0r<=0;x0i<=0;x1r<=0;x1i<=0;x2r<=0;x2i<=0;x3r<=0;x3i<=0; k0_o<=0; vld_o<=0;
    end else begin
        x0r<=sat24(q0r);x0i<=sat24(q0i); x1r<=sat24(q1r);x1i<=sat24(q1i);
        x2r<=sat24(q2r);x2i<=sat24(q2i); x3r<=sat24(q3r);x3i<=sat24(q3i);
        k0_o<=k4; vld_o<=v4;
    end
endmodule

// 3-DSP Karatsuba complex multiply, twiddle(18b) x data(24b) -> 24b, delay 5.
module complex_mul (
    input clk,
    input signed [17:0] ar, ai,
    input signed [23:0] br, bi,
    output signed [23:0] pr, pi
);
    // c1: operand sums
    reg signed [18:0] s1; reg signed [24:0] cd1, dc1;
    reg signed [17:0] ar1, ai1; reg signed [23:0] br1, bi1;
    // c2: products (DSP output regs)
    reg signed [41:0] p1, p2, p3;
    // c3: k1 = (a+b)c + h
    reg signed [42:0] k1, m3, m2;
    // c4: re/im combine
    reg signed [42:0] rr, ii;
    // c5: slice
    reg signed [23:0] prr, pii;

    always @(posedge clk) begin
        s1  <= ar + ai;
        cd1 <= br + bi;
        dc1 <= bi - br;
        ar1 <= ar; ai1 <= ai; br1 <= br; bi1 <= bi;
    end
    always @(posedge clk) begin
        p1 <= s1  * br1;
        p2 <= ar1 * dc1;
        p3 <= ai1 * cd1;
    end
    always @(posedge clk) begin
        k1 <= {p1[41],p1} + 43'sd32768;
        m3 <= {p3[41],p3};
        m2 <= {p2[41],p2};
    end
    always @(posedge clk) begin
        rr <= k1 - m3;
        ii <= k1 + m2;
    end
    always @(posedge clk) begin
        prr <= rr[39:16];
        pii <= ii[39:16];
    end
    assign pr = prr;
    assign pi = pii;
endmodule
