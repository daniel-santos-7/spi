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

    signal m_ready_reg : std_logic;
    signal s_ready_reg : std_logic;
    signal s_grant_reg : std_logic;
    signal valid_reg   : std_logic;
    signal role_reg    : std_logic;
    signal data_reg    : std_logic_vector(WIDTH-1 downto 0);
    signal bits_reg    : std_logic_vector(CNT_BITS-1 downto 0);
    signal m_put       : std_logic;
    signal s_put       : std_logic;
    signal get         : std_logic;

begin

    m_put <= m_valid_i and m_ready_reg;
    s_put <= s_valid_i and s_ready_reg;
    get   <= valid_reg and ready_i;

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

    -- At most one ready is high: only while the buffer is empty next cycle,
    -- and only for the channel holding the grant. The grant moves to the
    -- other channel when it has a word waiting and this one has none or
    -- has just written (round robin), so a ready drops only when a word is
    -- taken or the other channel is waiting.
    ready_proc: process(clk_i)
        variable empty : std_logic;
        variable grant : std_logic;
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                m_ready_reg <= '0';
                s_ready_reg <= '0';
                s_grant_reg <= '0';
            else
                empty := not (m_put or s_put or (valid_reg and not get));
                grant := s_grant_reg;
                if s_grant_reg = '0' and s_valid_i = '1' and (m_valid_i = '0' or m_put = '1') then
                    grant := '1';
                elsif s_grant_reg = '1' and m_valid_i = '1' and (s_valid_i = '0' or s_put = '1') then
                    grant := '0';
                end if;
                m_ready_reg <= empty and not grant;
                s_ready_reg <= empty and grant;
                s_grant_reg <= grant;
            end if;
        end if;
    end process ready_proc;

    m_ready_o <= m_ready_reg;
    s_ready_o <= s_ready_reg;
    valid_o   <= valid_reg;
    role_o    <= role_reg;
    data_o    <= data_reg;
    bits_o    <= bits_reg;

end architecture rtl;
