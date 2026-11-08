// sys4_top.v -- 4 lane x fft2048 = 8192 point analysis chain (fs = 4*f_clk)
// Split-clock version for 250 MHz (plan 3.2 + 3.1):
//   clk  (250 MHz): front end + 4 cores + radix-4 merge + |X|^2 + spectrum write
//   clk2 (125 MHz): spectrum read + ds4 + report registers
//   spectrum RAM = ONE 4096x64 true dual port BRAM: write port on clk
//   (addr {lane,buf,row}), read port on clk2 (addr {quadrant,buf,row}).
//   Read latency is 1 clk2 cycle, exactly the 1 cycle ds4 had before.
`timescale 1ns/1ps
module sys4_top (
    input  wire clk,
    input  wire clk2,             // clk/2, MMCM CLKOUT2 (phase aligned)
    input  wire rst_n,
    output reg  [12:0] o_left, o_right, o_center,
    output reg  [13:0] o_bw,
    output reg  [15:0] o_peak, o_thr,
    output reg  [23:0] o_amp,
    output reg         o_found, o_done,
    output reg  [15:0] o_done_cnt,
    output reg  [12:0] o_lat         // 2026-11-02: 本帧分析处理时间（clk2 拍，含 1024 采集）
);
    // ---------------- front end + 4 cores (clk) ----------------
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

    // ---------------- merge (clk) ----------------
    wire signed [23:0] x0r,x0i,x1r,x1i,x2r,x2i,x3r,x3i;
    wire [10:0] k0; wire cv;
    comb4 u_cb (.clk(clk),.rst_n(rst_n),.y0r(c0r),.y0i(c0i),.y1r(c1r),.y1i(c1i),
                .y2r(c2r),.y2i(c2i),.y3r(c3r),.y3i(c3i),.j(j),.vld(1'b1),
                .x0r(x0r),.x0i(x0i),.x1r(x1r),.x1i(x1i),.x2r(x2r),.x2i(x2i),
                .x3r(x3r),.x3i(x3i),.k0_o(k0),.vld_o(cv));

    wire [15:0] m0,m1,m2,m3;
    mag_sq24 u_m0(.clk(clk),.rst_n(rst_n),.valid_in(cv),.i_in(x0r),.q_in(x0i),.mag16(m0),.valid_out());
    mag_sq24 u_m1(.clk(clk),.rst_n(rst_n),.valid_in(cv),.i_in(x1r),.q_in(x1i),.mag16(m1),.valid_out());
    mag_sq24 u_m2(.clk(clk),.rst_n(rst_n),.valid_in(cv),.i_in(x2r),.q_in(x2i),.mag16(m2),.valid_out());
    mag_sq24 u_m3(.clk(clk),.rst_n(rst_n),.valid_in(cv),.i_in(x3r),.q_in(x3i),.mag16(m3),.valid_out());

    // ---------------- spectrum RAM: 16 x (1024 x 16) in BRAM -----------------
    // [quadrant][lane] arrays, one word per (buf,row) address; a read returns the
    // 4 LANES of the selected quadrant = 4 consecutive bins (what ds4 expects).
    // BRAM read is synchronous and the quadrant select is a 4:1 mux on the RAM
    // outputs, so the read latency is 2 clk2 cycles (ds4 is padded by 1 stage).
    (* ram_style = "block" *) reg [15:0] r00 [0:1023]; (* ram_style = "block" *) reg [15:0] r01 [0:1023];
    (* ram_style = "block" *) reg [15:0] r02 [0:1023]; (* ram_style = "block" *) reg [15:0] r03 [0:1023];
    (* ram_style = "block" *) reg [15:0] r10 [0:1023]; (* ram_style = "block" *) reg [15:0] r11 [0:1023];
    (* ram_style = "block" *) reg [15:0] r12 [0:1023]; (* ram_style = "block" *) reg [15:0] r13 [0:1023];
    (* ram_style = "block" *) reg [15:0] r20 [0:1023]; (* ram_style = "block" *) reg [15:0] r21 [0:1023];
    (* ram_style = "block" *) reg [15:0] r22 [0:1023]; (* ram_style = "block" *) reg [15:0] r23 [0:1023];
    (* ram_style = "block" *) reg [15:0] r30 [0:1023]; (* ram_style = "block" *) reg [15:0] r31 [0:1023];
    (* ram_style = "block" *) reg [15:0] r32 [0:1023]; (* ram_style = "block" *) reg [15:0] r33 [0:1023];
    reg [10:0] kd0,kd1,kd2,kd3; reg vd0,vd1,vd2,vd3;
    always @(posedge clk) begin
        kd0<=k0; kd1<=kd0; kd2<=kd1; kd3<=kd2;
        vd0<=cv; vd1<=vd0; vd2<=vd1; vd3<=vd2;
    end
    wire wv = vd3;
    wire [10:0] jd = {kd3[0],kd3[1],kd3[2],kd3[3],kd3[4],kd3[5],kd3[6],kd3[7],kd3[8],kd3[9],kd3[10]};
    wire fend = wv && (jd == 11'd2047);
    reg wbuf, wr_ok, ftog, buf_done;
    reg [13:0] warm;
    wire ds_busy, ds_done;
    (* ASYNC_REG = "TRUE" *) reg bs_s0, bs_s1;
    wire [9:0] waddr = {wbuf, kd3[10:2]};
    wire [1:0] lane  = kd3[1:0];
    always @(posedge clk) if (wv && wr_ok) begin
        case (lane)
          2'd0: begin r00[waddr]<=m0; r10[waddr]<=m1; r20[waddr]<=m2; r30[waddr]<=m3; end
          2'd1: begin r01[waddr]<=m0; r11[waddr]<=m1; r21[waddr]<=m2; r31[waddr]<=m3; end
          2'd2: begin r02[waddr]<=m0; r12[waddr]<=m1; r22[waddr]<=m2; r32[waddr]<=m3; end
          default: begin r03[waddr]<=m0; r13[waddr]<=m1; r23[waddr]<=m2; r33[waddr]<=m3; end
        endcase
    end
    initial begin warm = 14'd0; wbuf = 1'b0; wr_ok = 1'b0; ftog = 1'b0; buf_done = 1'b0;
                  bs_s0 = 1'b0; bs_s1 = 1'b0; end
    always @(posedge clk) if (!rst_n) begin
        warm <= 14'd0; wbuf <= 1'b0; wr_ok <= 1'b0; ftog <= 1'b0; buf_done <= 1'b0;
        bs_s0 <= 1'b0; bs_s1 <= 1'b0;
    end else begin
        bs_s0 <= ds_busy; bs_s1 <= bs_s0;
        if (warm != 14'H3FFF) warm <= warm + 1'b1;
        // 2026-10-25 duty100: CONTINUOUS CAPTURE.  The old code dropped wr_ok for one
        // whole frame after every analysed frame and re-armed only at the next fend,
        // which forced N >= 2 no matter how fast pass A was.  The spectrum RAM already
        // has two banks (wbuf/rbuf are the MSB of every array address), so the writer
        // can simply keep going: at each fend the completed bank is handed to the
        // reader and the writer continues into the other bank.
        // Safety: a start is only issued when ds4 is idle, and a bank is not rewritten
        // for two frames, so the binding condition is D < 2048 clk2 (see docs).
        if (fend && warm[13]) wr_ok <= 1'b1;
        if (fend && wr_ok) begin
            buf_done <= wbuf; wbuf <= ~wbuf; ftog <= ~ftog;
        end
    end

    // ---------------- clk2 domain: read + ds4 + report ----------------
    reg rst_n2;
    initial rst_n2 = 1'b0;
    always @(posedge clk2) rst_n2 <= rst_n;

    (* ASYNC_REG = "TRUE" *) reg ft_s0, ft_s1, ft_s2, bd_s0, bd_s1;
    always @(posedge clk2) if (!rst_n2) begin
        ft_s0<=0; ft_s1<=0; ft_s2<=0; bd_s0<=0; bd_s1<=0;
    end else begin
        ft_s0 <= ftog;      ft_s1 <= ft_s0;   ft_s2 <= ft_s1;
        bd_s0 <= buf_done;  bd_s1 <= bd_s0;
    end
    wire new_frame = ft_s1 ^ ft_s2;

    wire [8:0] ra;
    reg rbuf, ds_start;
    always @(posedge clk2) if (!rst_n2) begin rbuf <= 1'b0; ds_start <= 1'b0; end
    else begin
        ds_start <= 1'b0;
        if (new_frame && !ds_busy) begin rbuf <= bd_s1; ds_start <= 1'b1; end
    end

    wire [9:0] raddr = {rbuf, ra};
    reg [15:0] d00,d01,d02,d03,d10,d11,d12,d13,d20,d21,d22,d23,d30,d31,d32,d33;
    // C1/v3: keep all four quadrant words (the 4:1 rq mux of the baseline threw
    // 3/4 of the already-read bandwidth away).  ds4 consumes 4 x 64 bit and
    // runs four independent 256-bin windows.  Read latency stays 2 clk2.
    always @(posedge clk2) begin
        d00<=r00[raddr]; d01<=r01[raddr]; d02<=r02[raddr]; d03<=r03[raddr];
        d10<=r10[raddr]; d11<=r11[raddr]; d12<=r12[raddr]; d13<=r13[raddr];
        d20<=r20[raddr]; d21<=r21[raddr]; d22<=r22[raddr]; d23<=r23[raddr];
        d30<=r30[raddr]; d31<=r31[raddr]; d32<=r32[raddr]; d33<=r33[raddr];
    end
    reg [63:0] rw0, rw1, rw2, rw3;
    always @(posedge clk2) begin
        rw0 <= {d03,d02,d01,d00};
        rw1 <= {d13,d12,d11,d10};
        rw2 <= {d23,d22,d21,d20};
        rw3 <= {d33,d32,d31,d30};
    end

    wire [12:0] dl,dr,dc; wire [13:0] dbw; wire [15:0] dpk,dth; wire dfnd;
    wire ds_pa_done, ds_pb_busy;
    ds4 u_ds (.clk(clk2),.rst_n(rst_n2),.start(ds_start),.bank(rbuf),.busy(ds_busy),.ra(ra),
              .rw0(rw0),.rw1(rw1),.rw2(rw2),.rw3(rw3),.done(ds_done),
              .o_left(dl),.o_right(dr),.o_center(dc),
              .o_bw(dbw),.o_peak(dpk),.o_thr(dth),.found(dfnd),
              .pa_done(ds_pa_done),.pb_busy(ds_pb_busy));

    always @(posedge clk2) if (!rst_n2) begin
        o_left<=0; o_right<=0; o_center<=0; o_bw<=0; o_peak<=0; o_thr<=0;
        o_found<=0; o_done<=0; o_done_cnt<=0; o_amp<=0;
    end else begin
        o_done <= ds_done;
        if (ds_done) begin
            o_left<=dl; o_right<=dr; o_center<=dc; o_bw<=dbw; o_peak<=dpk; o_thr<=dth;
            o_found<=dfnd; o_done_cnt <= o_done_cnt + 1'b1;
            o_amp <= {12'd0, amp12};
        end
    end

    // ---- 延迟测量（2026-11-02 v2）：帧首样点 → 该帧结果锁存，单位 clk2 拍 ----
    // 稳态下 ds_start(k+1) 早于 ds_done(k)（分析 1104 拍 > 帧 1024 拍），
    // 所以 start/done 各配一个 2 深 FIFO 时间戳，不能用一个"在 new_frame 重置"的计数器。
    reg [12:0] fc;              // 自由运行时基
    reg [12:0] ts0, ts1;        // 最近两次 ds_start 的时刻
    reg        wp, rp;          // 写/读指针
    always @(posedge clk2) if (!rst_n2) begin
        fc <= 13'd0; ts0 <= 13'd0; ts1 <= 13'd0; wp <= 1'b0; rp <= 1'b0; o_lat <= 13'd0;
    end else begin
        fc <= fc + 1'b1;
        if (ds_start) begin
            if (wp) ts1 <= fc; else ts0 <= fc;
            wp <= ~wp;
        end
        if (ds_done) begin
            o_lat <= fc - (rp ? ts1 : ts0) + 13'd1024;   // +1024 = 采集窗
            rp <= ~rp;
        end
    end
endmodule
