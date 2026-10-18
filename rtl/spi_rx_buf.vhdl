----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI receive buffer (one word from either role, a ready/valid pair per role)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity spi_rx_buf is
    generic (
        WIDTH    : positive := 32;
        CNT_BITS : positive := 6
    );
    port (
        clk_i     : in  std_logic;
        rst_i     : in  std_logic;
        load_i    : in  std_logic;  -- word offered at the end of a frame, no ready back
        role_i    : in  std_logic;  -- of a master frame (1) or a slave frame (0)
        data_i    : in  std_logic_vector(WIDTH-1 downto 0);
        bits_i    : in  std_logic_vector(CNT_BITS-1 downto 0);
        m_ready_i : in  std_logic;
        s_ready_i : in  std_logic;
        m_valid_o : out std_logic;
        s_valid_o : out std_logic;
        data_o    : out std_logic_vector(WIDTH-1 downto 0);
        bits_o    : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_rx_buf;

architecture rtl of spi_rx_buf is

    signal m_valid_reg : std_logic;
    signal s_valid_reg : std_logic;
    signal data_reg    : std_logic_vector(WIDTH-1 downto 0);
    signal bits_reg    : std_logic_vector(CNT_BITS-1 downto 0);
    signal full        : std_logic;
    signal taken       : std_logic;

begin

    -- at most one valid is high: the role of the frame that filled it
    full  <= m_valid_reg or s_valid_reg;
    taken <= (m_valid_reg and m_ready_i) or (s_valid_reg and s_ready_i);

    buf_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                m_valid_reg <= '0';
                s_valid_reg <= '0';
                data_reg    <= (others => '0');
                bits_reg    <= (others => '0');
            elsif full = '0' or taken = '1' then
                m_valid_reg <= load_i and role_i;
                s_valid_reg <= load_i and not role_i;
                data_reg    <= data_i;
                bits_reg    <= bits_i;
            end if;
        end if;
    end process buf_proc;

    m_valid_o <= m_valid_reg;
    s_valid_o <= s_valid_reg;
    data_o    <= data_reg;
    bits_o    <= bits_reg;

end architecture rtl;
