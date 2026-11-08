-- ==========================================================================
-- complex_multiply2_k.vhd  --  3-multiplier (Karatsuba) complex multiplier
--
--   Drop-in replacement for work.complexMultiply2 (same entity name, same
--   ports, same generic list, SAME 5-cycle delay), but 3 DSP48E1 instead of 4.
--   Purpose: 4 lane x fft2048 needs 80 DSP for the cores alone on xc7a35t
--   (90 total), so the core has to drop to 15 DSP (4 nodes x 3 + 3).
--
--   Bit-exactness with the original 4-multiplier version (proved by tb_cmul):
--     original:  re = ((ac + h) - bd),  im = ((ad + h) + bc),  h = 2^(internalBits-outBits-2)
--     Karatsuba: k1 = (a+b)c + h ;  re = k1 - b(c+d) ;  im = k1 + a(d-c)
--                k1 - b(c+d) = ac + bc + h - bc - bd = ac - bd + h   (identical)
--                k1 + a(d-c) = ac + bc + h + ad - ac = ad + bc + h   (identical)
--     All intermediate signals are wide enough that no product is truncated
--     before the final >>(internalBits-outBits-1) slice, so the result is
--     bit-identical to the 4-multiplier version (which is what the fft2048
--     core was verified against in optF_4lane/sim).
--
--   Delay budget (identical to complexMultiply2, which is 5):
--     c0 inputs -> c1 a1..d1 + s=a+b + cd/dc sums
--     c1        -> c2 multiplier input regs (inside multiplyAdd)
--     c2        -> c3 products
--     c3        -> c4 k1 +/- k3 (accumulate, uses k1 as the C port)
--     c4        -> c5 res_re/res_im
-- ==========================================================================
library ieee;
library work;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
use work.fft_types.all;
use work.multiplyAdd;

entity complexMultiply2 is
	generic(in1Bits,in2Bits,outBits: integer := 8;
			round: boolean := true);
	port(clk: std_logic;
			in1,in2: in complex;
			out1: out complex
			);
end entity;

architecture a of complexMultiply2 is
	-- in1 = twiddle side (18 bit), in2 = data side (24 bit)
	constant internalBits: integer := in1Bits + in2Bits;      -- 42
	constant accBits: integer := internalBits + 2;            -- 44 (headroom for k1=ac+bc)
	constant halfBit: integer := internalBits - outBits - 3;  -- 15 (halfLSB = "01"&0s)
	constant hiBit: integer := internalBits - 3;              -- 39  (bd4'left-2)
	constant loBit: integer := internalBits - outBits - 2;    -- 16  (bd4'left-outBits-1)

	signal a,b,a1,b1: signed(in1Bits-1 downto 0);
	signal c,d,c1,d1: signed(in2Bits-1 downto 0);
	-- s = a+b is kept at in1Bits (NOT in1Bits+1) on purpose:
	--   in1 is the twiddle side, a,b in [-2^16, 2^16-1] (unity Q1.16), so
	--   |a+b| <= 2^17 = 131072 which is exactly representable in signed 18 bit.
	--   Keeping 18 bits makes the product 18x24, which fits ONE DSP48E1
	--   (25x18) with the twiddle sum on the B port; 19 bits forces a split.
	signal s:  signed(in1Bits-1 downto 0);      -- a+b   (twiddle sum)
	signal cd: signed(in2Bits downto 0);        -- c+d   (data sum)
	signal dc: signed(in2Bits downto 0);        -- d-c

	signal halfLSB: signed(accBits-1 downto 0);
	signal k1:  signed(accBits-1 downto 0);
	signal re4, im4: signed(accBits-1 downto 0);
	signal res_re, res_im: signed(outBits-1 downto 0);
begin
	a <= complex_re(in1, in1Bits);
	b <= complex_im(in1, in1Bits);
	c <= complex_re(in2, in2Bits);
	d <= complex_im(in2, in2Bits);

	-- s is consumed at c1 by mAdd1 together with c, so it must be a c0 value.
	s  <= a + b;   -- exact: |a+b| <= 2^17 (see the bound note above)

	process(clk) begin
		if rising_edge(clk) then
			a1 <= a; b1 <= b; c1 <= c; d1 <= d;
		end if;
	end process;

	-- cd/dc are consumed at c2 by mAdd3/mAdd4 together with the c1 values of
	-- b/a, so they must be built from c1/d1 (c1 values), not from c/d.
	cd <= resize(c1, in2Bits+1) + resize(d1, in2Bits+1);
	dc <= resize(d1, in2Bits+1) - resize(c1, in2Bits+1);

	halfLSB <= (halfBit => '1', others => '0');

	-- k1 = (a+b)*c + halfLSB   (c0 -> c3; s and c are both cycle-0 values,
	-- multiplyAdd registers them together at c1)
	mAdd1: entity multiplyAdd
		generic map(in1Bits=>in1Bits, in2Bits=>in2Bits, outBits=>accBits)
		port map(clk, s, c, halfLSB, k1);

	-- re = k1 - b*(c+d)        (c1 -> c4, k1 is the accumulate input at c3)
	mAdd3: entity multiplyAdd
		generic map(in1Bits=>in1Bits, in2Bits=>in2Bits+1, outBits=>accBits, subtract=>true)
		port map(clk, b1, cd, k1, re4);

	-- im = k1 + a*(d-c)
	mAdd4: entity multiplyAdd
		generic map(in1Bits=>in1Bits, in2Bits=>in2Bits+1, outBits=>accBits, subtract=>false)
		port map(clk, a1, dc, k1, im4);

	process(clk) begin
		if rising_edge(clk) then
			res_re <= re4(hiBit downto loBit);
			res_im <= im4(hiBit downto loBit);
		end if;
	end process;

	out1 <= to_complex(res_re, res_im);
end architecture;
