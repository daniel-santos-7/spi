----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI slave edge detection (SCK strobes)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity spi_edge is
    port (
        clk_i       : in  std_logic;
        rst_i       : in  std_logic;
        sclk_i      : in  std_logic;  -- sclk_i and cs_n_i must already be
        cs_n_i      : in  std_logic;  -- synchronised to clk_i (spi_sync does it)
        sclk_rise_o : out std_logic;  -- SCK edges only while CS# is low
        sclk_fall_o : out std_logic
    );
end entity spi_edge;

architecture rtl of spi_edge is

    signal sclk_dly_reg : std_logic;

begin

    edge_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                sclk_dly_reg <= '0';
            else
                sclk_dly_reg <= sclk_i;
            end if;
        end if;
    end process edge_proc;

    sclk_rise_o <= sclk_i and not sclk_dly_reg and not cs_n_i;
    sclk_fall_o <= sclk_dly_reg and not sclk_i and not cs_n_i;

end architecture rtl;
