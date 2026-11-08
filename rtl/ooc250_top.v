// ooc250_top.v -- out-of-context probe for the 250 MHz domain only.
// Contains: fe4lane + 4x fft2048_core + comb4 (the high-speed pipeline).
// Excludes: spectrum RAM, mag_sq24, ds4, report (these move to clk/2 per plan 3.2).
`timescale 1ns/1ps
module ooc250_top (
    input  wire clk, rst_n,
    output reg  [31:0] chk0, chk1, chk2, chk3
);
    wire signed [23:0] y0r,y0i,y1r,y1i,y2r,y2i,y3r,y3i;
    wire [10:0] ph, j;
    wire [11:0] amp12;
    fe4lane u_fe (.clk(clk),.rst_n(rst_n),.y0r(y0r),.y0i(y0i),.y1r(y1r),.y1i(y1i),
                  .y2r(y2r),.y2i(y2i),.y3r(y3r),.y3i(y3i),.phase_o(ph),.j_o(j),
                  .amp_o(amp12),.vld());

    wire [23:0] c0r,c0i,c1r,c1i,c2r,c2i,c3r,c3i;
    fft2048_core u_c0 (.clk(clk),.din_re(y0r),.din_im(y0i),.phase(ph),.dout_re(c0r),.dout_im(c0i));
    fft2048_core u_c1 (.clk(clk),.din_re(y1r),.din_im(y1i),.phase(ph),.dout_re(c1r),.dout_im(c1i));
    fft2048_core u_c2 (.clk(clk),.din_re(y2r),.din_im(y2i),.phase(ph),.dout_re(c2r),.dout_im(c2i));
    fft2048_core u_c3 (.clk(clk),.din_re(y3r),.din_im(y3i),.phase(ph),.dout_re(c3r),.dout_im(c3i));

    wire signed [23:0] x0r,x0i,x1r,x1i,x2r,x2i,x3r,x3i;
    wire [10:0] k0; wire cv;
    comb4 u_cb (.clk(clk),.rst_n(rst_n),.y0r(c0r),.y0i(c0i),.y1r(c1r),.y1i(c1i),
                .y2r(c2r),.y2i(c2i),.y3r(c3r),.y3i(c3i),.j(j),.vld(1'b1),
                .x0r(x0r),.x0i(x0i),.x1r(x1r),.x1i(x1i),.x2r(x2r),.x2i(x2i),
                .x3r(x3r),.x3i(x3i),.k0_o(k0),.vld_o(cv));

    always @(posedge clk) if (!rst_n) begin
        chk0<=0; chk1<=0; chk2<=0; chk3<=0;
    end else if (cv) begin
        chk0 <= {k0, x0r[23:3]};
        chk1 <= x1r;
        chk2 <= x2r;
        chk3 <= x3r;
    end
endmodule
