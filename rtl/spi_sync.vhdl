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
        cs_n_i : in  std_logic;  -- CS# as the slave should see it
        mosi_i : in  std_logic;
        dbg_o  : out std_logic;  -- outputs: inputs in the clk_i domain,
        sclk_o : out std_logic;  -- two cycles later
        cs_n_o : out std_logic;
        mosi_o : out std_logic
    );
end entity spi_sync;

architecture rtl of spi_sync is

    signal dbg_s  : std_logic_vector(1 downto 0);
    signal sclk_s : std_logic_vector(1 downto 0);
    signal cs_s   : std_logic_vector(1 downto 0);
    signal mosi_s : std_logic_vector(1 downto 0);

begin

    sync_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                dbg_s  <= (others => '0');
                sclk_s <= (others => '0');
                cs_s   <= (others => '1');
                mosi_s <= (others => '0');
            else
                dbg_s  <= dbg_s(0) & dbg_i;
                sclk_s <= sclk_s(0) & sclk_i;
                cs_s   <= cs_s(0) & cs_n_i;
                mosi_s <= mosi_s(0) & mosi_i;
            end if;
        end if;
    end process sync_proc;

    dbg_o  <= dbg_s(1);
    sclk_o <= sclk_s(1);
    cs_n_o <= cs_s(1);
    mosi_o <= mosi_s(1);

end architecture rtl;
