# ==========================================================================
#  board_4lane.xdc —— 达芬奇 Artix-7 板级约束（1 GSPS / 4 lane 版）
#  引脚来源：正点原子达芬奇开发板工程信息速查 / 260 交付的 spec_top.xdc
# ==========================================================================

# ---------------- 时钟：50 MHz 晶振 ----------------
create_clock -period 20.000 -name sys_clk -waveform {0.000 10.000} [get_ports sys_clk]

# ---------------- 引脚 ----------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN R4} [get_ports sys_clk]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN U2} [get_ports sys_rst_n]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN T6} [get_ports uart_txd]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN R2} [get_ports led0]

# 复位是异步按键，打拍同步后即可，不做跨时钟域分析
set_false_path -from [get_ports sys_rst_n]

# ---------------- UART 报文格式器的多周期约束 ----------------
# 与 260 版同理：report_fmt 的 FSM 每前进一拍都被 uart_busy 门控，
# 115200 baud 在 300 MHz 下一个字节约 26042 拍，寄存器之间天然有上千拍余量。
# 不加的话这些"伪关键路径"会把布局/物理优化的注意力从真瓶颈上拉走。
# （260 版实测：违约列表前 40 条里约 30 条是这个模块。）

# ---------------- JTAG 在线调试（不做 SPI 固化时也保留 CFGBVS） ----------------
set_property CFGBVS VCCO            [current_design]
set_property CONFIG_VOLTAGE 3.3     [current_design]

# ---------------- SPI Flash 固化属性（2026-10-25 加上，为出 .mcs/.bin） --------
# 取自达芬奇开发板工程信息速查 §5。只影响比特流头部
# （配置模式/位宽/速率），不参与布局布线，不影响时序。
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4    [current_design]
set_property CONFIG_MODE SPIx4                  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50     [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP  [current_design]
set_multicycle_path 8 -setup -from [get_cells -hier -filter {NAME =~ "*u_rpt*" && REF_NAME =~ "FD*"}] -to [get_cells -hier -filter {NAME =~ "*u_rpt*" && REF_NAME =~ "FD*"}]
set_multicycle_path 7 -hold  -from [get_cells -hier -filter {NAME =~ "*u_rpt*" && REF_NAME =~ "FD*"}] -to [get_cells -hier -filter {NAME =~ "*u_rpt*" && REF_NAME =~ "FD*"}]
