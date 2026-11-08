-- fft2048_core.vhd : production wrapper for the OWOComm fft2048 core.
-- optH_4lane copy of optF_4lane/rtl/fft2048_core.vhd, ONE change:
--   inverse => false  (forward DFT, e^-j2pi nk/N), so the 4 lane combine can
--   use natural-order bins and the report's L/R (below/above DC) keeps its
--   meaning without an extra mirror. optE_2lane made the same change on the
--   4096 core (ADR in optE/decisions.md); the generator supports it.
-- Everything else (ports, generics, gain 1/32) is unchanged.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fft_types.all;

entity fft2048_core is
	generic(dataBits: integer := 24;
			twBits: integer := 17);
	port(clk: in std_logic;
		din_re: in std_logic_vector(dataBits-1 downto 0);
		din_im: in std_logic_vector(dataBits-1 downto 0);
		phase: in std_logic_vector(10 downto 0);
		dout_re: out std_logic_vector(dataBits-1 downto 0);
		dout_im: out std_logic_vector(dataBits-1 downto 0));
end entity;

architecture a of fft2048_core is
	signal din_c, dout_c: complex;
begin
	din_c <= to_complex(signed(din_re), signed(din_im));

	core: entity work.fft2048
		generic map(dataBits => dataBits, twBits => twBits, inverse => false)
		port map(clk => clk, din => din_c, phase => unsigned(phase), dout => dout_c);

	dout_re <= std_logic_vector(dout_c.re(dataBits-1 downto 0));
	dout_im <= std_logic_vector(dout_c.im(dataBits-1 downto 0));
end architecture;
