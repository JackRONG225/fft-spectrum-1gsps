// ds4.v -- v10 (duty100): 4-groups/clk2 pass-B walk, packed 64-bit smem words
//
// Schedule (unchanged since v4):
//   PA engine : spectrum bank k -> 4x 256-bin sliding windows -> smem bank k + peak
//   PB engine : smem bank k -> left/right threshold walk -> report fields
//   PA(k+1) overlaps PB(k) because smem is double banked (bank = frame parity).
//
// v10 (experiment u100, real 100%): the walk now visits 4 GROUPS per clk2 on BOTH
// sides, independent of signal shape, so PB <= ~520 clk2 for any input (<= 1024).
//
//   * smem word is 64 bit = FOUR adjacent groups: word k of quadrant y holds
//     {s[512y+4k+3], s[512y+4k+2], s[512y+4k+1], s[512y+4k]}.  A quadrant still
//     stores 512 groups, so the arrays are 128x64 instead of 256x32: the total
//     smem bit count is IDENTICAL (128*64 == 256*32), LUTRAM does not grow.
//   * the left walk needs the chunk (q, q-1, q-2, q-3) as one word -> aligned when
//     q % 4 == 3; the right walk needs (pr, pr+1, pr+2, pr+3) -> aligned when
//     pr % 4 == 0.  Each side therefore does 0..3 single-group pre-steps (in visit
//     order pg, pg+-1, ...), then one 4-group decision per clk2.
//   * decision is still "first group below thr from the inside out", so a stop at
//     offset i sets pl=q-i (left) / pr=pr+i (right); L/R/BW/C are unchanged.
//   * read path: pointer -> address -> LUTRAM mux -> 64-bit register; decision path:
//     register -> 4 comparators + priority -> pointer.  One 8 ns cycle each.
//
// WALK LIMIT: model4.py walks at most 2600 groups per side.  A walk that has tested
// a full circle (2048 groups) without finding a group below thr means the whole
// 8192-bin band is occupied: that frame is reported as FULL BAND, not as a wrapped
// pointer:  L=0, R=8191, BW=8192, C=4096.  This is an explicit saturation result for
// the only case where a -3 dB boundary does not exist; every frame that has a real
// boundary anywhere in the circle reports the true boundary (b8 could not: its cap
// was 1300 cycles = 2600 groups, and its 1300-cycle cap made an unterminated walk
// run 1301 clk2 -> N=2).
//
// Bank lifetime: PA(k+2) overwrites smem bank k parity at f_k+2048+72, PB(k) starts
// at f_k+591, so PB must finish within ~1385 clk2.  Worst case here is a full circle
// at 4 groups/clk2 = 512 clk2 (+3 pre-steps + 2 finish) -> ~517, safe.
`timescale 1ns/1ps
module ds4 (
    input  wire clk, rst_n,
    input  wire start,
    input  wire bank,             // smem frame bank for this frame (parity)
    output reg  busy,             // pass A busy
    output wire [8:0] ra,
    input  wire [63:0] rw0,       // quadrant 0 word at address ra (bins 4w..4w+3)
    input  wire [63:0] rw1,
    input  wire [63:0] rw2,
    input  wire [63:0] rw3,
    output reg  done,
    output reg  [12:0] o_left, o_right, o_center,
    output reg  [13:0] o_bw,
    output reg  [15:0] o_peak, o_thr,
    output reg  found,
    output reg  pa_done,          // 1-cycle pulse: smem bank 'bank' complete
    output reg  pb_busy
);
    localparam IDLE=2'd0, P0=2'd1, PA=2'd2;
    localparam PIDLE=2'd0, PRUN=2'd1, PFIN=2'd2, PFIN2=2'd3;
    localparam [10:0] STORE_OFF = 11'd0;

    reg [1:0] st;
    reg [8:0] a;
    assign ra = a;

    // ---------------- 4-lane magnitude sums of the four quadrant words ------
    wire [17:0] sw0 = {2'b00,rw0[15:0]} + {2'b00,rw0[31:16]} + {2'b00,rw0[47:32]} + {2'b00,rw0[63:48]};
    wire [17:0] sw1 = {2'b00,rw1[15:0]} + {2'b00,rw1[31:16]} + {2'b00,rw1[47:32]} + {2'b00,rw1[63:48]};
    wire [17:0] sw2 = {2'b00,rw2[15:0]} + {2'b00,rw2[31:16]} + {2'b00,rw2[47:32]} + {2'b00,rw2[63:48]};
    wire [17:0] sw3 = {2'b00,rw3[15:0]} + {2'b00,rw3[31:16]} + {2'b00,rw3[47:32]} + {2'b00,rw3[63:48]};

    // ---------------- per-stream 64-word ring + accumulator -----------------
    reg [17:0] dly0 [0:63];
    reg [17:0] dly1 [0:63];
    reg [17:0] dly2 [0:63];
    reg [17:0] dly3 [0:63];
    reg [25:0] acc0, acc1, acc2, acc3;

    reg [1:0] vp;
    reg [8:0] ad1, ad2;
    wire vok = vp[1];

    wire [17:0] x0 = (st == P0) ? sw3 : sw0;
    wire [17:0] x1 = (st == P0) ? sw0 : sw1;
    wire [17:0] x2 = (st == P0) ? sw1 : sw2;
    wire [17:0] x3 = (st == P0) ? sw2 : sw3;

    reg [17:0] swr0, swr1, swr2, swr3;      // S1
    reg [17:0] swq0, swq1, swq2, swq3;      // S2
    reg [17:0] oldr0, oldr1, oldr2, oldr3;  // S2 ring read
    reg [25:0] nwr0, nwr1, nwr2, nwr3;      // S3 window sums
    reg [15:0] mar;                         // S4 max candidate value
    reg [10:0] iar;                         // S4 max candidate store index

    reg [8:0] a1, a2, a3, a4;
    reg v1, v2, v3, v4;

    wire [5:0] rix = a1[5:0];
    wire [25:0] nw0 = acc0 + {8'd0, swq0} - {8'd0, oldr0};
    wire [25:0] nw1 = acc1 + {8'd0, swq1} - {8'd0, oldr1};
    wire [25:0] nw2 = acc2 + {8'd0, swq2} - {8'd0, oldr2};
    wire [25:0] nw3 = acc3 + {8'd0, swq3} - {8'd0, oldr3};

    wire [10:0] aoff = {2'b00, a3} + STORE_OFF;
    wire [8:0]  wa   = aoff[8:0];
    wire [1:0]  cary = aoff[10:9];

    // ---------------- smem: 16 arrays of 128x64 (packed quads) ---------------
    // Lxy = left read copy (x = frame bank, y = quadrant), Rxy = right read copy.
    // word k of quadrant y = {s[512y+4k+3], s[512y+4k+2], s[512y+4k+1], s[512y+4k]}.
    reg [63:0] L00 [0:127];  reg [63:0] L01 [0:127];  reg [63:0] L02 [0:127];  reg [63:0] L03 [0:127];
    reg [63:0] L10 [0:127];  reg [63:0] L11 [0:127];  reg [63:0] L12 [0:127];  reg [63:0] L13 [0:127];
    reg [63:0] R00 [0:127];  reg [63:0] R01 [0:127];  reg [63:0] R02 [0:127];  reg [63:0] R03 [0:127];
    reg [63:0] R10 [0:127];  reg [63:0] R11 [0:127];  reg [63:0] R12 [0:127];  reg [63:0] R13 [0:127];
    // write staging: a PA group arrives every cycle; three 16-bit stages hold
    // groups 4k, 4k+1, 4k+2 until group 4k+3 arrives and one 64-bit word is written.
    // (single driver: this block only -- see docs/缺陷_打包smem上板失效.md)
    reg [15:0] stg0a, stg0b, stg0c;
    reg [15:0] stg1a, stg1b, stg1c;
    reg [15:0] stg2a, stg2b, stg2c;
    reg [15:0] stg3a, stg3b, stg3c;

    reg bank_pa;

    // ---------------- pass B registers -------------------------------------
    reg [1:0] pst;
    reg [10:0] pl, pr;            // left/right stop pointers
    reg [10:0] q;                 // left candidate position
    reg dl, dr;
    reg full;                     // whole circle above thr -> BW=8192
    reg [11:0] bc;                // PRUN cycles (log / safety cap)
    reg [11:0] cntL, cntR;        // groups tested (passed) on each side
    reg [1:0]  preL, preR;        // single-group pre-steps left before a 4-group chunk
    reg [15:0] thr_pb, peak_pb;
    reg [10:0] pg_pb;
    reg pb_bank;
    reg [15:0] pa_peak_r; reg [10:0] pa_pg_r; reg pa_bank_r; reg pa_req;

    reg prime;                    // first PRUN cycle: capture, do not decide
    reg [63:0] lwd, rwd;          // registered smem words (read one cycle ahead)

    // Prefetch address: in prime read the word that holds the starting group; in a
    // decision cycle read the word that will hold the NEXT chunk / pre-step group.
    wire [10:0] lptr = prime ? q : ((preL != 2'd0) ? (q - 11'd1) : (q - 11'd4));
    wire [10:0] rptr = prime ? pr : ((preR != 2'd0) ? (pr + 11'd1) : (pr + 11'd4));

    reg [63:0] rdL, rdR;
    always @(*) begin
        if (pb_bank) begin
            case (lptr[10:9])
              2'd0: rdL = L10[lptr[8:2]];
              2'd1: rdL = L11[lptr[8:2]];
              2'd2: rdL = L12[lptr[8:2]];
              default: rdL = L13[lptr[8:2]];
            endcase
            case (rptr[10:9])
              2'd0: rdR = R10[rptr[8:2]];
              2'd1: rdR = R11[rptr[8:2]];
              2'd2: rdR = R12[rptr[8:2]];
              default: rdR = R13[rptr[8:2]];
            endcase
        end else begin
            case (lptr[10:9])
              2'd0: rdL = L00[lptr[8:2]];
              2'd1: rdL = L01[lptr[8:2]];
              2'd2: rdL = L02[lptr[8:2]];
              default: rdL = L03[lptr[8:2]];
            endcase
            case (rptr[10:9])
              2'd0: rdR = R00[rptr[8:2]];
              2'd1: rdR = R01[rptr[8:2]];
              2'd2: rdR = R02[rptr[8:2]];
              default: rdR = R03[rptr[8:2]];
            endcase
        end
    end

    // single-group lane select inside a registered 64-bit word (pre-step decisions)
    reg [15:0] lpre, rpre;
    always @(*) begin
        case (q[1:0])
          2'd0: lpre = lwd[15:0];
          2'd1: lpre = lwd[31:16];
          2'd2: lpre = lwd[47:32];
          default: lpre = lwd[63:48];
        endcase
        case (pr[1:0])
          2'd0: rpre = rwd[15:0];
          2'd1: rpre = rwd[31:16];
          2'd2: rpre = rwd[47:32];
          default: rpre = rwd[63:48];
        endcase
    end

    // ---------------- report ------------------------------------------------
    reg [15:0] peak_r; reg [10:0] peak_g;
    integer ii;

    wire [13:0] L_bin = {2'b00,pl,2'b00} + 14'd4;
    wire [13:0] R_bin = {2'b00,pr,2'b00} - 14'd1;
    wire [13:0] bw_c  = (R_bin >= L_bin) ? (R_bin - L_bin + 14'd1)
                                         : (R_bin + 14'd8192 - L_bin + 14'd1);

    // ---------------- S4 peak candidates ------------------------------------
    wire [15:0] wv0 = nwr0[23:8], wv1 = nwr1[23:8], wv2 = nwr2[23:8], wv3 = nwr3[23:8];
    wire        c01 = (wv0 >= wv1);
    wire [15:0] mx01 = c01 ? wv0 : wv1;
    wire        c23 = (wv2 >= wv3);
    wire [15:0] mx23 = c23 ? wv2 : wv3;
    wire        cA  = (mx01 >= mx23);
    wire [15:0] mxA = cA ? mx01 : mx23;
    wire [10:0] gq0 = {cary + 2'd0, wa};
    wire [10:0] gq1 = {cary + 2'd1, wa};
    wire [10:0] gq2 = {cary + 2'd2, wa};
    wire [10:0] gq3 = {cary + 2'd3, wa};
    wire [10:0] i01 = c01 ? gq0 : gq1;
    wire [10:0] i23 = c23 ? gq2 : gq3;
    wire [10:0] iA  = cA  ? i01 : i23;
    wire [15:0] pkb = (mar > peak_r) ? mar : peak_r;
    wire [10:0] pgb = (mar > peak_r) ? iar : peak_g;

    initial begin
        for (ii=0;ii<64;ii=ii+1) begin
            dly0[ii]=18'd0; dly1[ii]=18'd0; dly2[ii]=18'd0; dly3[ii]=18'd0;
        end
        for (ii=0;ii<128;ii=ii+1) begin
            L00[ii]=64'd0; L01[ii]=64'd0; L02[ii]=64'd0; L03[ii]=64'd0;
            L10[ii]=64'd0; L11[ii]=64'd0; L12[ii]=64'd0; L13[ii]=64'd0;
            R00[ii]=64'd0; R01[ii]=64'd0; R02[ii]=64'd0; R03[ii]=64'd0;
            R10[ii]=64'd0; R11[ii]=64'd0; R12[ii]=64'd0; R13[ii]=64'd0;
        end
    end

    // ---------------- smem write: one 64-bit word per four PA groups ---------
    always @(posedge clk) if (!rst_n) begin
        stg0a<=16'd0; stg0b<=16'd0; stg0c<=16'd0;
        stg1a<=16'd0; stg1b<=16'd0; stg1c<=16'd0;
        stg2a<=16'd0; stg2b<=16'd0; stg2c<=16'd0;
        stg3a<=16'd0; stg3b<=16'd0; stg3c<=16'd0;
    end else if (v3 && (st == PA)) begin
        case (wa[1:0])
          2'd0: begin
              stg0a<=nwr0[23:8]; stg1a<=nwr1[23:8]; stg2a<=nwr2[23:8]; stg3a<=nwr3[23:8];
          end
          2'd1: begin
              stg0b<=nwr0[23:8]; stg1b<=nwr1[23:8]; stg2b<=nwr2[23:8]; stg3b<=nwr3[23:8];
          end
          2'd2: begin
              stg0c<=nwr0[23:8]; stg1c<=nwr1[23:8]; stg2c<=nwr2[23:8]; stg3c<=nwr3[23:8];
          end
          default: begin
              if (bank_pa) begin
                  L10[wa[8:2]] <= {nwr0[23:8], stg0c, stg0b, stg0a};
                  L11[wa[8:2]] <= {nwr1[23:8], stg1c, stg1b, stg1a};
                  L12[wa[8:2]] <= {nwr2[23:8], stg2c, stg2b, stg2a};
                  L13[wa[8:2]] <= {nwr3[23:8], stg3c, stg3b, stg3a};
                  R10[wa[8:2]] <= {nwr0[23:8], stg0c, stg0b, stg0a};
                  R11[wa[8:2]] <= {nwr1[23:8], stg1c, stg1b, stg1a};
                  R12[wa[8:2]] <= {nwr2[23:8], stg2c, stg2b, stg2a};
                  R13[wa[8:2]] <= {nwr3[23:8], stg3c, stg3b, stg3a};
              end else begin
                  L00[wa[8:2]] <= {nwr0[23:8], stg0c, stg0b, stg0a};
                  L01[wa[8:2]] <= {nwr1[23:8], stg1c, stg1b, stg1a};
                  L02[wa[8:2]] <= {nwr2[23:8], stg2c, stg2b, stg2a};
                  L03[wa[8:2]] <= {nwr3[23:8], stg3c, stg3b, stg3a};
                  R00[wa[8:2]] <= {nwr0[23:8], stg0c, stg0b, stg0a};
                  R01[wa[8:2]] <= {nwr1[23:8], stg1c, stg1b, stg1a};
                  R02[wa[8:2]] <= {nwr2[23:8], stg2c, stg2b, stg2a};
                  R03[wa[8:2]] <= {nwr3[23:8], stg3c, stg3b, stg3a};
              end
          end
        endcase
    end

    // ---------------- main FSM (PA + PB) --------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            st<=IDLE; pst<=PIDLE; busy<=0; done<=0; a<=9'd448; vp<=0; ad1<=9'd0; ad2<=9'd0;
            acc0<=0; acc1<=0; acc2<=0; acc3<=0;
            peak_r<=0; peak_g<=0;
            pl<=0; pr<=0; q<=0; dl<=0; dr<=0; bc<=0; full<=0; prime<=1'b1;
            cntL<=0; cntR<=0; preL<=0; preR<=0;
            thr_pb<=0; peak_pb<=0; pg_pb<=0; pb_bank<=0;
            pa_peak_r<=0; pa_pg_r<=0; pa_bank_r<=0; pa_req<=0;
            o_left<=0; o_right<=0; o_center<=0; o_bw<=0; o_peak<=0; o_thr<=0;
            found<=0;
            swr0<=0; swr1<=0; swr2<=0; swr3<=0;
            swq0<=0; swq1<=0; swq2<=0; swq3<=0;
            oldr0<=0; oldr1<=0; oldr2<=0; oldr3<=0;
            nwr0<=0; nwr1<=0; nwr2<=0; nwr3<=0;
            mar<=0; iar<=0; a1<=0; a2<=0; a3<=0; a4<=0;
            v1<=0; v2<=0; v3<=0; v4<=0;
            pa_done<=0; pb_busy<=0; bank_pa<=0; lwd<=0; rwd<=0;
        end else begin
            done <= 1'b0;
            pa_done <= 1'b0;

            // registered smem read data (asynchronous LUTRAM -> register)
            lwd <= rdL; rwd <= rdR;

            // ================= pass A =================
            case (st)
            IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    st<=P0; busy<=1'b1; bank_pa<=bank;
                    a<=9'd448; vp<=2'd0; ad1<=9'd448; ad2<=9'd448;
                    peak_r<=0; peak_g<=0;
                    acc0<=26'd0; acc1<=26'd0; acc2<=26'd0; acc3<=26'd0;
                    a1<=9'd0; a2<=9'd0; a3<=9'd0; a4<=9'd0;
                    v1<=0; v2<=0; v3<=0; v4<=0;
                end
            end

            P0: begin
                if (a != 9'd511) a <= a + 1'b1;
                vp <= {vp[0], 1'b1};
                ad1 <= a; ad2 <= ad1;
                v1<=vok; v2<=v1; v3<=v2; v4<=v3;
                a1<=ad2; a2<=a1; a3<=a2; a4<=a3;
                swr0<=x0; swr1<=x1; swr2<=x2; swr3<=x3;
                oldr0<=dly0[rix]; oldr1<=dly1[rix]; oldr2<=dly2[rix]; oldr3<=dly3[rix];
                swq0<=swr0; swq1<=swr1; swq2<=swr2; swq3<=swr3;
                if (v2) begin
                    dly0[a2[5:0]] <= swq0;
                    dly1[a2[5:0]] <= swq1;
                    dly2[a2[5:0]] <= swq2;
                    dly3[a2[5:0]] <= swq3;
                    acc0 <= acc0 + {8'd0, swq0};
                    acc1 <= acc1 + {8'd0, swq1};
                    acc2 <= acc2 + {8'd0, swq2};
                    acc3 <= acc3 + {8'd0, swq3};
                    if (a2 == 9'd511) begin
                        st<=PA; a<=9'd0; vp<=2'd0; ad1<=9'd0; ad2<=9'd0;
                        a1<=9'd0; a2<=9'd0; a3<=9'd0; a4<=9'd0;
                        v1<=0; v2<=0; v3<=0; v4<=0;
                    end
                end
            end

            PA: begin
                if (a != 9'd511) a <= a + 1'b1;
                vp <= {vp[0], 1'b1};
                ad1 <= a; ad2 <= ad1;
                v1<=vok; v2<=v1; v3<=v2; v4<=v3;
                a1<=ad2; a2<=a1; a3<=a2; a4<=a3;
                swr0<=x0; swr1<=x1; swr2<=x2; swr3<=x3;
                oldr0<=dly0[rix]; oldr1<=dly1[rix]; oldr2<=dly2[rix]; oldr3<=dly3[rix];
                swq0<=swr0; swq1<=swr1; swq2<=swr2; swq3<=swr3;

                if (v2) begin
                    dly0[a2[5:0]] <= swq0;
                    dly1[a2[5:0]] <= swq1;
                    dly2[a2[5:0]] <= swq2;
                    dly3[a2[5:0]] <= swq3;
                    acc0 <= nw0; acc1 <= nw1; acc2 <= nw2; acc3 <= nw3;
                    nwr0 <= nw0; nwr1 <= nw1; nwr2 <= nw2; nwr3 <= nw3;
                end

                if (v3) begin
                    mar <= mxA; iar <= iA;
                end

                if (v4) begin
                    if (mar > peak_r) begin peak_r <= mar; peak_g <= iar; end
                    if (a4 == 9'd511) begin
                        st<=IDLE; busy<=1'b0; pa_done<=1'b1;
                        pa_peak_r <= pkb; pa_pg_r <= pgb; pa_bank_r <= bank_pa; pa_req <= 1'b1;
                    end
                end
            end
            default: st <= IDLE;
            endcase

            // ================= pass B =================
            case (pst)
            PIDLE: begin
                pb_busy <= 1'b0;
                if (pa_req) begin
                    pa_req <= 1'b0;
                    pst <= PRUN; pb_busy <= 1'b1;
                    pl <= pa_pg_r; pr <= pa_pg_r; q <= pa_pg_r;
                    dl <= 0; dr <= 0; full <= 0; bc <= 0; prime <= 1'b1;
                    // pre-steps to align the first 4-group chunk:
                    //   left  needs q%4==3  -> (3 - pg%4) mod 4
                    //   right needs pr%4==0 -> (-pg) mod 4
                    preL <= (pa_pg_r[1:0] == 2'd3) ? 2'd0 : (pa_pg_r[1:0] + 2'd1);
                    preR <= (2'd0 - pa_pg_r[1:0]);
                    cntL <= 0; cntR <= 0;
                    thr_pb <= pa_peak_r >> 1; peak_pb <= pa_peak_r;
                    pg_pb <= pa_pg_r; pb_bank <= pa_bank_r;
                end
            end

            PRUN: begin
                if (!prime) begin
                    // ---- left side: one pre-step group, or one 4-group chunk ----
                    if (!dl) begin
                        if (preL != 2'd0) begin
                            if (lpre < thr_pb) begin pl <= q; dl <= 1'b1; end
                            else begin
                                q <= q - 1'b1; preL <= preL - 1'b1; cntL <= cntL + 1'b1;
                                if ((cntL + 12'd1) >= 12'd2048) begin full <= 1'b1; dl <= 1'b1; dr <= 1'b1; end
                            end
                        end else begin
                            if      (lwd[63:48] < thr_pb) begin pl <= q;     dl <= 1'b1; end
                            else if (lwd[47:32] < thr_pb) begin pl <= q - 1; dl <= 1'b1; end
                            else if (lwd[31:16] < thr_pb) begin pl <= q - 2; dl <= 1'b1; end
                            else if (lwd[15:0]  < thr_pb) begin pl <= q - 3; dl <= 1'b1; end
                            else begin
                                q <= q - 4; cntL <= cntL + 4;
                                if ((cntL + 12'd4) >= 12'd2048) begin full <= 1'b1; dl <= 1'b1; dr <= 1'b1; end
                            end
                        end
                    end
                    // ---- right side: one pre-step group, or one 4-group chunk ---
                    if (!dr) begin
                        if (preR != 2'd0) begin
                            if (rpre < thr_pb) begin dr <= 1'b1; end
                            else begin
                                pr <= pr + 1'b1; preR <= preR - 1'b1; cntR <= cntR + 1'b1;
                                if ((cntR + 12'd1) >= 12'd2048) begin full <= 1'b1; dl <= 1'b1; dr <= 1'b1; end
                            end
                        end else begin
                            if      (rwd[15:0]  < thr_pb) begin dr <= 1'b1; end
                            else if (rwd[31:16] < thr_pb) begin pr <= pr + 1; dr <= 1'b1; end
                            else if (rwd[47:32] < thr_pb) begin pr <= pr + 2; dr <= 1'b1; end
                            else if (rwd[63:48] < thr_pb) begin pr <= pr + 3; dr <= 1'b1; end
                            else begin
                                pr <= pr + 4; cntR <= cntR + 4;
                                if ((cntR + 12'd4) >= 12'd2048) begin full <= 1'b1; dl <= 1'b1; dr <= 1'b1; end
                            end
                        end
                    end
                end
                prime <= 1'b0;
                bc <= bc + 1'b1;
                // wc-style guarantee is structural (at most 512 chunk cycles); the
                // only safety net is bc>700, unreachable but inside the bank lifetime.
                if ((dl && dr) || bc > 12'd700) pst <= PFIN;
            end

            PFIN: begin
                if (full) begin
                    o_left   <= 13'd0;
                    o_right  <= 13'd8191;
                    o_bw     <= 14'd8192;
                end else begin
                    o_left   <= L_bin[12:0];
                    o_right  <= R_bin[12:0];
                    o_bw     <= bw_c;
                end
                o_peak   <= peak_pb;
                o_thr    <= thr_pb;
                found    <= (peak_pb != 16'd0);
                pst <= PFIN2;
            end

            PFIN2: begin
                if (full) o_center <= 13'd4096;
                else o_center <= (L_bin[12:0] + {1'b0,bw_c[13:1]} >= 14'd8192) ?
                            (L_bin[12:0] + {1'b0,bw_c[13:1]} - 14'd8192) : (L_bin[12:0] + {1'b0,bw_c[13:1]});
                done <= 1'b1; pb_busy <= 1'b0; pst <= PIDLE;
            end
            default: pst <= PIDLE;
            endcase
        end
    end
endmodule
