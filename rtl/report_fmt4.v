// ==========================================================================
//  report_fmt4.v —— UART ASCII 结果报文格式化（500 MSPS / 2 lane 档）
//
//  【口径】复刻 deliver_260MSPS/02_src/rtl/report_fmt.v：
//    · 模板 + 数字域：模板字节 < 0x80 → ASCII 字面量原样发出；
//                     模板字节 ≥ 0x80 → 在此插入第 (b-0x80) 号数字域，
//                     用【十进制 ASCII】逐位发出（内部 BCD 只是中间量，
//                     线上永远是 0x30~0x39）。
//    · 十进制、无前导零（值为 0 时输出 "0"）、大写键名、key=value、空格分隔
//    · 帧尾 CR LF = 0x0D 0x0A；无帧头、无校验、无长度字段（与 260 档一致）
//    · 一帧 = 一条 ASCII 文本行，直接可读，host 端按行解析即可
//
//  【字段顺序】本档按 sys4_top 的输出集合排（8 个数字域）：
//      BW / C / A / L / R / PEAK / THR / FOUND / FRM
//  2026-10-24：删除 T（片内温度）域——片上测温（XADC）方案已放弃（试综合 WNS=-0.357，
//  见报告目录），报文由 9 域缩回 8 域，FRM 仍紧随 FOUND。
//  260 档的字段集合不同（PEAK / F / BW / A / FRM / LAT），无法逐字照抄；
//  编码口径、帧尾、键值风格完全一致，差异见 docs/uart_report.md §2 对照表。
//
//  【与 260 版实现上的两处不同，报文逐字节相同】
//    1) 流式发送，不做 msgbuf 报文缓存：
//       260 版的 96 字节 msgbuf 用变量下标写，被 Vivado 实现成 768 个触发器 +
//       逐槽写译码，是它 200 MHz 下全设计最差路径（slack +0.006 ns）。
//       本版把数字直接流向 uart_tx：一个字节 = 2170 拍，格式化状态机有上千拍
//       余量，所以根本不需要缓存，也没有任何变量下标写 / 分布式 RAM。
//    2) 十进制转换用 double-dabble（加 3-移位，24 拍一次），8 个域共用一份
//       组合逻辑，不再实例化 bin2dec。
//
//  【背压】uart_tx 忙时【直接丢弃】新的 done：不排队、不缓存、不置溢出标志。
//    一帧约 6 ms（69 字节 @115200），而 done 每个帧周期来一次（16.384 us，
//    500 MSPS / 8192 点），所以实际约 167 次/秒上报一次，报的是"最近一帧"。
//    帧尾那一拍同时到来的 done 也会被丢（不影响观感），详见 docs §5。
//
//  【时钟】全部寄存器都在 clk（250 MHz）单一时钟域，不产生新时钟域，
//    内部没有分频时钟、没有门控时钟、没有 negedge 逻辑。
//
//  【复位】同步复位（always @(posedge clk) + if (!rst_n)）。
// ==========================================================================
`timescale 1ns / 1ps

module report_fmt4 (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 一组结果（与 sys2_top 的 o_* 同拍有效；done 为单拍脉冲）----
    input  wire        done,        // 结果有效（单拍）
    input  wire [13:0] bw,          // o_bw
    input  wire [12:0] center,      // o_center
    input  wire [23:0] amp,         // o_amp
    input  wire [12:0] left,        // o_left
    input  wire [12:0] right,       // o_right
    input  wire [15:0] peak,        // o_peak
    input  wire [15:0] thr,         // o_thr
    input  wire        found,       // o_found
    input  wire [7:0]  temp,        // 已停用：XADC 放弃，上层固定接 8'd0，报文不输出
    input  wire [13:0] frm,         // 帧长度（每分析帧的 IQ 样点数，实测）
    input  wire [15:0] dcnt,        // 2026-10-25：done 计数（看 8.192 µs 帧周期用）
    input  wire [15:0] lat,         // 2026-11-02: 本帧延迟（ns，5 位十进制）

    // ---- 到 uart_tx ----
    input  wire        uart_busy,   // uart_tx.tx_busy
    output reg  [7:0]  tx_byte,     // 待发字节（tx_valid=1 当拍有效）
    output reg         tx_valid,    // 单拍脉冲
    output reg         busy         // 报文正在发（可接 LED / ILA）
);

    // ---------------- 结果影子寄存器 ----------------
    // done 到来时一次性锁存，之后 6 ms 的发送期间数据不会被下一帧冲掉。
    // ds2_sys.v 的 P2 段里 found/left/right/bw_idx/center/peak/thr 和 done 是
    // 【同一拍】更新的（见 ds2_sys.v 252~259 行），所以这里同拍锁存就是对的，
    // 不需要 260 档那样再加 scan_done_d 对一拍。
    reg [13:0] r_bw;
    reg [12:0] r_c;
    reg [23:0] r_a;
    reg [12:0] r_l;
    reg [12:0] r_r;
    reg [15:0] r_pk;
    reg [15:0] r_thr;
    reg        r_found;
    reg [13:0] r_frm;
    reg [15:0] r_dcnt;      // 2026-10-25: done 计数影子值
    reg [15:0] r_lat;       // 2026-11-02: 延迟影子值（ns）

    // ---------------- 报文模板 ----------------
    //  < 0x80：ASCII 字面量；≥ 0x80：数字域标记（0x80+n = 第 n 个域）；0x00：结束
    //  一帧 49 个模板项（9 个数字域 + 40 个字面量/帧尾），当前实测报文 69 字节：
    //    BW=256 C=1360 A=771 L=1232 R=1487 PEAK=767 THR=383 FOUND=1 FRM=8192\r\n
    //  注：删温度域时只删 6'd41..6'd44（" " "T" "=" 域标记 0x88），6'd45 的 " " 是 FRM 前的
    //      分隔符，必须保留，否则会拼成 "FOUND=1FRM=8192"。
    function [7:0] tpl;
        input [5:0] i;
        begin
            case (i)
                6'd0:  tpl = "B";
                6'd1:  tpl = "W";
                6'd2:  tpl = "=";
                6'd3:  tpl = 8'h80;             // 数字域 0: bw
                6'd4:  tpl = " ";
                6'd5:  tpl = "C";
                6'd6:  tpl = "=";
                6'd7:  tpl = 8'h81;             // 数字域 1: center
                6'd8:  tpl = " ";
                6'd9:  tpl = "A";
                6'd10: tpl = "=";
                6'd11: tpl = 8'h82;             // 数字域 2: amp
                6'd12: tpl = " ";
                6'd13: tpl = "L";
                6'd14: tpl = "=";
                6'd15: tpl = 8'h83;             // 数字域 3: left
                6'd16: tpl = " ";
                6'd17: tpl = "R";
                6'd18: tpl = "=";
                6'd19: tpl = 8'h84;             // 数字域 4: right
                6'd20: tpl = " ";
                6'd21: tpl = "P";
                6'd22: tpl = "E";
                6'd23: tpl = "A";
                6'd24: tpl = "K";
                6'd25: tpl = "=";
                6'd26: tpl = 8'h85;             // 数字域 5: peak
                6'd27: tpl = " ";
                6'd28: tpl = "T";
                6'd29: tpl = "H";
                6'd30: tpl = "R";
                6'd31: tpl = "=";
                6'd32: tpl = 8'h86;             // 数字域 6: thr
                6'd33: tpl = " ";
                6'd34: tpl = "F";
                6'd35: tpl = "O";
                6'd36: tpl = "U";
                6'd37: tpl = "N";
                6'd38: tpl = "D";
                6'd39: tpl = "=";
                6'd40: tpl = 8'h87;             // 数字域 7: found
                6'd41: tpl = " ";               // 2026-10-24：温度域已删，保留 FRM 的分隔空格
                6'd42: tpl = "F";
                6'd43: tpl = "R";
                6'd44: tpl = "M";
                6'd45: tpl = "=";
                6'd46: tpl = 8'h89;             // 数字域 9: frm（样点数）
                // 2026-10-25：加 done 计数域。主机侧用"相邻两行的 DCNT 差 / 到达时间差"
                // 就能反推 done 速率：N=1 时 1/8.192µs = 122.07 kHz，N=2 时减半。
                6'd47: tpl = " ";
                6'd48: tpl = "D";
                6'd49: tpl = "C";
                6'd50: tpl = "N";
                6'd51: tpl = "T";
                6'd52: tpl = "=";
                6'd53: tpl = 8'h8A;             // 数字域 10: dcnt（16 bit）
                // 2026-11-02：加延迟域（ns）。报文 69 → 80 B（" LAT=" + 5 位数字）
                6'd54: tpl = " ";
                6'd55: tpl = "L";
                6'd56: tpl = "A";
                6'd57: tpl = "T";
                6'd58: tpl = "=";
                6'd59: tpl = 8'h8B;             // 数字域 11: lat
                6'd60: tpl = 8'h0D;             // CR
                6'd61: tpl = 8'h0A;             // LF
                default: tpl = 8'h00;           // 结束
            endcase
        end
    endfunction

    // 第 f 个数字域的取值（24 bit 足够：最宽的是 amp 24 bit）
    function [23:0] fval;
        input [3:0] f;
        begin
            case (f)
                3'd0: fval = {10'd0, r_bw};     // 14 bit
                3'd1: fval = {11'd0, r_c};      // 13 bit
                3'd2: fval = r_a;               // 24 bit
                3'd3: fval = {11'd0, r_l};      // 13 bit
                3'd4: fval = {11'd0, r_r};      // 13 bit
                3'd5: fval = {8'd0,  r_pk};     // 16 bit
                3'd6: fval = {8'd0,  r_thr};    // 16 bit
                3'd7: fval = {23'd0, r_found};  // 1 bit
                4'd9: fval = {10'd0, r_frm};    // 域 9：frm（14 bit，样点数；域 8 原为温度，已删）
                4'd10: fval = {8'd0, r_dcnt};   // 域 10：done 计数（16 bit）
                4'd11: fval = {8'd0, r_lat};    // 延迟 ns
                default: fval = 24'd0;
            endcase
        end
    endfunction

    // 第 f 个数字域最多几位十进制（不超过 2^24-1 = 8 位）
    function [3:0] fndig;
        input [3:0] f;
        begin
            case (f)
                3'd0: fndig = 4'd5;     // bw     ≤ 16383
                3'd1: fndig = 4'd4;     // center ≤ 8191
                3'd2: fndig = 4'd8;     // amp    ≤ 16777215
                3'd3: fndig = 4'd4;     // left   ≤ 8191
                3'd4: fndig = 4'd4;     // right  ≤ 8191
                3'd5: fndig = 4'd5;     // peak   ≤ 65535
                3'd6: fndig = 4'd5;     // thr    ≤ 65535
                3'd7: fndig = 4'd1;     // found  0/1
                4'd9: fndig = 4'd5;     // frm    ≤ 65535
                4'd10: fndig = 4'd5;    // dcnt   ≤ 65535
                4'd11: fndig = 4'd5;    // lat ≤ 65528
                default: fndig = 4'd1;
            endcase
        end
    endfunction

    // ---------------- 十进制转换：double-dabble（两级流水） ----------------
    // 每个 4 bit BCD 位 ≥5 就 +3，然后整体左移补入 1 个二进制位。
    // 24 bit 值走 24 拍，得到 8 位十进制（32 bit BCD）。
    // 2026-10-20 晚：原来 "dabble + 移位" 在同一拍，275 MHz 下 3.55~3.62 ns
    // （8 个 nibble 的 +3 比较 + 32 bit 移位，路由占 2.7 ns），是全设计最差路径。
    // 拆成两级（dabble 结果先打拍，下一拍再移位/拼接）：每 bit 2 拍 ⇒ 48 拍，
    // 相对 UART 一个字节 2170 拍完全可忽略。
    function [31:0] dabble;
        input [31:0] b;
        integer k;
        reg [3:0] n;
        begin
            dabble = b;
            for (k = 0; k < 8; k = k + 1) begin
                n = dabble[4*k +: 4];
                if (n >= 4'd5) dabble[4*k +: 4] = n + 4'd3;
            end
        end
    endfunction

    reg [23:0] cv_val;      // 待转换值（逐拍左移）
    reg [31:0] cv_bcd;      // 转换结果（8 个十进制位）
    reg [5:0]  cv_cnt;      // 已移位数 0..48（每个 bit 两拍；5 bit 装不下 48，必须 6 bit）
    reg [31:0] cv_dab_r;    // dabble 结果（第一级）
    reg [23:0] cv_val_r;    // 与 cv_dab_r 同拍的值（第一级）
    wire [31:0] cv_dab = dabble(cv_bcd);

    // ---------------- 主状态机 ----------------
    localparam [3:0] S_IDLE = 4'd0,     // 等 done
                     S_WALK = 4'd1,     // 走模板
                     S_CONV = 4'd2,     // double-dabble 转换
                     S_EMIT = 4'd3,     // 逐位发数字
                     S_EADV = 4'd4,     // 数字位推进（发完 / 跳过高位 0）
                     S_TX   = 4'd5,     // 装载字节并拉 tx_valid
                     S_TXH  = 4'd6,     // 等 uart_tx 把 busy 拉起来
                     S_TXW  = 4'd7,     // 等这个字节发完
                     S_WAIT = 4'd8;     // 等一拍，让模板字节寄存器 tb_r 跟上 tidx

    reg [3:0] st;
    reg [3:0] ret_st;       // 发完字节回到哪个状态
    // 这两个下标驱动很大的 case / 32 路 mux，实测路径是"路由占 70%"，
    // 让工具按 8 个负载复制驱动器，缩短走线（275 MHz 下 pend_byte/ret_st CE 3.40 ns）。
    (* max_fanout = 8 *) reg [5:0] tidx;         // 模板下标
    (* max_fanout = 8 *) reg [3:0] didx;         // 当前数字位下标（ndig-1 → 0）
    // 2026-10-20 晚：模板字节先打一拍（tb_r），S_WALK 的判据与输出都只从寄存器出发。
    // 原来是 tidx -> tpl(tidx)（43 路译码）-> 判据 -> tidx+1 形成组合环，
    // 275 MHz 下 3.56 ns（路由占 2.6 ns），把 550 档卡在 -0.007。
    // tidx 变动后插一个 S_WAIT 拍，让 tb_r 跟上（每帧只多 8 拍，可忽略）。
    reg [7:0] tb_r;
    reg       lead;         // 1 = 还在压制前导零
    reg [7:0] pend_byte;    // 待发字节

    always @(posedge clk) begin
        if (!rst_n) tb_r <= tpl(6'd0); else tb_r <= tpl(tidx);
    end

    wire [7:0]  tb_byte   = tb_r;
    wire [3:0]  cur_ndig  = fndig(tb_r[3:0]);
    wire [3:0]  cur_digit = cv_bcd[{didx, 2'b00} +: 4];
    // 2026-10-20 晚：当前十进制位提前一拍取（cd_r）。
    // 原来 emit_this / pend_byte / lead 都由 32 bit 的 cur_digit mux 直接算，
    // 路径是 cv_bcd -> 8:1 mux -> CE，300 MHz 下 3.22 ns / -0.134。
    // 现在 cd_r 在进入 S_EMIT 之前就取好，发送阶段的判断全从 4 bit 寄存器出发。
    reg [3:0] cd_r;
    // 前导零压制：最高位开始，遇到第一个非 0 才允许发；最后一位无条件发（值 0 也要发 "0"）
    wire        emit_this = (!lead) || (cd_r != 4'd0) || (didx == 4'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            ret_st    <= S_IDLE;
            tidx      <= 6'd0;
            didx      <= 4'd0;
            lead      <= 1'b1;
            cd_r      <= 4'd0;
            pend_byte <= 8'd0;
            tx_byte   <= 8'd0;
            tx_valid  <= 1'b0;
            busy      <= 1'b0;
            cv_val    <= 24'd0;
            cv_bcd    <= 32'd0;
            cv_cnt    <= 6'd0;
            cv_dab_r  <= 32'd0;
            cv_val_r  <= 24'd0;
            r_bw      <= 14'd0;
            r_c       <= 13'd0;
            r_a       <= 24'd0;
            r_l       <= 13'd0;
            r_r       <= 13'd0;
            r_pk      <= 16'd0;
            r_thr     <= 16'd0;
            r_found   <= 1'b0;
            r_frm     <= 14'd0;
            r_dcnt    <= 16'd0;
            r_lat     <= 16'd0;
        end else begin
            tx_valid <= 1'b0;       // 默认单拍

            case (st)
            // ---------------------------------------------- 等结果
            S_IDLE: begin
                busy <= 1'b0;
                if (done) begin              // 忙时的 done 根本进不到这里，直接被丢
                    r_bw    <= bw;
                    r_c     <= center;
                    r_a     <= amp;
                    r_l     <= left;
                    r_r     <= right;
                    r_pk    <= peak;
                    r_thr   <= thr;
                    r_found <= found;
                    r_frm   <= frm;
                    r_dcnt  <= dcnt;
                    r_lat   <= lat;
                    tidx    <= 6'd0;
                    busy    <= 1'b1;
                    st      <= S_WAIT;     // 让 tb_r 跟上新的 tidx
                end
            end

            // ---------------------------------------------- 等一拍（模板字节打拍）
            S_WAIT: begin
                st <= S_WALK;
            end

            // ---------------------------------------------- 走模板
            S_WALK: begin
                if (tb_byte == 8'h00) begin          // 模板走完，一帧结束
                    busy <= 1'b0;
                    st   <= S_IDLE;
                end else if (tb_byte < 8'h80) begin  // ASCII 字面量
                    pend_byte <= tb_byte;
                    tidx      <= tidx + 6'd1;
                    ret_st    <= S_WALK;
                    st        <= S_TX;
                end else begin                       // 数字域标记
                    cv_val <= fval(tb_byte[3:0]);
                    cv_bcd <= 32'd0;
                    cv_cnt <= 6'd0;
                    st     <= S_CONV;
                end
            end

            // ---------------------------------------------- 十进制转换（48 拍，每 bit 两级）
            S_CONV: begin
                if (cv_cnt == 6'd48) begin
                    didx <= cur_ndig - 4'd1;
                    lead <= 1'b1;
                    cd_r <= cv_bcd[{(cur_ndig - 4'd1), 2'b00} +: 4];
                    st   <= S_EMIT;
                end else if (cv_cnt[0] == 1'b0) begin
                    // 第一级：8 个 nibble 的 +3 判断，结果打拍
                    cv_dab_r <= cv_dab;
                    cv_val_r <= cv_val;
                    cv_cnt   <= cv_cnt + 6'd1;
                end else begin
                    // 第二级：整体左移 + 补入 1 个二进制位
                    cv_bcd <= {cv_dab_r[30:0], cv_val_r[23]};
                    cv_val <= {cv_val_r[22:0], 1'b0};
                    cv_cnt <= cv_cnt + 6'd1;
                end
            end

            // ---------------------------------------------- 逐位发数字
            S_EMIT: begin
                if (emit_this) begin
                    pend_byte <= 8'h30 + {4'd0, cd_r};
                    ret_st    <= S_EADV;
                    st        <= S_TX;
                end else begin
                    st <= S_EADV;                    // 前导零：不发，直接跳过
                end
            end

            // ---------------------------------------------- 数字位推进
            S_EADV: begin
                if (didx == 4'd0) begin
                    tidx <= tidx + 6'd1;             // 越过模板里的数字域标记
                    st   <= S_WAIT;                  // 让 tb_r 跟上（每帧 8 次）
                end else begin
                    didx <= didx - 4'd1;
                    lead <= lead & (cd_r == 4'd0);
                    cd_r <= cv_bcd[{(didx - 4'd1), 2'b00} +: 4];
                    st   <= S_EMIT;
                end
            end

            // ---------------------------------------------- 发一个字节
            S_TX: begin
                tx_byte  <= pend_byte;
                tx_valid <= 1'b1;
                st       <= S_TXH;
            end

            // 等 uart_tx 把 busy 拉起来（下拍它才采样到 tx_valid，
            // 所以这里必须等，不能直接看 !busy）
            S_TXH: begin
                if (uart_busy) st <= S_TXW;
            end

            // 等这个字节发完（含停止位）
            S_TXW: begin
                if (!uart_busy) st <= ret_st;
            end

            default: begin
                st   <= S_IDLE;
                busy <= 1'b0;
            end
            endcase
        end
    end

endmodule
