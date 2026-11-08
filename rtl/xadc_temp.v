// xadc_temp.v -- read the Artix-7 on-chip temperature via the XADC hard block.
// Single-channel mode (SEQ=0100, channel 0 = temperature) so the temp register
// is refreshed continuously; a slow DRP poll picks it up (~2 ms period).
// Output: integer degC = DO[11:4] of register 0x00 (two's complement).
`timescale 1ns/1ps
module xadc_temp (
    input  wire       clk,      // clk2 domain (125 MHz), also XADC DCLK
    input  wire       rst_n,
    output reg  [7:0] temp
);
    reg        den, dwe;
    reg [6:0]  daddr;
    reg [15:0] di;
    wire [15:0] do;
    wire        drdy, busyn, eoc, eos;
    wire [4:0]  channel;
    wire [7:0]  alm;
    wire        ot;

    // SEQ = 0100 (single channel), channel = 0000 (temperature)
    // CB  = 5  -> ADCCLK = DCLK/5 = 25 MHz (spec max 26 MHz)
    XADC #(
        .INIT_40(16'h0000),
        .INIT_41(16'h4000),
        .INIT_42(16'h0500),
        .INIT_48(16'h0000), .INIT_49(16'h0000), .INIT_4A(16'h0000), .INIT_4B(16'h0000),
        .INIT_4C(16'h0000), .INIT_4D(16'h0000), .INIT_4E(16'h0000), .INIT_4F(16'h0000),
        .INIT_50(16'hB5ED), .INIT_51(16'h5999), .INIT_52(16'hA147), .INIT_53(16'hDD71),
        .INIT_54(16'hA93A), .INIT_55(16'h5111), .INIT_56(16'h91F1), .INIT_57(16'hB5C2),
        .SIM_DEVICE("7SERIES"),
        .SIM_MONITOR_FILE("xadc_monitor.txt")
    ) u_xadc (
        .DCLK(clk), .DEN(den), .DWE(dwe), .DADDR(daddr), .DI(di),
        .DO(do), .DRDY(drdy), .RESET(~rst_n),
        .CONVST(1'b0), .CONVSTCLK(1'b0),
        .ALM(alm), .BUSY(busyn), .CHANNEL(channel), .EOC(eoc), .EOS(eos), .OT(ot)
    );

    localparam [1:0] S_IDLE = 2'd0, S_REQ = 2'd1, S_WAIT = 2'd2, S_GAP = 2'd3;
    reg [1:0]  st;
    reg [17:0] gap;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; den <= 1'b0; dwe <= 1'b0; daddr <= 7'd0; di <= 16'd0;
            temp <= 8'd0; gap <= 18'd0;
        end else begin
            case (st)
            S_IDLE: begin
                den <= 1'b0;
                if (gap == 18'd0) begin
                    daddr <= 7'h00;      // temperature register
                    den   <= 1'b1;
                    st    <= S_REQ;
                end else begin
                    gap <= gap - 1'b1;
                end
            end
            S_REQ:  begin den <= 1'b0; st <= S_WAIT; end
            S_WAIT: if (drdy) begin
                        temp <= do[11:4];   // integer degC, two's complement
                        st   <= S_GAP;
                    end
            S_GAP:  begin st <= S_IDLE; gap <= 18'd262143; end   // ~2.1 ms @125 MHz
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
