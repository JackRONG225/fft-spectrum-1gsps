// board_top_4lane.v -- DaVinci Artix-7 board top for the 4-lane 8192-point chain.
// 50 MHz -> MMCM -> clk_f (= fs/4, high speed domain) + clk_h (= clk_f/2).
// ROM vectors on chip, UART report on T6 (UART + report run on clk_h).
`timescale 1ns/1ps
module board_top_4lane (
    input  wire sys_clk,
    input  wire sys_rst_n,
    output wire uart_txd,
    output wire led0
);
    wire clk_f, clk_h, locked;
    clk_wiz_0 u_clk_wiz (
        .clk_in1(sys_clk), .resetn(sys_rst_n), .locked(locked),
        .clk_out1(clk_f), .clk_out2(clk_h)
    );

    (* max_fanout = 16 *) reg rst_n_r;
    always @(posedge clk_f) rst_n_r <= locked & sys_rst_n;
    wire rst_n = rst_n_r;

    (* max_fanout = 16 *) reg rst_n_h_r;
    always @(posedge clk_h) rst_n_h_r <= locked & sys_rst_n;
    wire rst_n_h = rst_n_h_r;

    wire [12:0] o_left,o_right,o_center;
    wire [12:0] o_lat;
    wire [13:0] o_bw;
    wire [15:0] o_peak,o_thr,o_done_cnt;
    wire [23:0] o_amp;
    wire o_found,o_done;

    sys4_top u_sys (
        .clk(clk_f), .clk2(clk_h), .rst_n(rst_n),
        .o_left(o_left), .o_right(o_right), .o_center(o_center), .o_bw(o_bw),
        .o_peak(o_peak), .o_thr(o_thr), .o_amp(o_amp), .o_found(o_found),
        .o_done(o_done), .o_done_cnt(o_done_cnt), .o_lat(o_lat)
    );

    // 2026-10-24：片上测温（XADC）方案已放弃（试综合 WNS=-0.357，见报告目录），
    // 温度端口固定接 0，报文也不再输出 T 域；测温模块源码保留在 rtl/ 仅备查，不参与综合。
    wire [7:0] tx_byte; wire tx_valid, tx_busy, rpt_busy;
    wire [15:0] o_lat_ns = {o_lat, 3'b000};   // 拍 × 8 ns
    report_fmt4 u_rpt (
        .clk(clk_h), .rst_n(rst_n_h), .done(o_done),
        .bw(o_bw), .center(o_center), .amp(o_amp), .left(o_left), .right(o_right),
        .peak(o_peak), .thr(o_thr), .found(o_found), .temp(8'd0), .frm(14'd8192), .dcnt(o_done_cnt),
        .lat(o_lat_ns),
        .uart_busy(tx_busy), .tx_byte(tx_byte), .tx_valid(tx_valid), .busy(rpt_busy)
    );

`ifdef CLK2_FREQ_MHZ
    localparam integer CLK_HZ = `CLK2_FREQ_MHZ * 1_000_000;
`else
    localparam integer CLK_HZ = 100_000_000;
`endif
    uart_tx #(.CLK_FREQ(CLK_HZ)) u_uart (
        .clk(clk_h), .rst_n(rst_n_h), .tx_start(tx_valid), .tx_data(tx_byte),
        .tx_busy(tx_busy), .txd(uart_txd)
    );

    assign led0 = o_done_cnt[3];
endmodule
