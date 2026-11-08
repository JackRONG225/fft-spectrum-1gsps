// ==========================================================================
//  mag_sq24.v —— 平方谱 |I|^2 + |Q|^2（2026-10-20 晚 第二版：单 DSP / 13 bit）
//
//  【为什么要改】第一版是 24x24 全宽平方（每个平方 2 个 DSP 级联）。
//  300 MHz 实测：唯一失败路径就是那 4 对 DSP 的 PCOUT->PCIN 级联，
//  即使把两个 DSP 钉成同列相邻（route 只剩 0.056 ns），**纯逻辑仍有 2.096 ns**
//  —— 那是 DSP48E1 -2 的 Tcko(PCOUT) 固定延时，加 PCIN 建立时间约 1.2 ns，
//  这条链在本器件的物理下限就是 ~3.3 ns。**级联本身不可救，只能不用级联。**
//
//  【关键观察】输出只取 sum[23:8]（16 bit）并饱和：
//      sat = (|I|^2+|Q|^2 >= 2^24)        ⇒ mag16 = 0xFFFF
//  也就是说 **只要 |I| 或 |Q| >= 4096，输出必然是 0xFFFF**，具体数值无意义。
//  所以平方器只需要在 |I|,|Q| < 4096（**13 bit 有符号，-4096..4095**）时精确：
//      · |I| < 4096  ⇒ I^2 < 2^24 ⇒ 13x13 乘法 = **1 个 DSP，无级联**
//      · |I| >= 4096 ⇒ 置 sat 标志（此时两路平方和必然 >= 2^24），操作数随便
//  数值上是**逐位等价**的：
//      · 小幅度：13 bit 截位无损（24 bit 值的低 13 bit 就是原值），乘积/sum/mag16 全等；
//      · 大幅度：老版 sat 也一定为 1（I^2 >= 2^24 ⇒ sum >= 2^24），两版都输出 0xFFFF。
//  代价：DSP **每路 2 -> 1**（4 路共 8 -> 4，全设计 60 -> 56），并且少了 48 bit 乘积寄存器。
//
//  【流水】仍 4 级，与第一版**完全同延迟**（所以 fe2lane_mag 的 wbase=3792 不用改）：
//      s1 i1/q1 + 幅度标志  -> s2 两个 13x13 乘积（DSP） -> s3 26 bit 求和 + sat -> s4 mag16
//
//  【为什么用 "bit12 以上是否等于符号扩展" 判大幅度】
//      13 bit 有符号能表示 -4096..4095，恰好就是"精确区"。
//      big = |(i[23:13] ^ {11{i[12]}})  —— 11 bit 或归约，2 个 LUT，比 24 bit 比较便宜。
// ==========================================================================
`timescale 1ns / 1ps

module mag_sq24 #(
    parameter integer SHIFT = 8
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,
    input  wire signed [23:0] i_in,
    input  wire signed [23:0] q_in,

    output reg  [15:0]        mag16,     // sum[SHIFT+15:SHIFT]，饱和到 0xFFFF
    output reg                valid_out
);

    // ---------------- s1：输入寄存 + 大幅度判定 ----------------
    reg signed [23:0] i1, q1;
    reg               ibig1, qbig1;
    reg               v1;

    wire ibig_c = |(i_in[23:13] ^ {11{i_in[12]}});
    wire qbig_c = |(q_in[23:13] ^ {11{q_in[12]}});

    always @(posedge clk) begin
        if (!rst_n) begin
            i1 <= 24'sd0; q1 <= 24'sd0;
            ibig1 <= 1'b0; qbig1 <= 1'b0; v1 <= 1'b0;
        end else begin
            i1 <= i_in; q1 <= q_in;
            ibig1 <= ibig_c; qbig1 <= qbig_c;
            v1 <= valid_in;
        end
    end

    // ---------------- s2：两个 13x13 平方（各 1 个 DSP，无级联） ----------------
    // 注意：Verilog 的 part-select 是**无符号**的，直接写 i1[12:0]*i1[12:0]
    // 会变成无符号乘法（负值被当成 8092 这种大正数），必须显式转 signed。
    wire signed [12:0] i13_c = i1[12:0];
    wire signed [12:0] q13_c = q1[12:0];

    reg signed [25:0] pi_r, pq_r;
    reg               ibig2, qbig2;
    reg               v2;

    always @(posedge clk) begin
        if (!rst_n) begin
            pi_r <= 26'sd0; pq_r <= 26'sd0;
            ibig2 <= 1'b0; qbig2 <= 1'b0; v2 <= 1'b0;
        end else begin
            // 小幅度时 i1[12:0] 就是 i1 本身（13 bit 有符号无损）
            pi_r <= i13_c * i13_c;
            pq_r <= q13_c * q13_c;
            ibig2 <= ibig1; qbig2 <= qbig1;
            v2 <= v1;
        end
    end

    // ---------------- s3：26 bit 求和 + 饱和判定 ----------------
    // 两项各 < 2^25，和 < 2^26；"和 >= 2^24" 由 bit24/bit25 判定
    wire [25:0] sum_c = {1'b0, pi_r[24:0]} + {1'b0, pq_r[24:0]};
    wire        sat_c = ibig2 | qbig2 | sum_c[24] | sum_c[25];

    reg [25:0] sum_r;
    reg        sat_r;
    reg        v3;

    always @(posedge clk) begin
        if (!rst_n) begin
            sum_r <= 26'd0; sat_r <= 1'b0; v3 <= 1'b0;
        end else begin
            sum_r <= sum_c;
            sat_r <= sat_c;
            v3    <= v2;
        end
    end

    // ---------------- s4：取位 + 饱和 ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            mag16 <= 16'd0; valid_out <= 1'b0;
        end else begin
            mag16 <= sat_r ? 16'hFFFF : sum_r[SHIFT+15:SHIFT];
            valid_out <= v3;
        end
    end

endmodule
