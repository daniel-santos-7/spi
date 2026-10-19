----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI port testbench (two ports on one bus, master <-> slave)
-- 2026
----------------------------------------------------------------------
--
-- Two spi_port instances, A and B, share one set of pads modelled as
-- resolved signals with pull resistors (CS# up, SCK/MOSI/MISO down).
-- A port is a slave out of reset and becomes a master while its strap
-- (role_req_i) is 1, switching only between frames; role_ack_o shows
-- the role in effect.
-- Phase 0 straps A as master and B as slave; phase 1 swaps the roles.
-- In one full phase 0 frame both straps flip in the middle of the
-- frame and flip back before it ends: neither port may change role, so
-- the frame and every check around it must be unaffected. In the next
-- one B's strap is 1 for the single cycle B sees CS# fall: the slave
-- frame wins (B offers no reply for it, so it sends zeros). In the last
-- phase 0 frame A's strap drops to 0 as its word is taken, in the
-- frame, and stays there: A must finish the frame as master and only
-- then become a slave, without its own CS# rise reaching its slave
-- logic. Between phases B becomes a master and a slave again with no
-- word offered (no frame); its first word as a master is offered in
-- the cycle after its strap rises. A strap only changes while that
-- port's tx_valid is low, as the client must.
-- A port takes the word to send as a frame starts: the client holds
-- tx_valid and the word until tx_ready, a one-cycle pulse in the cycle
-- after the start; with tx_valid low at the start the frame sends
-- zeros and gives no pulse. Every
-- frame is one word of random data from the master, answered by a
-- random reply word from the slave, with a random tx_bits: mostly 1 to
-- WIDTH bits, sometimes 0 or more than WIDTH, which must give WIDTH
-- bits. The master client sometimes writes the next word once the
-- frame runs (held: taken and sent right after it ends, CS# high for
-- CS_MIN cycles), sometimes as soon as the last one is reported
-- (back-to-back), otherwise after a random gap; the slave client offers
-- each reply once it is planned and holds it until it is taken.
--
-- Phase 2 straps both ports as slaves and drives the pins from a
-- software host, with frames of any length (empty, shorter, equal and
-- longer than WIDTH). Each frame must be reported as one word: the
-- first WIDTH bits, with a count of WIDTH for a longer frame. The host
-- offers one reply word per frame, so any bit after the WIDTH-th must
-- be 0. Each frame with a reply offered, empty ones included, gives one
-- tx_ready pulse per port at its start, and none during the frame. One
-- host frame, after a shorter one, has its reply offered only in the
-- cycle after the ports see CS# fall: too late, so it must send zeros
-- (not what the shorter frame left in the shift register) with no
-- tx_ready pulse, and the reply, held, goes out in the next frame.
-- Both slaves get the same reply, so MISO contention is not checked
-- in this phase (every reply bit the host samples is). Each word is
-- reported with a one-cycle rx_valid pulse.
-- In one host frame both ports are reset halfway through: with CS#
-- still low after the reset they must stay out of that frame (no word
-- reported, MISO not driven during the reset nor after it) and take the
-- next one normally.
-- Then a CS# fall lands in A's first cycle as a slave (the host
-- forces CS# low against A, still a master, as in a collision): A must
-- take the frame and send the reply offered once it is a slave.
-- Last, A masters a behavioural slave that follows the pads directly
-- (no synchroniser, so no SCK limit) with sck_div_i 0 to 3 and
-- back-to-back frames of 1 bit, WIDTH bits, a random length and
-- tx_bits 0; B is cut off from MISO. The model checks every SCK phase,
-- that MOSI has been stable for a cycle at each SCK rise (the first
-- bit included), the CS# high time and the bits it receives; the
-- master must receive the model's reply.
--
-- Checks: every word and bit count the slave reports, the
-- words the master receives (the first tx_bits bits of the reply),
-- CS# high time, SCK phases, MOSI/MISO changing only while SCK is low,
-- frame length, pad contention, pin release, that SCK/CS#/MOSI are
-- driven by the master only, that rx_valid and tx_ready are one-cycle
-- pulses, that role_ack_o follows the strap and
-- changes only while CS# is high, that a slave port ignores tx_bits
-- (driven all ones).
--
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;

entity tb_spi_port is
    generic (
        SCK_DIV     : positive := 5;
        NUM_FRAMES  : positive := 60;
        HOST_FRAMES : positive := 30;
        SEED        : positive := 1;
        WIDTH       : positive := 32;
        CNT_BITS    : positive := 7
    );
end entity tb_spi_port;

architecture sim of tb_spi_port is

    constant CLK_PERIOD : time    := 10 ns;
    constant DIV_BITS   : positive := 8;
    constant CS_MIN     : integer := 2;
    constant MISO_LAT   : integer := 3;
    constant MDL_DLY    : time    := CLK_PERIOD / 4;
    constant GLITCH_F   : integer := 3;
    constant B2B_HI     : integer := 4;
    constant FRAME_CYC  : integer := 2 * WIDTH * SCK_DIV;
    constant HOST_MAX   : integer := 2 * WIDTH + 8;
    constant HOST_URUN  : integer := 5;
    constant HOST_RST   : integer := 10;
    constant MAX_FRAMES : integer := 2 * NUM_FRAMES + 1;
    constant MAX_WORDS  : integer := MAX_FRAMES;
    constant HOST_WORDS : integer := 4 * HOST_FRAMES;
    constant TIMEOUT    : time    := (2 * NUM_FRAMES * (FRAME_CYC + 100) + HOST_FRAMES * (2 * HOST_MAX * SCK_DIV + 100)) * CLK_PERIOD;

    subtype word_t is std_logic_vector(WIDTH-1 downto 0);
    subtype bits_t is std_logic_vector(CNT_BITS-1 downto 0);
    type word_arr_t is array (natural range <>) of word_t;
    type nat_arr_t is array (natural range <>) of natural;

    function hex(v : std_logic_vector) return string is
        constant DIGITS : string(1 to 16) := "0123456789ABCDEF";
        constant N      : natural := (v'length + 3) / 4;
        variable p      : std_logic_vector(4*N-1 downto 0) := (others => '0');
        variable r      : string(1 to N);
    begin
        if is_x(v) then
            return "X";
        end if;
        p(v'length-1 downto 0) := v;
        for i in 0 to N-1 loop
            r(i+1) := DIGITS(to_integer(unsigned(p(4*N-1-4*i downto 4*N-4-4*i))) + 1);
        end loop;
        return r;
    end function hex;

    function top_bits(v : std_logic_vector; k : natural) return std_logic_vector is
        variable r : std_logic_vector(v'length-1 downto 0) := (others => '0');
        variable t : std_logic_vector(v'length-1 downto 0);
    begin
        t := v;
        for i in 0 to k-1 loop
            r(k-1-i) := t(v'length-1-i);
        end loop;
        return r;
    end function top_bits;

    -- clock, reset, control
    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal sim_done  : std_logic := '0';
    signal chk_on    : std_logic := '0';
    signal iso_check : std_logic := '0';
    signal swap      : std_logic := '0';
    signal strap_a   : std_logic := '1';
    signal strap_b   : std_logic := '0';

    -- software host (phase 2)
    signal host_en   : std_logic := '0';
    signal host_sclk : std_logic := '0';
    signal host_cs_n : std_logic := '1';
    signal host_mosi : std_logic := '0';
    signal host_resp : word_t    := (others => '0');
    signal host_wr   : std_logic := '0';
    signal cs_ovr    : std_logic := '0';
    signal div_val   : std_logic_vector(DIV_BITS-1 downto 0);

    -- behavioural slave (master against small dividers)
    signal mdl_en    : std_logic := '0';
    signal mdl_div   : natural   := 0;
    signal mdl_k     : natural   := WIDTH;
    signal mdl_mtx   : word_t    := (others => '0');
    signal mdl_resp  : word_t    := (others => '0');
    signal mdl_miso  : std_logic := 'Z';
    signal mdl_fcnt  : natural   := 0;
    signal hw_n      : natural   := 0;
    signal a_txr_n   : natural   := 0;
    signal b_txr_n   : natural   := 0;
    signal hw_data   : word_arr_t(0 to HOST_WORDS-1);
    signal hw_bits   : nat_arr_t(0 to HOST_WORDS-1);

    -- pads and their logic levels
    signal sclk_pad : std_logic;
    signal cs_n_pad : std_logic;
    signal mosi_pad : std_logic;
    signal miso_pad : std_logic;
    signal sclk_in  : std_logic;
    signal cs_n_in  : std_logic;
    signal mosi_in  : std_logic;
    signal miso_in  : std_logic;

    -- port A
    signal a_role_ack   : std_logic;
    signal a_sclk_o     : std_logic;
    signal a_sclk_oe    : std_logic;
    signal a_cs_n_o     : std_logic;
    signal a_cs_n_oe    : std_logic;
    signal a_mosi_o     : std_logic;
    signal a_mosi_oe    : std_logic;
    signal a_miso_o     : std_logic;
    signal a_miso_oe    : std_logic;
    signal a_tx_valid   : std_logic;
    signal a_tx_ready   : std_logic;
    signal a_tx_data    : word_t;
    signal a_tx_bits    : bits_t;
    signal a_rx_data    : word_t;
    signal a_rx_bits    : std_logic_vector(CNT_BITS-1 downto 0);
    signal a_rx_valid   : std_logic;

    -- port B
    signal b_role_ack   : std_logic;
    signal b_sclk_o     : std_logic;
    signal b_sclk_oe    : std_logic;
    signal b_cs_n_o     : std_logic;
    signal b_cs_n_oe    : std_logic;
    signal b_mosi_o     : std_logic;
    signal b_mosi_oe    : std_logic;
    signal b_miso_o     : std_logic;
    signal b_miso_oe    : std_logic;
    signal b_tx_valid   : std_logic;
    signal b_tx_ready   : std_logic;
    signal b_tx_data    : word_t;
    signal b_tx_bits    : bits_t;
    signal b_rx_data    : word_t;
    signal b_rx_bits    : std_logic_vector(CNT_BITS-1 downto 0);
    signal b_rx_valid   : std_logic;

    -- master client (whichever port is strapped as master)
    signal m_tx_valid : std_logic := '0';
    signal m_tx_ready : std_logic;
    signal m_tx_data  : word_t    := (others => '0');
    signal m_tx_bits  : bits_t    := (others => '0');
    signal m_rx_data  : word_t;
    signal m_rx_valid : std_logic;
    signal m_rx_wcnt  : natural := 0;
    signal m_rx_fcnt  : natural := 0;

    -- slave client (whichever port is strapped as slave)
    signal s_tx_valid : std_logic;
    signal s_tx_ready : std_logic;
    signal s_tx_data  : word_t;
    signal s_tx_cnt   : natural := 0;
    signal s_rx_data  : word_t;
    signal s_rx_bits  : std_logic_vector(CNT_BITS-1 downto 0);
    signal s_rx_valid : std_logic;
    signal s_rx_wcnt  : natural := 0;

    -- test plan, per word and per frame
    signal plan_wcnt  : natural := 0;
    signal plan_mtx   : word_arr_t(0 to MAX_WORDS-1);
    signal plan_sresp : word_arr_t(0 to MAX_WORDS-1)        := (others => (others => '0'));
    signal plan_wbits : nat_arr_t(0 to MAX_WORDS-1)         := (others => WIDTH);
    signal plan_wlast : std_logic_vector(0 to MAX_WORDS-1)  := (others => '0');
    signal plan_flen  : nat_arr_t(0 to MAX_FRAMES-1)        := (others => WIDTH);
    signal plan_b2b   : std_logic_vector(0 to MAX_FRAMES-1) := (others => '0');
    signal plan_held  : std_logic_vector(0 to MAX_FRAMES-1) := (others => '0');
    signal plan_skip  : std_logic_vector(0 to MAX_WORDS-1)  := (others => '0');

begin

    assert SCK_DIV >= 5 report "TB: the slave needs SCK <= clk/10, so SCK_DIV must be at least 5." severity failure;
    assert SCK_DIV <= 2**DIV_BITS - 1
        report "TB: SCK_DIV-1 must fit sck_div_i and differ from all ones (the value driven while CS# is low)." severity failure;

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0' else '0';

    ------------------------------------------------------------------
    -- DUTs and bus
    ------------------------------------------------------------------

    tb_spi_port_a: entity work.spi_port generic map (
        DIV_BITS => DIV_BITS,
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i      => clk,
        rst_i      => rst,
        role_req_i => strap_a,
        sck_div_i  => div_val,
        sclk_i     => sclk_in,
        cs_n_i     => cs_n_in,
        mosi_i     => mosi_in,
        miso_i     => miso_in,
        tx_valid_i => a_tx_valid,
        tx_data_i  => a_tx_data,
        tx_bits_i  => a_tx_bits,
        role_ack_o => a_role_ack,
        sclk_o     => a_sclk_o,
        sclk_oe    => a_sclk_oe,
        cs_n_o     => a_cs_n_o,
        cs_n_oe    => a_cs_n_oe,
        mosi_o     => a_mosi_o,
        mosi_oe    => a_mosi_oe,
        miso_o     => a_miso_o,
        miso_oe    => a_miso_oe,
        tx_ready_o => a_tx_ready,
        rx_data_o  => a_rx_data,
        rx_bits_o  => a_rx_bits,
        rx_valid_o => a_rx_valid
    );

    tb_spi_port_b: entity work.spi_port generic map (
        DIV_BITS => DIV_BITS,
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i      => clk,
        rst_i      => rst,
        role_req_i => strap_b,
        sck_div_i  => div_val,
        sclk_i     => sclk_in,
        cs_n_i     => cs_n_in,
        mosi_i     => mosi_in,
        miso_i     => miso_in,
        tx_valid_i => b_tx_valid,
        tx_data_i  => b_tx_data,
        tx_bits_i  => b_tx_bits,
        role_ack_o => b_role_ack,
        sclk_o     => b_sclk_o,
        sclk_oe    => b_sclk_oe,
        cs_n_o     => b_cs_n_o,
        cs_n_oe    => b_cs_n_oe,
        mosi_o     => b_mosi_o,
        mosi_oe    => b_mosi_oe,
        miso_o     => b_miso_o,
        miso_oe    => b_miso_oe,
        tx_ready_o => b_tx_ready,
        rx_data_o  => b_rx_data,
        rx_bits_o  => b_rx_bits,
        rx_valid_o => b_rx_valid
    );

    sclk_pad <= a_sclk_o when a_sclk_oe = '1' else 'Z';
    sclk_pad <= b_sclk_o when b_sclk_oe = '1' else 'Z';
    sclk_pad <= host_sclk when host_en = '1' else 'Z';
    sclk_pad <= 'L';
    cs_n_pad <= a_cs_n_o when a_cs_n_oe = '1' else 'Z';
    cs_n_pad <= b_cs_n_o when b_cs_n_oe = '1' else 'Z';
    cs_n_pad <= host_cs_n when host_en = '1' else 'Z';
    cs_n_pad <= 'H';
    mosi_pad <= a_mosi_o when a_mosi_oe = '1' else 'Z';
    mosi_pad <= b_mosi_o when b_mosi_oe = '1' else 'Z';
    mosi_pad <= host_mosi when host_en = '1' else 'Z';
    mosi_pad <= 'L';
    miso_pad <= a_miso_o when a_miso_oe = '1' else 'Z';
    miso_pad <= b_miso_o when b_miso_oe = '1' and mdl_en = '0' else 'Z';
    miso_pad <= mdl_miso;
    miso_pad <= 'L';

    -- the master takes the divider as a frame starts (CS# still high):
    -- any other value while CS# is low must not change the frame
    div_val <= std_logic_vector(to_unsigned(mdl_div, DIV_BITS))   when cs_n_in = '1' and mdl_en = '1' else
               std_logic_vector(to_unsigned(SCK_DIV-1, DIV_BITS)) when cs_n_in = '1' else
               (others => '1');

    sclk_in <= to_x01(sclk_pad);
    -- cs_ovr: the host wins over a master driving CS# (collision model)
    cs_n_in <= host_cs_n when cs_ovr = '1' else to_x01(cs_n_pad);
    mosi_in <= to_x01(mosi_pad);
    miso_in <= to_x01(miso_pad);

    -- Each port's client is the one of its role: the master client, the
    -- slave client or, in phase 2, the host. A slave port gets tx_bits
    -- all ones, which it must ignore.
    a_tx_valid   <= host_wr   when host_en = '1' else m_tx_valid when swap = '0' else s_tx_valid;
    a_tx_data    <= host_resp when host_en = '1' else m_tx_data  when swap = '0' else s_tx_data;
    a_tx_bits    <= m_tx_bits when host_en = '0' and swap = '0' else (others => '1');
    b_tx_valid   <= host_wr   when host_en = '1' else m_tx_valid when swap = '1' else s_tx_valid;
    b_tx_data    <= host_resp when host_en = '1' else m_tx_data  when swap = '1' else s_tx_data;
    b_tx_bits    <= m_tx_bits when host_en = '0' and swap = '1' else (others => '1');
    m_tx_ready   <= a_tx_ready   when swap = '0' else b_tx_ready;
    m_rx_data    <= a_rx_data    when swap = '0' else b_rx_data;
    m_rx_valid   <= a_rx_valid   when swap = '0' else b_rx_valid;

    s_tx_ready   <= b_tx_ready   when swap = '0' else a_tx_ready;
    s_rx_data    <= b_rx_data    when swap = '0' else a_rx_data;
    s_rx_bits    <= b_rx_bits    when swap = '0' else a_rx_bits;
    s_rx_valid   <= b_rx_valid   when swap = '0' else a_rx_valid;

    ------------------------------------------------------------------
    -- Stimulus: test plan, master client and software host
    ------------------------------------------------------------------

    stim_proc: process
        variable s1      : positive := SEED;
        variable s2      : positive := 7919;
        variable r       : real;
        variable v       : integer;
        variable g       : integer;
        variable n       : integer;
        variable k       : integer;
        variable frame   : natural := 0;
        variable word    : natural := 0;
        variable b2b     : boolean := false;
        variable held    : boolean := false;
        variable mtx     : word_t;
        variable resp    : word_t;
        variable pend    : boolean := false;
        variable pword   : word_t  := (others => '0');
        variable hbits   : std_logic_vector(HOST_MAX-1 downto 0);
        variable hrx     : std_logic_vector(HOST_MAX-1 downto 0);
        variable exp_rx  : word_t;
        variable len     : integer;
        variable ew      : integer;
        variable eb      : integer;
        variable hw0     : natural;
        variable txa0    : natural;
        variable txb0    : natural;
        variable txp     : natural;
        variable fc0     : natural;
        variable n_b2b   : natural := 0;
        variable n_held  : natural := 0;
        variable n_mshrt : natural := 0;
        variable n_mclip : natural := 0;
        variable n_empty : natural := 0;
        variable n_short : natural := 0;
        variable n_exact : natural := 0;
        variable n_long  : natural := 0;

        procedure rnd(lo, hi : in integer; x : out integer) is
            variable t : integer;
        begin
            uniform(s1, s2, r);
            t := lo + integer(trunc(r * real(hi - lo + 1)));
            if t > hi then
                t := hi;
            end if;
            x := t;
        end procedure rnd;

        procedure rnd_bits(x : out std_logic_vector) is
            variable t : std_logic_vector(x'range);
            variable b : integer;
        begin
            for i in t'range loop
                rnd(0, 1, b);
                if b = 1 then
                    t(i) := '1';
                else
                    t(i) := '0';
                end if;
            end loop;
            x := t;
        end procedure rnd_bits;

        procedure cycles(c : in natural) is
        begin
            for i in 1 to c loop
                wait until rising_edge(clk);
            end loop;
        end procedure cycles;
    begin
        rst <= '1';
        cycles(10);
        rst <= '0';
        cycles(10);
        chk_on    <= '1';
        iso_check <= '1';

        for ph in 0 to 1 loop
            if ph = 1 then
                -- strap A as slave too, check that nobody drives the bus,
                -- then strap B as master
                iso_check <= '0';
                strap_a   <= '0';
                cycles(10);
                assert sclk_pad = 'L' and cs_n_pad = 'H' and mosi_pad = 'L' and miso_pad = 'L'
                    report "TB: pins still driven with both ports strapped as slave" severity error;
                assert a_role_ack = '0' and b_role_ack = '0'
                    report "TB: role_ack does not follow the strap" severity error;
                swap <= '1';
                -- B becomes a master and a slave again with no word offered:
                -- no frame
                strap_b <= '1';
                cycles(10);
                assert b_tx_ready = '0' and b_role_ack = '1' and cs_n_in = '1'
                    report "TB: B started a frame with no word offered" severity error;
                strap_b <= '0';
                cycles(10);
                report "TB: roles swapped, A is slave and B is master" severity note;
            end if;

            b2b  := false;
            held := false;
            for f in 1 to NUM_FRAMES loop
                rnd_bits(mtx);
                rnd_bits(resp);
                rnd(0, 7, v);
                if v = 0 then
                    len := 0;
                elsif v = 1 and WIDTH < 2**CNT_BITS-1 then
                    rnd(WIDTH+1, 2**CNT_BITS-1, len);
                elsif v <= 3 then
                    len := WIDTH;
                else
                    rnd(1, WIDTH, len);
                end if;
                if ph = 0 and (f = GLITCH_F or f = NUM_FRAMES) then
                    len := WIDTH;
                end if;
                if len = 0 or len > WIDTH then
                    k       := WIDTH;
                    n_mclip := n_mclip + 1;
                else
                    k := len;
                end if;
                if k < WIDTH then
                    n_mshrt := n_mshrt + 1;
                end if;
                if ph = 0 and f = GLITCH_F + 1 then
                    -- B's strap changes as this frame starts: the slave client
                    -- offers no reply (role_req_i only changes with tx_valid_i
                    -- low), so B sends zeros
                    resp := (others => '0');
                    plan_skip(word) <= '1';
                end if;
                plan_wlast(word)  <= '1';
                plan_mtx(word)    <= mtx;
                plan_sresp(word)  <= resp;
                plan_wbits(word)  <= k;
                plan_flen(frame)  <= k;
                if b2b then
                    plan_b2b(frame) <= '1';
                end if;
                if held then
                    plan_held(frame) <= '1';
                end if;
                plan_wcnt <= word + 1;

                m_tx_data  <= mtx;
                m_tx_bits  <= std_logic_vector(to_unsigned(len, CNT_BITS));
                if ph = 1 and f = 1 then
                    -- B's first word as a master is offered in the cycle after
                    -- its strap rises
                    strap_b <= '1';
                    cycles(1);
                end if;
                if held then
                    -- write the next word once the frame before it runs
                    wait until rising_edge(clk) and cs_n_in = '0';
                end if;
                m_tx_valid <= '1';
                loop
                    wait until rising_edge(clk);
                    exit when m_tx_ready = '1';
                end loop;
                m_tx_valid <= '0';
                if ph = 0 and f = NUM_FRAMES then
                    -- drop A's strap for good as its last word is taken, in
                    -- the frame: A becomes a slave only once the frame is
                    -- over
                    iso_check <= '0';
                    strap_a   <= '0';
                end if;
                if ph = 1 and f = 1 then
                    cycles(10);
                    iso_check <= '1';
                end if;
                if ph = 0 and f = GLITCH_F + 1 then
                    -- B's strap is 1 exactly when B sees CS# fall: the slave
                    -- frame wins (B sends zeros, no reply offered); the wait
                    -- starts one cycle after the start, as the tx_ready pulse
                    wait until rising_edge(clk) and cs_n_in = '0';
                    strap_b <= '1';
                    cycles(1);
                    strap_b <= '0';
                end if;
                if ph = 0 and f = GLITCH_F then
                    -- flip both straps in the middle of a full frame and back
                    -- before it ends: the frame must not change at all
                    cycles(4 * SCK_DIV);
                    strap_a <= '0';
                    strap_b <= '1';
                    cycles(4 * SCK_DIV);
                    strap_a <= '1';
                    strap_b <= '0';
                end if;
                frame := frame + 1;
                word  := word + 1;

                -- held: the next word is written while this frame runs and
                -- sent as it ends (not for the glitch frames, timed from
                -- their write); b2b: written as this one is reported
                rnd(0, 5, v);
                held := v = 0 and f < NUM_FRAMES - 1 and not (ph = 0 and f >= GLITCH_F - 1 and f <= GLITCH_F + 1);
                b2b  := v = 1 and f < NUM_FRAMES;
                if held then
                    n_held := n_held + 1;
                else
                    loop
                        wait until rising_edge(clk);
                        exit when m_rx_fcnt = frame;
                    end loop;
                    if b2b then
                        n_b2b := n_b2b + 1;
                    else
                        rnd(1, 30, g);
                        cycles(g);
                    end if;
                end if;
            end loop;

            loop
                wait until rising_edge(clk);
                exit when m_rx_wcnt = word and s_rx_wcnt = word;
            end loop;
            cycles(10);
        end loop;

        -- phase 2: both ports slaves, frames of any length from the host
        iso_check <= '0';
        strap_b   <= '0';
        cycles(10);
        host_en <= '1';
        cycles(10);
        report "TB: both ports are slaves, the software host drives the pins" severity note;

        for f in 1 to HOST_FRAMES loop
            if f = 1 then
                n := 0;
            elsif f = 2 then
                n := WIDTH;
            elsif f = 3 then
                n := HOST_MAX;
            elsif f = 4 then
                n := WIDTH / 2;
            elsif f = HOST_RST then
                n := WIDTH;
            elsif f = HOST_URUN then
                rnd(3, HOST_MAX, n);
            else
                rnd(1, HOST_MAX, n);
            end if;
            rnd_bits(hbits);
            assert a_tx_ready = '0' and b_tx_ready = '0'
                report "host: frame " & integer'image(f) & " tx_ready high between frames" severity error;
            if pend then
                resp := pword;  -- offered during the underrun frame, still held
            elsif f = HOST_URUN then
                resp := (others => '0');
            else
                rnd_bits(resp);
                host_resp <= resp;
                host_wr   <= '1';
            end if;
            pend := false;
            cycles(2);
            hw0  := hw_n;
            txa0 := a_txr_n;
            txb0 := b_txr_n;
            txp  := 1;
            if f = HOST_URUN then
                txp := 0;  -- no reply offered: no tx_ready pulse
            end if;

            host_cs_n <= '0';
            if f = HOST_URUN then
                -- the reply is offered in the cycle after the ports see CS#
                -- fall (start): too late for this frame, so no tx_ready and
                -- zeros; it is held and goes out in the next frame
                cycles(3);
                rnd_bits(pword);
                host_resp <= pword;
                host_wr   <= '1';
                cycles(SCK_DIV - 3);
            else
                cycles(SCK_DIV);
            end if;
            -- both ports have started the frame: one tx_ready pulse each if a
            -- reply was offered
            assert a_txr_n = txa0 + txp and b_txr_n = txb0 + txp
                report "host: frame " & integer'image(f) & " wrong tx_ready pulses at the start" severity error;
            if f /= HOST_URUN then
                host_wr <= '0';
            end if;
            for i in 0 to n-1 loop
                if f = HOST_RST and i = n / 2 then
                    -- reset both ports in the middle of the frame
                    rst <= '1';
                    cycles(2);
                    assert a_miso_oe = '0' and b_miso_oe = '0'
                        report "host: frame " & integer'image(f) & " MISO driven during reset" severity error;
                    cycles(1);
                    rst <= '0';
                end if;
                host_mosi <= hbits(HOST_MAX-1-i);
                cycles(SCK_DIV);
                host_sclk <= '1';
                hrx(HOST_MAX-1-i) := miso_in;
                assert a_tx_ready = '0' and b_tx_ready = '0'
                    report "host: frame " & integer'image(f) & " tx_ready high during the frame" severity error;
                assert a_rx_valid = '0' and b_rx_valid = '0'
                    report "host: frame " & integer'image(f) & " rx_valid high during the frame" severity error;
                assert (a_miso_oe = '0' and b_miso_oe = '0') or not (f = HOST_RST and i >= n / 2)
                    report "host: frame " & integer'image(f) & " MISO driven after a reset in the frame" severity error;
                cycles(SCK_DIV);
                host_sclk <= '0';
            end loop;
            cycles(SCK_DIV);
            host_cs_n <= '1';
            host_mosi <= '0';
            if f = HOST_URUN then
                pend := true;  -- pword
            end if;
            for i in 0 to n-1 loop
                if f = HOST_RST then
                    null;  -- the reset clears the reply
                elsif i < WIDTH then
                    assert hrx(HOST_MAX-1-i) = resp(WIDTH-1-i)
                        report "host: frame " & integer'image(f) & " reply bit " & integer'image(i) & " wrong" severity error;
                else
                    assert hrx(HOST_MAX-1-i) = '0'
                        report "host: frame " & integer'image(f) & " reply bit " & integer'image(i) & " is not 0" severity error;
                end if;
            end loop;
            cycles(10);

            ew := 1;
            if f = HOST_RST then
                -- the ports came out of reset with CS# low: they must stay
                -- out of this frame and report nothing
                ew := 0;
            end if;
            assert hw_n = hw0 + ew
                report "host: frame " & integer'image(f) & " (" & integer'image(n) & " bits) reported " &
                       integer'image(hw_n - hw0) & " words, expected " & integer'image(ew) severity error;
            for w in 0 to ew-1 loop
                if n = 0 then
                    eb := 0;
                elsif n - w*WIDTH < WIDTH then
                    eb := n - w*WIDTH;
                else
                    eb := WIDTH;
                end if;
                exp_rx := (others => '0');
                for i in 0 to eb-1 loop
                    exp_rx(eb-1-i) := hbits(HOST_MAX-1-w*WIDTH-i);
                end loop;
                if hw0 + w < hw_n then
                    assert hw_bits(hw0+w) = eb
                        report "host: frame " & integer'image(f) & " word " & integer'image(w) & " reported " &
                               integer'image(hw_bits(hw0+w)) & " bits, expected " & integer'image(eb) severity error;
                    assert hw_data(hw0+w) = exp_rx
                        report "host: frame " & integer'image(f) & " word " & integer'image(w) & " is " & hex(hw_data(hw0+w)) &
                               ", expected " & hex(exp_rx) severity error;
                end if;
            end loop;

            if n = 0 then
                n_empty := n_empty + 1;
            elsif n < WIDTH then
                n_short := n_short + 1;
            elsif n = WIDTH then
                n_exact := n_exact + 1;
            else
                n_long := n_long + 1;
            end if;
            rnd(10, 30, g);
            cycles(g);
        end loop;

        host_en <= '0';
        swap    <= '0';
        cycles(2);

        -- a CS# fall in A's first cycle as a slave: the host forces CS# low
        -- against A (still a master; SCK and MOSI stay A's until it is a
        -- slave), the strap drops, and a reply is
        -- offered to A and B (both send the same word) once A is a slave;
        -- A must take the frame and send it
        strap_a <= '1';
        cycles(10);
        rnd_bits(hbits);
        rnd_bits(resp);
        resp(WIDTH-1) := '1';
        cs_ovr    <= '1';
        host_cs_n <= '0';
        hw0       := hw_n;
        txa0      := a_txr_n;
        cycles(1);
        strap_a   <= '0';
        cycles(1);
        host_en   <= '1';  -- A has released SCK and MOSI
        host_resp <= resp;
        host_wr   <= '1';
        cycles(SCK_DIV);
        host_wr <= '0';
        cs_ovr  <= '0';  -- A has released CS#: the host drives the pad
        for i in 0 to WIDTH-1 loop
            host_mosi <= hbits(HOST_MAX-1-i);
            cycles(SCK_DIV);
            host_sclk <= '1';
            hrx(HOST_MAX-1-i) := miso_in;
            assert a_tx_ready = '0'
                report "TB: frame after the role change, tx_ready high during the frame" severity error;
            cycles(SCK_DIV);
            host_sclk <= '0';
        end loop;
        cycles(SCK_DIV);
        host_cs_n <= '1';
        host_mosi <= '0';
        cycles(10);
        exp_rx := (others => '0');
        for i in 0 to WIDTH-1 loop
            exp_rx(WIDTH-1-i) := hbits(HOST_MAX-1-i);
            assert hrx(HOST_MAX-1-i) = resp(WIDTH-1-i)
                report "TB: frame after the role change, reply bit " & integer'image(i) & " wrong" severity error;
        end loop;
        assert a_role_ack = '0' and a_txr_n = txa0 + 1 and hw_n = hw0 + 1 and
               hw_bits(hw0) = WIDTH and hw_data(hw0) = exp_rx
            report "TB: CS# fall right after the role change lost" severity error;
        host_en   <= '0';

        -- A masters a behavioural slave (no synchroniser, so no SCK limit)
        -- with dividers 0 to 3: 1-bit, WIDTH-bit, random and tx_bits 0
        -- frames, back-to-back; B is a slave cut off from MISO
        mdl_en  <= '1';
        strap_a <= '1';
        cycles(10);
        for d in 0 to 3 loop
            mdl_div <= d;
            for j in 1 to 4 loop
                rnd_bits(mtx);
                rnd_bits(resp);
                if j = 1 then
                    len := 1;
                elsif j = 2 then
                    len := WIDTH;
                elsif j = 3 then
                    rnd(2, WIDTH-1, len);
                else
                    len := 0;
                end if;
                k := len;
                if len = 0 then
                    k := WIDTH;
                end if;
                mdl_k      <= k;
                mdl_mtx    <= mtx;
                mdl_resp   <= resp;
                m_tx_data  <= mtx;
                m_tx_bits  <= std_logic_vector(to_unsigned(len, CNT_BITS));
                fc0        := mdl_fcnt;
                m_tx_valid <= '1';
                loop
                    wait until rising_edge(clk);
                    exit when a_tx_ready = '1';
                end loop;
                m_tx_valid <= '0';
                loop
                    wait until rising_edge(clk);
                    exit when a_rx_valid = '1';
                end loop;
                assert mdl_fcnt = fc0 + 1 and to_integer(unsigned(a_rx_bits)) = k and a_rx_data = top_bits(resp, k)
                    report "model: divider " & integer'image(d) & " frame " & integer'image(j) & " master word is " &
                           hex(a_rx_data) & ", expected " & hex(top_bits(resp, k)) severity error;
            end loop;
        end loop;
        strap_a <= '0';
        cycles(10);
        mdl_en  <= '0';

        assert n_b2b > 0 and n_held > 0 and n_mshrt > 0 and n_mclip > 0
            report "TB: coverage hole (back-to-back, held, shorter or clipped master frame)" severity error;
        report "TB: PASS - " & integer'image(frame) & " master frames, " & integer'image(word) & " words of " &
               integer'image(WIDTH) & " bits (" & integer'image(n_b2b) & " back-to-back, " & integer'image(n_held) & " held, " &
               integer'image(n_mshrt) & " shorter, " & integer'image(n_mclip) &
               " with tx_bits 0 or over WIDTH), " & integer'image(HOST_FRAMES) & " host frames (" &
               integer'image(n_empty) & " empty, " & integer'image(n_short) & " shorter, " &
               integer'image(n_exact) & " exact, " & integer'image(n_long) & " longer)"
            severity note;
        sim_done <= '1';
        wait;
    end process stim_proc;

    ------------------------------------------------------------------
    -- Slave client: writes each reply, checks each received word
    ------------------------------------------------------------------

    s_tx_data  <= plan_sresp(s_tx_cnt);
    -- each reply is offered once planned and held until the port takes it;
    -- a skipped reply is passed once its frame is reported
    s_tx_valid <= '1' when host_en = '0' and s_tx_cnt < plan_wcnt and plan_skip(s_tx_cnt) = '0' else '0';

    slave_tx_proc: process
    begin
        wait until rising_edge(clk);
        if (s_tx_valid = '1' and s_tx_ready = '1') or (plan_skip(s_tx_cnt) = '1' and s_rx_wcnt > s_tx_cnt) then
            s_tx_cnt <= s_tx_cnt + 1;
        end if;
    end process slave_tx_proc;

    slave_rx_proc: process
        variable i : natural := 0;
    begin
        wait until rising_edge(clk);
        if chk_on = '1' and host_en = '0' and mdl_en = '0' and s_rx_valid = '1' then
            assert i < plan_wcnt
                report "slave: unexpected word " & hex(s_rx_data) severity error;
            assert to_integer(unsigned(s_rx_bits)) = plan_wbits(i)
                report "slave: word " & integer'image(i) & " reported " & integer'image(to_integer(unsigned(s_rx_bits))) &
                       " bits, expected " & integer'image(plan_wbits(i)) severity error;
            assert s_rx_data = top_bits(plan_mtx(i), plan_wbits(i))
                report "slave: word " & integer'image(i) & " is " & hex(s_rx_data) &
                       ", expected " & hex(top_bits(plan_mtx(i), plan_wbits(i))) severity error;
            i := i + 1;
            s_rx_wcnt <= i;
        end if;
    end process slave_rx_proc;

    ------------------------------------------------------------------
    -- Host receive recorder (phase 2): both slaves must report alike
    ------------------------------------------------------------------

    host_rx_proc: process
    begin
        wait until rising_edge(clk);
        if host_en = '1' and a_rx_valid = '1' then
            assert b_rx_valid = '1' and b_rx_data = a_rx_data and b_rx_bits = a_rx_bits
                report "host: the two slaves report different words" severity error;
            hw_data(hw_n) <= a_rx_data;
            hw_bits(hw_n) <= to_integer(unsigned(a_rx_bits));
            hw_n          <= hw_n + 1;
        end if;
    end process host_rx_proc;

    ------------------------------------------------------------------
    -- Master receive checker
    ------------------------------------------------------------------

    master_rx_proc: process
        variable j  : natural := 0;
        variable hi : natural := 0;
    begin
        wait until rising_edge(clk);
        if chk_on = '1' and host_en = '0' and mdl_en = '0' and m_rx_valid = '1' then
            assert j < plan_wcnt
                report "master: unexpected word " & hex(m_rx_data) severity error;
            assert m_rx_data = top_bits(plan_sresp(j), plan_wbits(j))
                report "master: word " & integer'image(j) & " is " & hex(m_rx_data) &
                       ", expected " & hex(top_bits(plan_sresp(j), plan_wbits(j))) severity error;
            if plan_wlast(j) = '1' then
                assert cs_n_in = '1' and hi = 1
                    report "master: last word " & integer'image(j) & " not reported in the second cycle with CS# high" severity error;
                m_rx_fcnt <= m_rx_fcnt + 1;
            else
                assert cs_n_in = '0'
                    report "master: word " & integer'image(j) & " reported with CS# high but not last" severity error;
            end if;
            j := j + 1;
            m_rx_wcnt <= j;
        end if;
        if cs_n_in = '1' then
            hi := hi + 1;
        else
            hi := 0;
        end if;
    end process master_rx_proc;

    ------------------------------------------------------------------
    -- Bus monitor: protocol, timing, contention, role isolation
    ------------------------------------------------------------------

    bus_mon_proc: process
        variable sclk_p : std_logic;
        variable cs_p   : std_logic;
        variable mosi_p : std_logic;
        variable miso_p : std_logic;
        variable phase  : natural := 0;
        variable lo_cnt : natural := 0;
        variable hi_cnt : natural := CS_MIN;
        variable frame  : natural := 0;
        variable a_ack  : std_logic;
        variable b_ack  : std_logic;
        variable cs_run : natural := 0;
    begin
        wait until rising_edge(clk) and chk_on = '1';
        a_ack  := a_role_ack;
        b_ack  := b_role_ack;
        sclk_p := sclk_in;
        cs_p   := cs_n_in;
        mosi_p := mosi_in;
        miso_p := miso_in;
        loop
            wait until rising_edge(clk);

            assert sclk_in /= 'X' and cs_n_in /= 'X' and mosi_in /= 'X' and (miso_in /= 'X' or host_en = '1')
                report "bus: contention on a pad" severity error;

            -- cycles since CS# last changed: the slave follows CS# through
            -- the synchroniser, so MISO is taken and released MISO_LAT late
            -- (3 here, where the synchroniser always takes 2 cycles; 3 to 4
            -- in hardware)
            if cs_n_in /= cs_p then
                cs_run := 0;
            else
                cs_run := cs_run + 1;
            end if;

            if cs_n_in = '1' then
                assert sclk_in = '0'
                    report "bus: SCK high while CS# is high" severity error;
                assert miso_pad = 'L' or cs_run < MISO_LAT
                    report "bus: MISO driven while CS# is high" severity error;
            end if;

            if host_en = '0' and mdl_en = '0' then
                -- frame boundaries
                if cs_p = '1' and cs_n_in = '0' then
                    assert sclk_in = '0'
                        report "bus: SCK high when CS# falls" severity error;
                    assert hi_cnt >= CS_MIN
                        report "bus: CS# high for " & integer'image(hi_cnt) & " cycles before frame " &
                               integer'image(frame) severity error;
                    if plan_held(frame) = '1' then
                        assert hi_cnt = CS_MIN
                            report "bus: held frame " & integer'image(frame) & " waited " &
                                   integer'image(hi_cnt) & " cycles with CS# high" severity error;
                    end if;
                    if plan_b2b(frame) = '1' then
                        assert hi_cnt = B2B_HI
                            report "bus: back-to-back frame " & integer'image(frame) & " waited " &
                                   integer'image(hi_cnt) & " cycles with CS# high" severity error;
                    end if;
                    lo_cnt := 0;
                    phase  := 0;
                elsif cs_p = '0' and cs_n_in = '1' then
                    assert lo_cnt = 2 * plan_flen(frame) * SCK_DIV
                        report "bus: frame " & integer'image(frame) & " had CS# low for " & integer'image(lo_cnt) &
                               " cycles, expected " & integer'image(2 * plan_flen(frame) * SCK_DIV) severity error;
                    if sclk_p = '1' then
                        assert phase = SCK_DIV
                            report "bus: last SCK high phase lasted " & integer'image(phase) & " cycles" severity error;
                    end if;
                    frame  := frame + 1;
                    hi_cnt := 0;
                end if;
                if cs_n_in = '0' then
                    lo_cnt := lo_cnt + 1;
                else
                    hi_cnt := hi_cnt + 1;
                end if;

                -- SCK phases inside a frame
                if cs_n_in = '0' then
                    if sclk_in /= sclk_p and phase > 0 then
                        assert phase = SCK_DIV
                            report "bus: SCK phase lasted " & integer'image(phase) & " cycles" severity error;
                        phase := 1;
                    else
                        phase := phase + 1;
                    end if;
                end if;
            end if;

            -- data changes only while SCK is low
            if cs_n_in = '0' and cs_p = '0' then
                assert mosi_in = mosi_p or sclk_in = '0'
                    report "bus: MOSI changed while SCK is high" severity error;
                assert miso_in = miso_p or sclk_in = '0'
                    report "bus: MISO changed while SCK is high" severity error;
            end if;

            -- SCK, CS# and MOSI are driven together, by the master only;
            -- MISO by the slave while CS# is low
            assert a_sclk_oe = a_cs_n_oe and a_mosi_oe = a_cs_n_oe and
                   b_sclk_oe = b_cs_n_oe and b_mosi_oe = b_cs_n_oe
                report "bus: SCK, CS# and MOSI enables differ" severity error;
            -- the role changes only between frames
            assert (a_role_ack = a_ack and b_role_ack = b_ack) or cs_n_in = '1' or cs_ovr = '1'
                report "bus: role_ack changed while CS# is low" severity error;
            if iso_check = '1' then
                assert (a_role_ack = '1' and b_role_ack = '0' and swap = '0') or
                       (a_role_ack = '0' and b_role_ack = '1' and swap = '1')
                    report "bus: role_ack does not follow the strap" severity error;
                assert (sclk_pad = '0' or sclk_pad = '1') and (cs_n_pad = '0' or cs_n_pad = '1') and
                       (mosi_pad = '0' or mosi_pad = '1')
                    report "bus: master pins not driven" severity error;
                if cs_n_in = '0' and cs_run >= MISO_LAT then
                    assert miso_pad = '0' or miso_pad = '1'
                        report "bus: MISO not driven by the slave while CS# is low" severity error;
                end if;
                if swap = '0' then
                    assert b_cs_n_oe = '0' and a_miso_oe = '0'
                        report "bus: slave port B drives master pins or master port A drives MISO" severity error;
                else
                    assert a_cs_n_oe = '0' and b_miso_oe = '0'
                        report "bus: slave port A drives master pins or master port B drives MISO" severity error;
                end if;
            end if;

            sclk_p := sclk_in;
            cs_p   := cs_n_in;
            mosi_p := mosi_in;
            miso_p := miso_in;
            a_ack  := a_role_ack;
            b_ack  := b_role_ack;
        end loop;
    end process bus_mon_proc;

    -- rx_valid and tx_ready are one-cycle pulses; tx_ready pulses are
    -- counted for the host phase
    pulse_proc: process
        variable a_rx_p : std_logic := '0';
        variable b_rx_p : std_logic := '0';
        variable a_tx_p : std_logic := '0';
        variable b_tx_p : std_logic := '0';
    begin
        wait until rising_edge(clk);
        assert not (a_rx_valid = '1' and a_rx_p = '1') and not (b_rx_valid = '1' and b_rx_p = '1')
            report "TB: rx_valid high for more than one cycle" severity error;
        assert not (a_tx_ready = '1' and a_tx_p = '1') and not (b_tx_ready = '1' and b_tx_p = '1')
            report "TB: tx_ready high for more than one cycle" severity error;
        if a_tx_ready = '1' then
            a_txr_n <= a_txr_n + 1;
        end if;
        if b_tx_ready = '1' then
            b_txr_n <= b_txr_n + 1;
        end if;
        a_rx_p := a_rx_valid;
        b_rx_p := b_rx_valid;
        a_tx_p := a_tx_ready;
        b_tx_p := b_tx_ready;
    end process pulse_proc;

    ------------------------------------------------------------------
    -- Behavioural slave: SCK and CS# edges straight from the pads
    ------------------------------------------------------------------

    mdl_proc: process(cs_n_in, sclk_in)
        variable cnt   : natural := 0;
        variable rxw   : word_t;
        variable txw   : word_t;
        variable t_edg : time := 0 ns;
        variable t_csr : time := 0 ns;
    begin
        if mdl_en = '1' then
            if falling_edge(cs_n_in) then
                assert now - t_csr >= CS_MIN * CLK_PERIOD and sclk_in = '0'
                    report "model: CS# high too short, or SCK high, as CS# falls" severity error;
                cnt   := 0;
                rxw   := (others => '0');
                txw   := mdl_resp;
                t_edg := now;
                mdl_miso <= txw(WIDTH-1) after MDL_DLY;
            elsif rising_edge(cs_n_in) then
                assert cnt = mdl_k and rxw = top_bits(mdl_mtx, mdl_k)
                    report "model: got " & integer'image(cnt) & " bits " & hex(rxw) & ", expected " &
                           integer'image(mdl_k) & " bits " & hex(top_bits(mdl_mtx, mdl_k)) severity error;
                t_csr    := now;
                mdl_miso <= 'Z';
                mdl_fcnt <= mdl_fcnt + 1;
            elsif rising_edge(sclk_in) and cs_n_in = '0' then
                assert now - t_edg = (mdl_div + 1) * CLK_PERIOD
                    report "model: SCK low for " & time'image(now - t_edg) severity error;
                assert mosi_in'last_event >= CLK_PERIOD
                    report "model: MOSI not stable for a cycle at the SCK rise" severity error;
                if cnt < WIDTH then
                    rxw := rxw(WIDTH-2 downto 0) & mosi_in;
                end if;
                cnt   := cnt + 1;
                t_edg := now;
            elsif falling_edge(sclk_in) and cs_n_in = '0' then
                assert now - t_edg = (mdl_div + 1) * CLK_PERIOD
                    report "model: SCK high for " & time'image(now - t_edg) severity error;
                t_edg := now;
                txw   := txw(WIDTH-2 downto 0) & '0';
                mdl_miso <= txw(WIDTH-1) after MDL_DLY;
            end if;
        end if;
    end process mdl_proc;

    -- role_req_i only changes while the port's tx_valid_i is low
    strap_rule_proc: process
        variable sa : std_logic := '1';
        variable sb : std_logic := '0';
    begin
        wait until rising_edge(clk);
        assert strap_a = sa or a_tx_valid = '0'
            report "TB: A's strap changed with tx_valid high" severity error;
        assert strap_b = sb or b_tx_valid = '0'
            report "TB: B's strap changed with tx_valid high" severity error;
        sa := strap_a;
        sb := strap_b;
    end process strap_rule_proc;

    watchdog_proc: process
    begin
        wait until sim_done = '1' for TIMEOUT;
        assert sim_done = '1' report "TB: timeout" severity failure;
        wait;
    end process watchdog_proc;

end architecture sim;
