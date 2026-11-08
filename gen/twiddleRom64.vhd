
library ieee;
library work;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
-- read delay is 2 cycles

entity twiddleRom64 is
	generic(twBits: integer := 17);
	port(clk: in std_logic;
			romAddr: in unsigned(3-1 downto 0);
			romData: out std_logic_vector((twBits-1)*2-1 downto 0)
			);
end entity;
architecture a of twiddleRom64 is
	constant romDepthOrder: integer := 3;
	constant romDepth: integer := 2**romDepthOrder;
	constant romWidth: integer := (twBits-1)*2;
	type ram1t is array(0 to romDepth-1) of
		std_logic_vector(romWidth-1 downto 0);
	signal rom: ram1t;
	signal addr1: unsigned(romDepthOrder-1 downto 0);
	signal data0,data1: std_logic_vector(romWidth-1 downto 0);

	attribute rom_style: string;
	attribute rom_style of data0: signal is "distributed";
	attribute rom_style of addr1: signal is "distributed";
begin
	addr1 <= romAddr when rising_edge(clk);
	data0 <= rom(to_integer(addr1));
	data1 <= data0 when rising_edge(clk);
	romData <= data1;
g12:
	if twBits = 12 generate
		rom <= ("0001100100111111110110","0011001000011111011001","0100101001111110101000","0110001000011101100100","0111100010111100001110","1000111001011010100111"
,"1010001001111000101111","1011010100010110101000");
	end generate;
g16:
	if twBits = 16 generate
		rom <= ("000110010001100111111101100010","001100011111001111110110001010","010010100101000111101001111101","011000011111100111011001000010","011110001010111111000011100011","100011100011101110101001101110"
,"101000100110100110001011110010","101101010000010101101010000010");
	end generate;
g17:
	if twBits = 17 generate
		rom <= ("00011001000110001111111011000100","00110001111100011111101100010101","01001010010100001111010011111010","01100001111110001110110010000011","01111000101011011110000111000110","10001110001110101101010011011011"
,"10100010011010001100010111100100","10110101000001011011010100000101");
	end generate;
end a;
