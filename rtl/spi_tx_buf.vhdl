----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI transmit buffer (one word, ready/valid input)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity spi_tx_buf is
    generic (
        WIDTH    : positive := 32;
        CNT_BITS : positive := 6
    );
    port (
        clk_i   : in  std_logic;
        rst_i   : in  std_logic;
        flush_i : in  std_logic;  -- role change: drop the word held
        valid_i : in  std_logic;
        data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        bits_i  : in  std_logic_vector(CNT_BITS-1 downto 0);
        ready_i : in  std_logic;  -- the word was sent (frame end)
        ready_o : out std_logic;
        valid_o : out std_logic;
        data_o  : out std_logic_vector(WIDTH-1 downto 0);
        bits_o  : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_tx_buf;

architecture rtl of spi_tx_buf is

    signal valid_reg : std_logic;
    signal data_reg  : std_logic_vector(WIDTH-1 downto 0);
    signal bits_reg  : std_logic_vector(CNT_BITS-1 downto 0);

begin

    -- a word is taken only while the buffer is empty; one written in the
    -- cycle of a flush belongs to the new role and stays
    buf_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                valid_reg <= '0';
                data_reg  <= (others => '0');
                bits_reg  <= (others => '0');
            elsif valid_reg = '0' then
                valid_reg <= valid_i;
                data_reg  <= data_i;
                bits_reg  <= bits_i;
            elsif ready_i = '1' or flush_i = '1' then
                valid_reg <= '0';
            end if;
        end if;
    end process buf_proc;

    ready_o <= not valid_reg;
    valid_o <= valid_reg;
    data_o  <= data_reg;
    bits_o  <= bits_reg;

end architecture rtl;
