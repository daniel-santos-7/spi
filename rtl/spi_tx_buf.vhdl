----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI transmit buffer (one word from either role, ready/valid)
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
        clk_i     : in  std_logic;
        rst_i     : in  std_logic;
        m_valid_i : in  std_logic;  -- master word from the client
        m_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        m_bits_i  : in  std_logic_vector(CNT_BITS-1 downto 0);
        s_valid_i : in  std_logic;  -- slave reply from the client
        s_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        ready_i   : in  std_logic;  -- the word is used
        m_ready_o : out std_logic;
        s_ready_o : out std_logic;
        valid_o   : out std_logic;
        role_o    : out std_logic;  -- 1 = master word, 0 = slave reply
        data_o    : out std_logic_vector(WIDTH-1 downto 0);
        bits_o    : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_tx_buf;

architecture rtl of spi_tx_buf is

    signal valid_reg   : std_logic;
    signal role_reg    : std_logic;
    signal data_reg    : std_logic_vector(WIDTH-1 downto 0);
    signal bits_reg    : std_logic_vector(CNT_BITS-1 downto 0);
    signal m_ready     : std_logic;
    signal s_ready     : std_logic;
    signal m_put       : std_logic;
    signal s_put       : std_logic;
    signal get         : std_logic;

begin

    -- free while empty; the master goes first when both write at once
    m_ready <= not valid_reg;
    s_ready <= not valid_reg and not m_valid_i;

    m_put   <= m_valid_i and m_ready;
    s_put   <= s_valid_i and s_ready;
    get     <= valid_reg and ready_i;

    -- a word is only taken with the buffer empty, and never two in the
    -- same cycle
    buf_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                valid_reg <= '0';
                role_reg  <= '0';
                data_reg  <= (others => '0');
                bits_reg  <= (others => '0');
            elsif m_put = '1' then
                valid_reg <= '1';
                role_reg  <= '1';
                data_reg  <= m_data_i;
                bits_reg  <= m_bits_i;
            elsif s_put = '1' then
                valid_reg <= '1';
                role_reg  <= '0';
                data_reg  <= s_data_i;
            elsif get = '1' then
                valid_reg <= '0';
            end if;
        end if;
    end process buf_proc;

    m_ready_o <= m_ready;
    s_ready_o <= s_ready;
    valid_o   <= valid_reg;
    role_o    <= role_reg;
    data_o    <= data_reg;
    bits_o    <= bits_reg;

end architecture rtl;
