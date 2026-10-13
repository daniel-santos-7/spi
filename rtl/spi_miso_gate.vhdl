----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI MISO output enable (slave role, between CS# fall and rise)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity spi_miso_gate is
    port (
        clk_i       : in  std_logic;
        rst_i       : in  std_logic;
        en_i        : in  std_logic;  -- slave role (spi_ctrl)
        cs_n_fall_i : in  std_logic;  -- synchronised CS# edges (spi_edge)
        cs_n_rise_i : in  std_logic;
        oe_o        : out std_logic
    );
end entity spi_miso_gate;

architecture rtl of spi_miso_gate is

    signal active_reg : std_logic;

begin

    -- MISO is driven from the CS# fall to the CS# rise, as seen through the
    -- synchroniser, and only in the slave role: never during reset, nor in
    -- a host frame already under way at reset (no fall seen), nor for the
    -- port's own master frames (en_i low)
    active_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' or en_i = '0' or cs_n_rise_i = '1' then
                active_reg <= '0';
            elsif cs_n_fall_i = '1' then
                active_reg <= '1';
            end if;
        end if;
    end process active_proc;

    oe_o <= active_reg;

end architecture rtl;
