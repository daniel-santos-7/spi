----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI control (shift strobes for the master or the slave role)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.spi_pkg.all;

entity spi_ctrl is
    generic (
        SCK_DIV : positive := DEF_SCK_DIV
    );
    port (
        clk_i       : in  std_logic;
        rst_i       : in  std_logic;
        role_req_i  : in  std_logic;
        cs_n_fall_i : in  std_logic;
        cs_n_rise_i : in  std_logic;
        sclk_rise_i : in  std_logic;
        sclk_fall_i : in  std_logic;
        tx_valid_i  : in  std_logic;
        done_i      : in  std_logic;
        role_ack_o  : out std_logic;
        role_o      : out std_logic;
        sclk_o      : out std_logic;
        sclk_oe     : out std_logic;
        cs_n_o      : out std_logic;
        cs_n_oe     : out std_logic;
        mosi_oe     : out std_logic;
        miso_oe     : out std_logic;
        start_o     : out std_logic;
        stop_o      : out std_logic;
        sample_o    : out std_logic;
        shift_o     : out std_logic;
        tx_ready_o  : out std_logic;
        rx_valid_o  : out std_logic
    );
end entity spi_ctrl;

architecture rtl of spi_ctrl is

    type state_t is (S_IDLE, S_FRAME, M_IDLE, M_SCK_LO, M_SCK_HI, M_END);

    constant CNT_W : positive := bits_for(SCK_DIV-1);

    signal state_reg    : state_t;
    signal cnt_reg      : unsigned(CNT_W-1 downto 0);
    signal sclk_reg     : std_logic;
    signal cs_n_reg     : std_logic;
    signal s_drv_en_reg : std_logic;
    signal role_reg     : std_logic;
    signal cnt_en       : std_logic;
    signal cnt_end      : std_logic;

    signal m_start      : std_logic;
    signal m_stop       : std_logic;
    signal m_rise       : std_logic;
    signal m_fall       : std_logic;
    signal s_start      : std_logic;
    signal s_stop       : std_logic;
    signal s_rise       : std_logic;
    signal s_fall       : std_logic;

begin

    cnt_en  <= '1' when state_reg = M_SCK_LO or state_reg = M_SCK_HI else '0';
    cnt_end <= '1' when cnt_reg = SCK_DIV-1 else '0';

    fsm_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                state_reg    <= S_IDLE;
                sclk_reg     <= '0';
                cs_n_reg     <= '1';
                s_drv_en_reg <= '0';
                role_reg     <= '0';
            else
                case state_reg is
                    when S_IDLE =>
                        if cs_n_fall_i = '1' then
                            state_reg    <= S_FRAME;
                            s_drv_en_reg <= '1';
                        elsif role_req_i = '1' then
                            state_reg <= M_IDLE;
                            role_reg  <= '1';
                        end if;
                    when S_FRAME =>
                        if cs_n_rise_i = '1' then
                            state_reg    <= S_IDLE;
                            s_drv_en_reg <= '0';
                        end if;
                    when M_IDLE =>
                        if tx_valid_i = '1' then
                            state_reg <= M_SCK_LO;
                            cs_n_reg  <= '0';
                        elsif role_req_i = '0' then
                            state_reg <= S_IDLE;
                            role_reg  <= '0';
                        end if;
                    when M_SCK_LO =>
                        if cnt_end = '1' then
                            state_reg <= M_SCK_HI;
                            sclk_reg  <= '1';
                        end if;
                    when M_SCK_HI =>
                        if cnt_end = '1' then
                            sclk_reg <= '0';
                            if done_i = '1' then
                                state_reg <= M_END;
                                cs_n_reg  <= '1';
                            else
                                state_reg <= M_SCK_LO;
                            end if;
                        end if;
                    when M_END =>
                        state_reg <= M_IDLE;
                end case;
            end if;
        end if;
    end process fsm_proc;

    cnt_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                cnt_reg <= (others => '0');
            elsif cnt_en = '1' then
                if cnt_end = '1' then
                    cnt_reg <= (others => '0');
                else
                    cnt_reg <= cnt_reg + 1;
                end if;
            end if;
        end if;
    end process cnt_proc;

    m_start <= '1' when state_reg = M_IDLE   and tx_valid_i = '1' else '0';
    m_stop  <= '1' when state_reg = M_END    else '0';
    m_rise  <= '1' when state_reg = M_SCK_LO and cnt_end    = '1' else '0';
    m_fall  <= '1' when state_reg = M_SCK_HI and cnt_end    = '1' else '0';

    s_start <= '1' when state_reg = S_IDLE  and cs_n_fall_i = '1' else '0';
    s_stop  <= '1' when state_reg = S_FRAME and cs_n_rise_i = '1' else '0';
    s_rise  <= '1' when state_reg = S_FRAME and sclk_rise_i = '1' else '0';
    s_fall  <= '1' when state_reg = S_FRAME and sclk_fall_i = '1' else '0';

    role_ack_o <= role_reg;
    role_o     <= role_reg;
    sclk_o     <= sclk_reg;
    sclk_oe    <= role_reg;
    cs_n_o     <= cs_n_reg;
    cs_n_oe    <= role_reg;
    mosi_oe    <= role_reg;
    miso_oe    <= s_drv_en_reg;
    start_o    <= m_start or s_start;
    stop_o     <= m_stop or s_stop;
    sample_o   <= m_rise or s_rise;
    shift_o    <= m_fall or s_fall;
    tx_ready_o <= m_start or s_start;
    rx_valid_o <= m_stop or s_stop;

end architecture rtl;
