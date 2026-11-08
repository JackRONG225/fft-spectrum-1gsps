
library ieee;
library work;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
use work.fft_types.all;
use work.twiddleAddrGen;
use work.transposer;
use work.twiddleGenerator16;
use work.complexMultiply2;
use work.fft4_serial8;

-- data input bit order: (3 downto 0) [0,1,2,3]
-- data output bit order: (3 downto 0) [0,1,2,3]
-- phase should be 0,1,2,3,4,5,6,...
-- delay is 35
entity fft2048_sub16 is
	generic(dataBits: integer := 24;
			twBits: integer := 12;
			inverse: boolean := true);
	port(clk: in std_logic;
		din: in complex;
		phase: in unsigned(4-1 downto 0);
		dout: out complex
		);
end entity;
architecture ar of fft2048_sub16 is
	signal sub1din, sub1dout, sub2din, sub2dout: complex;
	signal sub1phase: unsigned(2-1 downto 0);
	signal sub2phase: unsigned(2-1 downto 0);
	constant N: integer := 16;
	constant dataBitsIntern: integer := dataBits + 0;
	constant dataBitsOut: integer := dataBits + 0;
	constant twiddleBits: integer := twBits;
	constant twiddleDelay: integer := 2;
	constant order: integer := 4;
	constant delay: integer := 35;
	constant sub1dataBits: integer := dataBits;
	constant sub2dataBits: integer := dataBitsIntern;


	--=======================================

	signal ph1, ph2, ph3: unsigned(order-1 downto 0);
	signal rbIn, transpOut: complex;
	signal bitPermIn,bitPermOut: unsigned(2-1 downto 0);

	-- twiddle generator
	signal twAddr: unsigned(order-1 downto 0);
	signal twData: complex;

	signal romAddr: unsigned(order-4 downto 0);
	signal romData: std_logic_vector(twiddleBits*2-3 downto 0);

begin
	sub1din <= din;
	sub1phase <= phase(2-1 downto 0);

	ph1 <= phase-7+1 when rising_edge(clk);

	transp: entity transposer
		generic map(N1=>2, N2=>2, dataBits=>dataBitsIntern)
		port map(clk=>clk, din=>sub1dout, phase=>ph1, dout=>transpOut);

	ph2 <= ph1;

	twAG: entity twiddleAddrGen
		generic map(
			subOrder1=>2,
			subOrder2=>2,
			twiddleDelay=>twiddleDelay,
			customSubOrder=>true,
			bitReverse4=>true)
		port map(
			clk=>clk,
			phase=>ph2,
			twAddr=>twAddr,
			bitPermIn=>bitPermIn,
			bitPermOut=>bitPermOut);

	twMult: entity complexMultiply2
		generic map(in1Bits=>twiddleBits+1,
					in2Bits=>dataBitsIntern,
					outBits=>dataBitsIntern)
		port map(clk=>clk, in1=>twData, in2=>transpOut, out1=>sub2din);

	ph3 <= ph2-5+1 when rising_edge(clk);
	sub2phase <= ph3(2-1 downto 0);
	dout <= sub2dout;
	bitPermOut <= bitPermIn(0)&bitPermIn(1);

	tw: entity twiddleGenerator16
		generic map(twBits=>twiddleBits, inverse=>inverse)
		port map(clk, twAddr, twData);
	sub1inst: entity fft4_serial8
		generic map(dataBits=>sub1dataBits, scale=>SCALE_NONE, inverse=>inverse)
		port map(clk=>clk, din=>sub1din, phase=>sub1phase, dout=>sub1dout);
	sub2inst: entity fft4_serial8
		generic map(dataBits=>sub2dataBits, scale=>SCALE_NONE, inverse=>inverse)
		port map(clk=>clk, din=>sub2din, phase=>sub2phase, dout=>sub2dout);

end ar;
