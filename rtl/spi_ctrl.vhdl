----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI control (shift strobes for the master or the slave role)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity spi_ctrl is
    generic (
        SCK_DIV : positive := 1
    );
    port (
        clk_i      : in  std_logic;
        rst_i      : in  std_logic;
        role_req_i : in  std_logic;  -- requested role (1 = master)
        role_ack_o : out std_logic;  -- role in effect (1 = master)
        s_start_i  : in  std_logic;  -- slave strobes (spi_edge)
        s_stop_i   : in  std_logic;
        s_rise_i   : in  std_logic;
        s_fall_i   : in  std_logic;
        cs_pin_i   : in  std_logic;  -- CS# pin as is, for miso_oe
        sclk_o     : out std_logic;
        sclk_oe    : out std_logic;
        cs_n_o     : out std_logic;
        cs_n_oe    : out std_logic;
        mosi_oe    : out std_logic;
        miso_oe    : out std_logic;
        tx_valid_i : in  std_logic;
        tx_ready_o : out std_logic;
        done_i     : in  std_logic;
        start_o    : out std_logic;
        stop_o     : out std_logic;
        rise_o     : out std_logic;
        fall_o     : out std_logic;
        load_o     : out std_logic
    );
end entity spi_ctrl;

architecture rtl of spi_ctrl is

    type state_t is (S_IDLE, S_FRAME, M_IDLE, M_SCK_LO, M_SCK_HI, M_STOP);

    signal state_reg    : state_t;
    signal cnt_reg      : natural range 0 to SCK_DIV;
    signal sclk_reg     : std_logic;
    signal cs_n_reg     : std_logic;
    signal stop_reg     : std_logic;
    signal ready_reg    : std_logic;
    signal role_reg     : std_logic;
    signal load         : std_logic;
    signal cnt_en_reg   : std_logic;
    signal cnt_end      : std_logic;

    signal m_start      : std_logic;
    signal m_rise       : std_logic;
    signal m_fall       : std_logic;

begin

    cnt_end <= '1' when cnt_reg = SCK_DIV-1 else '0';
    load    <= tx_valid_i and ready_reg;
    m_start <= load and role_reg;

    fsm_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                state_reg  <= S_IDLE;
                sclk_reg   <= '0';
                cs_n_reg   <= '1';
                cnt_en_reg <= '0';
                stop_reg   <= '0';
                ready_reg  <= '1';
                role_reg   <= '0';
            else
                case state_reg is
                    when S_IDLE =>
                        if s_start_i = '1' then
                            state_reg <= S_FRAME;
                            ready_reg <= '0';
                        elsif role_req_i = '1' then
                            state_reg <= M_IDLE;
                            role_reg  <= '1';
                        end if;
                    when S_FRAME =>
                        if s_stop_i = '1' then
                            state_reg <= S_IDLE;
                            ready_reg <= '1';
                        end if;
                    when M_IDLE =>
                        if tx_valid_i = '1' then
                            state_reg  <= M_SCK_LO;
                            cs_n_reg   <= '0';
                            cnt_en_reg <= '1';
                            ready_reg  <= '0';
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
                                state_reg  <= M_STOP;
                                cs_n_reg   <= '1';
                                cnt_en_reg <= '0';
                                stop_reg   <= '1';
                            else
                                state_reg <= M_SCK_LO;
                            end if;
                        end if;
                    when M_STOP =>
                        state_reg <= M_IDLE;
                        stop_reg  <= '0';
                        ready_reg <= '1';
                end case;
            end if;
        end if;
    end process fsm_proc;

    cnt_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                cnt_reg <= 0;
            elsif cnt_en_reg = '1' then
                if cnt_end = '1' then
                    cnt_reg <= 0;
                else
                    cnt_reg <= cnt_reg + 1;
                end if;
            end if;
        end if;
    end process cnt_proc;

    m_rise <= '1' when state_reg = M_SCK_LO and cnt_end = '1' else '0';
    m_fall <= '1' when state_reg = M_SCK_HI and cnt_end = '1' else '0';

    role_ack_o <= role_reg;
    sclk_o     <= sclk_reg;
    sclk_oe    <= role_reg;
    cs_n_o     <= cs_n_reg;
    cs_n_oe    <= role_reg;
    mosi_oe    <= role_reg;
    miso_oe    <= not (cs_pin_i or role_reg);
    tx_ready_o <= ready_reg;
    start_o    <= '1' when m_start = '1' or (s_start_i = '1' and state_reg = S_IDLE) else '0';
    stop_o     <= '1' when stop_reg = '1' or (s_stop_i = '1' and state_reg = S_FRAME) else '0';
    rise_o     <= '1' when m_rise = '1' or (s_rise_i = '1' and state_reg = S_FRAME) else '0';
    fall_o     <= '1' when m_fall = '1' or (s_fall_i = '1' and state_reg = S_FRAME) else '0';
    load_o     <= load;

end architecture rtl;
