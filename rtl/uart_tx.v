// ==========================================================================
//  uart_tx.v —— UART 发送器（8N1：1 起始位 + 8 数据位 + 1 停止位，无校验）
//
//  口径沿用 deliver_260MSPS/02_src/rtl/uart_tx.v：
//    115200 bps，板载 USB 转串口，TXD = T6（LVCMOS33，达芬奇 xc7a35tfgg484-2）
//
//  与 260 版的三处改动（TX 字节流完全不变）：
//    1) 分频做成参数：CLK_FREQ / BAUD 自动算，另留 CLK_DIV 直接覆盖
//       （默认 0 = 自动）。本档 250e6/115200 = 2170 ⇒ 实际 115207.4 bps
//       （+0.0064%，接收端 2% 容差内，可忽略）。
//       仿真时给 CLK_DIV=4 之类的小值，波形才跑得动。
//    2) 复位改【同步复位】：always @(posedge clk) + if (!rst_n)，
//       与 ds2_sys.v 的 FSM 段写法一致。260 版是异步复位。250 MHz 下同步
//       复位不占复位网络，也没有复位释放的 recovery/removal 问题。
//    3) tx_busy 一直保持到【停止位发完】才撤（260 版在停止位刚开始就撤），
//       一帧 busy 正好 10 个位时间。这样反压方（report_fmt2）不需要额外的
//       "等 busy 起来" 的隔离拍就能对准，握手是自同步的。
//
//  时序约定：
//    · 一位 = DIV 个 clk；空闲 txd = 1
//    · tx_start 必须是【单拍脉冲】；tx_busy=1 期间的 tx_start 直接忽略
//    · t0 拍 tx_start=1（此时 tx_busy=0）→ t0+1 拍 txd 拉低（起始位起点）
//      → 第 10 个位时间结束撤 tx_busy，同时 txd 回 1
//
//  资源：约 20 LUT / 33 FF（16 位分频计数 + 4 位位计数 + 10 位移位），无 DSP/BRAM。
// ==========================================================================
`timescale 1ns / 1ps

module uart_tx #(
    parameter integer CLK_FREQ = 250_000_000,   // 时钟频率（Hz）
    parameter integer BAUD     = 115200,        // 目标波特率
    parameter integer CLK_DIV  = 0              // >0 时直接指定分频（仿真用）
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       tx_start,     // 单拍脉冲：启动一次发送
    input  wire [7:0] tx_data,      // 待发字节（tx_start 当拍有效）
    output reg        tx_busy,      // 发送中（含停止位）
    output reg        txd           // 串行输出，空闲为 1
);

    // 分频值：CLK_DIV>0 时用它，否则由 CLK_FREQ/BAUD 算
    localparam integer DIV = (CLK_DIV > 0) ? CLK_DIV : (CLK_FREQ / BAUD);

    // 分频计数用 16 bit：250 MHz 下最低约 3815 bps（DIV<=65535），
    // 115200 / 57600 / 38400 / 19200 / 9600 全都在范围内。
    reg [15:0] div_cnt;
    reg [3:0]  bit_idx;
    reg [9:0]  shifter;         // {停止位, data[7:0], 起始位}

    always @(posedge clk) begin
        if (!rst_n) begin
            div_cnt <= 16'd0;
            bit_idx <= 4'd0;
            shifter <= 10'h3FF;         // 全 1：空闲
            tx_busy <= 1'b0;
            txd     <= 1'b1;
        end else if (!tx_busy) begin
            txd <= 1'b1;                // 空闲保持高
            if (tx_start) begin
                shifter <= {1'b1, tx_data, 1'b0};
                tx_busy <= 1'b1;
                bit_idx <= 4'd0;
                div_cnt <= 16'd0;
                txd     <= 1'b0;        // 起始位当拍就拉低，位宽仍是 DIV 拍
            end
        end else begin
            if (div_cnt == DIV - 1) begin
                div_cnt <= 16'd0;
                if (bit_idx == 4'd9) begin
                    tx_busy <= 1'b0;    // 停止位结束
                    bit_idx <= 4'd0;
                    txd     <= 1'b1;
                end else begin
                    bit_idx <= bit_idx + 4'd1;
                    shifter <= {1'b1, shifter[9:1]};
                    txd     <= shifter[1];  // 下一比特（移位前的 shifter[1]）
                end
            end else begin
                div_cnt <= div_cnt + 16'd1;
            end
        end
    end

endmodule
