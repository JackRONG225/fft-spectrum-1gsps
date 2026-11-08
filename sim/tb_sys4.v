// tb_sys4.v -- 4-lane chain: run frames, capture report fields, dump spectrum.
// duty100 version: adds
//   * structural self-check assertions on the bin axis (k0 = bitrev11(j) as a
//     de-reversed running slot counter, 2048 slots per frame),
//   * clk2-cycle timestamps for fend / ds_start / busy / done so N and D can be
//     measured from the log,
//   * smem dump at the 2nd PB entry (the old dump fired at the FIRST PA entry,
//     i.e. before pass A had ever written smem -- that file was all zeros),
//   * per-frame write counter (to detect dropped frames).
`timescale 1ns/1ps
module tb_sys4;
    reg clk = 0, rst_n = 0, clk2 = 0;
    always #2.5 clk  = ~clk;      // 200 MHz
    always #5.0 clk2 = ~clk2;     // 100 MHz
    wire [12:0] L,R,C; wire [13:0] BW; wire [15:0] PK,TH,DC;
    wire [23:0] A; wire F,D;
    wire [12:0] LAT;
    sys4_top u (.clk(clk),.clk2(clk2),.rst_n(rst_n),.o_left(L),.o_right(R),.o_center(C),.o_bw(BW),
                .o_peak(PK),.o_thr(TH),.o_amp(A),.o_found(F),.o_done(D),.o_done_cnt(DC),.o_lat(LAT));

    integer n, fd, i, fc, f4, f5, fs2;
    reg [2:0] last_st = 3'd0;
    integer c2 = 0;
    always @(posedge clk2) c2 <= c2 + 1;

    // ------------------------------------------------------------------
    // self-check: bin axis.  comb4 emits k0 = bitrev11(j) where j is a
    // free-running slot counter; de-reversing k0 must produce a +1 counter,
    // exactly one full turn (2048) per frame.
    // ------------------------------------------------------------------
    function [10:0] br11(input [10:0] x);
        integer b;
        begin for (b=0;b<11;b=b+1) br11[b] = x[10-b]; end
    endfunction
    reg [10:0] slot = 0;
    reg slot_init = 0;
    integer nassert = 0, nwv = 0, nwr = 0, nfe = 0, nst = 0, ndone = 0;
    integer frame_wr = 0, frame_slots = 0;
    always @(posedge clk) if (u.wv) begin
        nwv = nwv + 1;
        frame_slots = frame_slots + 1;
        // only check the axis on data that is actually captured (wr_ok), after
        // the pipeline has filled; the startup slots are not a real frame.
        if (!u.wr_ok || c2 < 200) begin
            slot <= br11(u.kd3); slot_init <= 1'b0;
        end else begin
            if (slot_init && (br11(u.kd3) !== ((slot + 11'd1) & 11'h7FF))) begin
                nassert = nassert + 1;
                if (nassert <= 5)
                    $display("### ASSERT_FAIL bin_axis c2=%0d k0=%0d br(k0)=%0d expected=%0d",
                             c2, u.kd3, br11(u.kd3), (slot + 11'd1) & 11'h7FF);
            end
            slot <= br11(u.kd3); slot_init <= 1'b1;
        end
        if (u.wr_ok) begin
            if (u.lane !== u.kd3[1:0] || u.waddr[8:0] !== u.kd3[10:2]) begin
                nassert = nassert + 1;
                if (nassert <= 5) $display("### ASSERT_FAIL wr_decode c2=%0d k0=%0d lane=%0d wa=%0d",
                                           c2, u.kd3, u.lane, u.waddr[8:0]);
            end
            nwr = nwr + 1; frame_wr = frame_wr + 1;
        end
    end
    always @(posedge clk) if (u.fend) begin
        nfe = nfe + 1;
        $display("### EV fend n=%0d c2=%0d wbuf=%b wr_ok=%b slots=%0d wr=%0d",
                 nfe, c2, u.wbuf, u.wr_ok, frame_slots, frame_wr);
        if (nfe > 1 && frame_slots != 2048) begin
            nassert = nassert + 1;
            $display("### ASSERT_FAIL frame_len n=%0d slots=%0d", nfe, frame_slots);
        end
        frame_slots = 0; frame_wr = 0;
    end

    // PA done / PB busy events (v4: split engines)
    integer npad = 0; reg pbd = 0;
    always @(posedge clk2) begin
        if (u.ds_pa_done) begin
            npad = npad + 1;
            $display("### EV pa_done n=%0d c2=%0d bank=%b peak=%0d pg=%0d",
                     npad, c2, u.u_ds.bank_pa, u.u_ds.pa_peak_r, u.u_ds.pa_pg_r);
        end
        if (u.ds_pb_busy && !pbd) $display("### EV pb_rise c2=%0d", c2);
        if (!u.ds_pb_busy && pbd) $display("### EV pb_fall c2=%0d", c2);
        pbd <= u.ds_pb_busy;
        if (u.ds_start) $display("### EV ds_start c2=%0d rbuf=%b", c2, u.rbuf);
    end
    reg busy_d = 0;
    always @(posedge clk2) begin
        if (u.ds_busy && !busy_d) $display("### EV busy_rise c2=%0d", c2);
        if (!u.ds_busy && busy_d) $display("### EV busy_fall c2=%0d", c2);
        busy_d <= u.ds_busy;
    end

    // smem dump at pa_done #2 (whole 1024-deep arrays = both frame banks)
    integer ndp = 0; reg dumped = 0;
    reg [63:0] w0, w1, w2, w3;
    always @(posedge clk2) begin
        if (u.ds_pa_done) begin
            ndp = ndp + 1;
            if (ndp == 2 && !dumped) begin : dump_smem
                integer jj;
                dumped = 1'b1;
                fd = $fopen("smem_rtl.txt","w");
                // smem v10 is packed in 64-bit quads:
                //   word k = {s[4k+3], s[4k+2], s[4k+1], s[4k]}.
                // Unpack back to one group per line so cmp_all.py keeps its format.
                for (jj=0;jj<128;jj=jj+1) begin
                    w0 = u.u_ds.L00[jj]; w1 = u.u_ds.L01[jj];
                    w2 = u.u_ds.L02[jj]; w3 = u.u_ds.L03[jj];
                    $fwrite(fd,"%0d %04x %04x %04x %04x\n", 4*jj+0, w0[15:0], w1[15:0], w2[15:0], w3[15:0]);
                    $fwrite(fd,"%0d %04x %04x %04x %04x\n", 4*jj+1, w0[31:16], w1[31:16], w2[31:16], w3[31:16]);
                    $fwrite(fd,"%0d %04x %04x %04x %04x\n", 4*jj+2, w0[47:32], w1[47:32], w2[47:32], w3[47:32]);
                    $fwrite(fd,"%0d %04x %04x %04x %04x\n", 4*jj+3, w0[63:48], w1[63:48], w2[63:48], w3[63:48]);
                    w0 = u.u_ds.L10[jj]; w1 = u.u_ds.L11[jj];
                    w2 = u.u_ds.L12[jj]; w3 = u.u_ds.L13[jj];
                    $fwrite(fd,"%0d %04x %04x %04x %04x\n", 512+4*jj+0, w0[15:0], w1[15:0], w2[15:0], w3[15:0]);
                    $fwrite(fd,"%0d %04x %04x %04x %04x\n", 512+4*jj+1, w0[31:16], w1[31:16], w2[31:16], w3[31:16]);
                    $fwrite(fd,"%0d %04x %04x %04x %04x\n", 512+4*jj+2, w0[47:32], w1[47:32], w2[47:32], w3[47:32]);
                    $fwrite(fd,"%0d %04x %04x %04x %04x\n", 512+4*jj+3, w0[63:48], w1[63:48], w2[63:48], w3[63:48]);
                end
                $fclose(fd);
                $display("### SMEM_DUMP at pa_done #2 c2=%0d bank=%b", c2, u.u_ds.bank_pa);
            end
        end
    end

    reg [12:0] cL,cR,cC; reg [13:0] cBW; reg [15:0] cPK,cTH; reg [23:0] cA; reg cF;
    initial begin
        fc = $fopen("core_sys.txt","w");
        f4 = $fopen("core4_dump.txt","w");
        f5 = $fopen("fe_dump2.txt","w");
        fs2 = $fopen("spec_sync.txt","w");
        cL=0;cR=0;cC=0;cBW=0;cPK=0;cTH=0;cA=0;cF=0;
        for (n=0;n<40;n=n+1) @(posedge clk);
        rst_n = 1;
        for (n=0;n<300000;n=n+1) begin
            @(posedge clk);
            if (u.wv && u.wr_ok) $fwrite(fc,"%0d %06x %06x\n", u.kd3, u.c0r, u.c0i);
            if (n>=5000 && n<7200) $fwrite(f4,"%0d %0d %06x %06x %06x %06x %06x %06x %06x %06x\n",
                n, u.j, u.c0r,u.c0i,u.c1r,u.c1i,u.c2r,u.c2i,u.c3r,u.c3i);
            if (u.ds_busy) nst = nst + 1;
            if (D) begin
                ndone = ndone + 1;
                cL<=L; cR<=R; cC<=C; cBW<=BW; cPK<=PK; cTH<=TH; cA<=A; cF<=F;
                if (ndone==2) begin
                    for (i=0;i<1024;i=i+1) begin
                        $fwrite(fs2,"0 %0d %04x %04x %04x %04x\n", i, u.r03[i], u.r02[i], u.r01[i], u.r00[i]);
                        $fwrite(fs2,"1 %0d %04x %04x %04x %04x\n", i, u.r13[i], u.r12[i], u.r11[i], u.r10[i]);
                        $fwrite(fs2,"2 %0d %04x %04x %04x %04x\n", i, u.r23[i], u.r22[i], u.r21[i], u.r20[i]);
                        $fwrite(fs2,"3 %0d %04x %04x %04x %04x\n", i, u.r33[i], u.r32[i], u.r31[i], u.r30[i]);
                    end
                end
                $display("### DONE%0d t=%0d c2=%0d L=%0d R=%0d BW=%0d C=%0d PK=%0d TH=%0d F=%0d A=%0d bc=%0d rbuf=%b bdone=%b wbuf=%b pg=%0d pr=%0d",
                         ndone, n, c2, L, R, BW, C, PK, TH, F, A, u.u_ds.bc, u.rbuf, u.buf_done, u.wbuf,
                         u.u_ds.peak_g, u.u_ds.peak_r);
            end
            if (ndone>=8) n = 300000;
        end
        while (!u.fend) @(posedge clk);
        for (n=0;n<4;n=n+1) @(posedge clk);
        fd = $fopen("spec_dump.txt","w");
        for (i=0;i<1024;i=i+1) begin
            $fwrite(fd,"0 %0d %04x %04x %04x %04x\n", i, u.r03[i], u.r02[i], u.r01[i], u.r00[i]);
            $fwrite(fd,"1 %0d %04x %04x %04x %04x\n", i, u.r13[i], u.r12[i], u.r11[i], u.r10[i]);
            $fwrite(fd,"2 %0d %04x %04x %04x %04x\n", i, u.r23[i], u.r22[i], u.r21[i], u.r20[i]);
            $fwrite(fd,"3 %0d %04x %04x %04x %04x\n", i, u.r33[i], u.r32[i], u.r31[i], u.r30[i]);
        end
        $fclose(fd);
        $fclose(fc);
        $fclose(f4);
        $fclose(f5);
        $fclose(fs2);
        $display("### TB_END ndone=%0d nwv=%0d nwr=%0d nfend=%0d nbusy=%0d assert_fail=%0d",
                 ndone,nwv,nwr,nfe,nst,nassert);
        $finish;
    end

    // 2026-11-02: LAT 自检
    always @(posedge clk2) if (u.o_done) $display("### LAT cyc=%0d ns=%0d", u.o_lat, u.o_lat*8);
endmodule
