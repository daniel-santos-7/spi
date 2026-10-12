----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI port input synchronisers
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity spi_sync is
    port (
        clk_i  : in  std_logic;
        rst_i  : in  std_logic;
        dbg_i  : in  std_logic;  -- role strap
        sclk_i : in  std_logic;
        cs_n_i : in  std_logic;
        mosi_i : in  std_logic;
        dbg_o  : out std_logic;  -- outputs: inputs in the clk_i domain,
        sclk_o : out std_logic;  -- two cycles later
        cs_n_o : out std_logic;
        mosi_o : out std_logic
    );
end entity spi_sync;

architecture rtl of spi_sync is

    signal dbg_reg  : std_logic_vector(1 downto 0);
    signal sclk_reg : std_logic_vector(1 downto 0);
    signal cs_n_reg : std_logic_vector(1 downto 0);
    signal mosi_reg : std_logic_vector(1 downto 0);

begin

    sync_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                dbg_reg  <= (others => '0');
                sclk_reg <= (others => '0');
                cs_n_reg <= (others => '1');
                mosi_reg <= (others => '0');
            else
                dbg_reg  <= dbg_reg(0) & dbg_i;
                sclk_reg <= sclk_reg(0) & sclk_i;
                cs_n_reg <= cs_n_reg(0) & cs_n_i;
                mosi_reg <= mosi_reg(0) & mosi_i;
            end if;
        end if;
    end process sync_proc;

    dbg_o  <= dbg_reg(1);
    sclk_o <= sclk_reg(1);
    cs_n_o <= cs_n_reg(1);
    mosi_o <= mosi_reg(1);

end architecture rtl;
