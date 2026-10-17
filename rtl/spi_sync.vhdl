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
        sclk_i : in  std_logic;
        cs_n_i : in  std_logic;
        mosi_i : in  std_logic;
        sclk_o : out std_logic;  -- outputs: inputs in the clk_i domain,
        cs_n_o : out std_logic;  -- two cycles later
        mosi_o : out std_logic
    );
end entity spi_sync;

architecture rtl of spi_sync is

    signal sclk_reg : std_logic_vector(1 downto 0);
    signal cs_n_reg : std_logic_vector(1 downto 0);
    signal mosi_reg : std_logic_vector(1 downto 0);

begin

    sync_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                sclk_reg <= (others => '0');
                cs_n_reg <= (others => '0');  -- busy: the FSM waits for CS# high
                mosi_reg <= (others => '0');
            else
                sclk_reg <= sclk_reg(0) & sclk_i;
                cs_n_reg <= cs_n_reg(0) & cs_n_i;
                mosi_reg <= mosi_reg(0) & mosi_i;
            end if;
        end if;
    end process sync_proc;

    sclk_o <= sclk_reg(1);
    cs_n_o <= cs_n_reg(1);
    mosi_o <= mosi_reg(1);

end architecture rtl;
