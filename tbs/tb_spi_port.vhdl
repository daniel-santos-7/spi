----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI port testbench (two ports on one bus, master <-> slave)
-- 2026
----------------------------------------------------------------------
--
-- Two spi_port instances, A and B, share one set of pads modelled as
-- resolved signals with pull resistors (CS# up, SCK/MOSI/MISO down).
-- Phase 0 straps A as master and B as slave; phase 1 swaps the roles.
-- Every frame is one word of random data from the master, answered by
-- a random reply word from the slave, with a random tx_bits: mostly 1
-- to WIDTH bits, sometimes 0 or more than WIDTH, which must give WIDTH
-- bits. The master client sometimes starts the next frame as soon as
-- the last one is reported, otherwise it waits a random gap. The slave
-- client writes the reply of a frame once the previous frame has been
-- reported.
--
-- Phase 2 straps both ports as slaves and drives the pins from a
-- software host, with frames of any length (empty, shorter, equal and
-- longer than WIDTH). Each frame must be reported as one word: the
-- first WIDTH bits, with a count of WIDTH for a longer frame. The host
-- writes one reply word per frame, so any bit after the WIDTH-th must
-- be 0. One host frame, after a shorter one, goes out with no reply
-- written (underrun) and must send zeros, not what the shorter frame
-- left in the shift register; the reply written before the empty frame
-- must go out in the next one; a word offered during a frame must not
-- be taken (tx_ready stays low while CS# is low, high between frames).
-- Both slaves get the same reply, so MISO
-- contention is not checked in this phase (every reply bit the host
-- samples is). The host reads every word as it is reported, except
-- once: it leaves one word unread, sends the next frame and checks
-- that the buffer still holds the old word, so the new one is dropped.
--
-- Checks: every word and bit count the slave reports, the
-- words the master receives (the first tx_bits bits of the reply),
-- CS# high time, SCK phases, MOSI/MISO changing only while SCK is low,
-- frame length, pad contention, pin release, that the unused role
-- inside each port stays silent while its client drives junk, and that
-- a master-strapped port takes no slave reply.
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
    constant CS_MIN     : integer := 2;
    constant B2B_HI     : integer := 4;
    constant FRAME_CYC  : integer := 2 * WIDTH * SCK_DIV;
    constant HOST_MAX   : integer := 2 * WIDTH + 8;
    constant HOST_URUN  : integer := 5;
    constant HOST_HOLD  : integer := 6;
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
    signal junk_en   : std_logic := '0';
    signal swap      : std_logic := '0';
    signal strap_a   : std_logic := '0';
    signal strap_b   : std_logic := '1';

    -- software host (phase 2)
    signal host_en   : std_logic := '0';
    signal host_sclk : std_logic := '0';
    signal host_cs_n : std_logic := '1';
    signal host_mosi : std_logic := '0';
    signal host_resp : word_t    := (others => '0');
    signal host_wr   : std_logic := '0';
    signal host_rd   : std_logic := '0';
    signal hw_n      : natural   := 0;
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
    signal a_dbg_o      : std_logic;
    signal a_sclk_o     : std_logic;
    signal a_sclk_oe    : std_logic;
    signal a_cs_n_o     : std_logic;
    signal a_cs_n_oe    : std_logic;
    signal a_mosi_o     : std_logic;
    signal a_mosi_oe    : std_logic;
    signal a_miso_o     : std_logic;
    signal a_miso_oe    : std_logic;
    signal a_m_tx_valid : std_logic;
    signal a_m_tx_ready : std_logic;
    signal a_m_tx_data  : word_t;
    signal a_m_tx_bits  : bits_t;
    signal a_m_rx_ready : std_logic;
    signal a_m_rx_data  : word_t;
    signal a_m_rx_valid : std_logic;
    signal a_s_rx_ready : std_logic;
    signal a_s_rx_data  : word_t;
    signal a_s_rx_bits  : std_logic_vector(CNT_BITS-1 downto 0);
    signal a_s_rx_valid : std_logic;
    signal a_s_tx_valid : std_logic;
    signal a_s_tx_ready : std_logic;
    signal a_s_tx_data  : word_t;

    -- port B
    signal b_dbg_o      : std_logic;
    signal b_sclk_o     : std_logic;
    signal b_sclk_oe    : std_logic;
    signal b_cs_n_o     : std_logic;
    signal b_cs_n_oe    : std_logic;
    signal b_mosi_o     : std_logic;
    signal b_mosi_oe    : std_logic;
    signal b_miso_o     : std_logic;
    signal b_miso_oe    : std_logic;
    signal b_m_tx_valid : std_logic;
    signal b_m_tx_ready : std_logic;
    signal b_m_tx_data  : word_t;
    signal b_m_tx_bits  : bits_t;
    signal b_m_rx_ready : std_logic;
    signal b_m_rx_data  : word_t;
    signal b_m_rx_valid : std_logic;
    signal b_s_rx_ready : std_logic;
    signal b_s_rx_data  : word_t;
    signal b_s_rx_bits  : std_logic_vector(CNT_BITS-1 downto 0);
    signal b_s_rx_valid : std_logic;
    signal b_s_tx_valid : std_logic;
    signal b_s_tx_ready : std_logic;
    signal b_s_tx_data  : word_t;

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
    signal s_rx_fcnt  : natural := 0;
    signal s_fdone    : natural;

    -- test plan, per word and per frame
    signal plan_wcnt  : natural := 0;
    signal plan_mtx   : word_arr_t(0 to MAX_WORDS-1);
    signal plan_sresp : word_arr_t(0 to MAX_WORDS-1)       := (others => (others => '0'));
    signal plan_wbits : nat_arr_t(0 to MAX_WORDS-1)        := (others => WIDTH);
    signal plan_wlast : std_logic_vector(0 to MAX_WORDS-1) := (others => '0');
    signal plan_wfrm  : nat_arr_t(0 to MAX_WORDS-1)        := (others => 0);
    signal plan_flen  : nat_arr_t(0 to MAX_FRAMES-1)       := (others => WIDTH);
    signal plan_b2b   : std_logic_vector(0 to MAX_FRAMES-1) := (others => '0');

begin

    assert SCK_DIV >= 5 report "TB: the slave needs SCK <= clk/10, so SCK_DIV must be at least 5." severity failure;

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0' else '0';

    ------------------------------------------------------------------
    -- DUTs and bus
    ------------------------------------------------------------------

    tb_spi_port_a: entity work.spi_port generic map (
        SCK_DIV  => SCK_DIV,
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i        => clk,
        rst_i        => rst,
        dbg_i        => strap_a,
        dbg_o        => a_dbg_o,
        sclk_i       => sclk_in,
        sclk_o       => a_sclk_o,
        sclk_oe      => a_sclk_oe,
        cs_n_i       => cs_n_in,
        cs_n_o       => a_cs_n_o,
        cs_n_oe      => a_cs_n_oe,
        mosi_i       => mosi_in,
        mosi_o       => a_mosi_o,
        mosi_oe      => a_mosi_oe,
        miso_i       => miso_in,
        miso_o       => a_miso_o,
        miso_oe      => a_miso_oe,
        m_tx_valid_i => a_m_tx_valid,
        m_tx_ready_o => a_m_tx_ready,
        m_tx_data_i  => a_m_tx_data,
        m_tx_bits_i  => a_m_tx_bits,
        m_rx_ready_i => a_m_rx_ready,
        m_rx_data_o  => a_m_rx_data,
        m_rx_valid_o => a_m_rx_valid,
        s_tx_valid_i => a_s_tx_valid,
        s_tx_ready_o => a_s_tx_ready,
        s_tx_data_i  => a_s_tx_data,
        s_rx_ready_i => a_s_rx_ready,
        s_rx_data_o  => a_s_rx_data,
        s_rx_bits_o  => a_s_rx_bits,
        s_rx_valid_o => a_s_rx_valid
    );

    tb_spi_port_b: entity work.spi_port generic map (
        SCK_DIV  => SCK_DIV,
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i        => clk,
        rst_i        => rst,
        dbg_i        => strap_b,
        dbg_o        => b_dbg_o,
        sclk_i       => sclk_in,
        sclk_o       => b_sclk_o,
        sclk_oe      => b_sclk_oe,
        cs_n_i       => cs_n_in,
        cs_n_o       => b_cs_n_o,
        cs_n_oe      => b_cs_n_oe,
        mosi_i       => mosi_in,
        mosi_o       => b_mosi_o,
        mosi_oe      => b_mosi_oe,
        miso_i       => miso_in,
        miso_o       => b_miso_o,
        miso_oe      => b_miso_oe,
        m_tx_valid_i => b_m_tx_valid,
        m_tx_ready_o => b_m_tx_ready,
        m_tx_data_i  => b_m_tx_data,
        m_tx_bits_i  => b_m_tx_bits,
        m_rx_ready_i => b_m_rx_ready,
        m_rx_data_o  => b_m_rx_data,
        m_rx_valid_o => b_m_rx_valid,
        s_tx_valid_i => b_s_tx_valid,
        s_tx_ready_o => b_s_tx_ready,
        s_tx_data_i  => b_s_tx_data,
        s_rx_ready_i => b_s_rx_ready,
        s_rx_data_o  => b_s_rx_data,
        s_rx_bits_o  => b_s_rx_bits,
        s_rx_valid_o => b_s_rx_valid
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
    miso_pad <= b_miso_o when b_miso_oe = '1' else 'Z';
    miso_pad <= 'L';

    sclk_in <= to_x01(sclk_pad);
    cs_n_in <= to_x01(cs_n_pad);
    mosi_in <= to_x01(mosi_pad);
    miso_in <= to_x01(miso_pad);

    -- Clients go to the port in that role; the port in the other role
    -- gets junk (tx_valid held high) once junk_en is set. In phase 2 both
    -- slaves get the host's reply.
    a_m_tx_valid <= m_tx_valid   when swap = '0' else junk_en;
    a_m_tx_data  <= m_tx_data    when swap = '0' else (others => '1');
    a_m_tx_bits  <= m_tx_bits    when swap = '0' else (others => '1');
    b_m_tx_valid <= m_tx_valid   when swap = '1' else junk_en;
    b_m_tx_data  <= m_tx_data    when swap = '1' else (others => '1');
    b_m_tx_bits  <= m_tx_bits    when swap = '1' else (others => '1');
    m_tx_ready   <= a_m_tx_ready when swap = '0' else b_m_tx_ready;
    m_rx_data    <= a_m_rx_data  when swap = '0' else b_m_rx_data;
    m_rx_valid   <= a_m_rx_valid when swap = '0' else b_m_rx_valid;
    a_m_rx_ready <= '1'          when swap = '0' else junk_en;
    b_m_rx_ready <= '1'          when swap = '1' else junk_en;

    a_s_tx_valid <= host_wr   when host_en = '1' else s_tx_valid when swap = '1' else junk_en;
    a_s_tx_data  <= host_resp when host_en = '1' else s_tx_data  when swap = '1' else (others => '1');
    b_s_tx_valid <= host_wr   when host_en = '1' else s_tx_valid when swap = '0' else junk_en;
    b_s_tx_data  <= host_resp when host_en = '1' else s_tx_data  when swap = '0' else (others => '1');
    a_s_rx_ready <= host_rd   when host_en = '1' else '1'        when swap = '1' else junk_en;
    b_s_rx_ready <= host_rd   when host_en = '1' else '1'        when swap = '0' else junk_en;
    s_tx_ready   <= b_s_tx_ready when swap = '0' else a_s_tx_ready;
    s_rx_data    <= b_s_rx_data  when swap = '0' else a_s_rx_data;
    s_rx_bits    <= b_s_rx_bits  when swap = '0' else a_s_rx_bits;
    s_rx_valid   <= b_s_rx_valid when swap = '0' else a_s_rx_valid;

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
        variable mtx     : word_t;
        variable resp    : word_t;
        variable prev    : word_t := (others => '0');
        variable prev_n  : integer := -1;
        variable hbits   : std_logic_vector(HOST_MAX-1 downto 0);
        variable hrx     : std_logic_vector(HOST_MAX-1 downto 0);
        variable exp_rx  : word_t;
        variable len     : integer;
        variable ew      : integer;
        variable eb      : integer;
        variable hw0     : natural;
        variable sv_rx   : word_t;
        variable sv_k    : integer := 0;
        variable n_b2b   : natural := 0;
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
        junk_en   <= '1';
        iso_check <= '1';

        for ph in 0 to 1 loop
            if ph = 1 then
                -- strap A as slave too, check that nobody drives the bus,
                -- then strap B as master
                iso_check <= '0';
                junk_en   <= '0';
                strap_a   <= '1';
                cycles(10);
                assert sclk_pad = 'L' and cs_n_pad = 'H' and mosi_pad = 'L' and miso_pad = 'L'
                    report "TB: pins still driven with both ports strapped as slave" severity error;
                assert a_dbg_o = '1' and b_dbg_o = '1'
                    report "TB: dbg_o does not follow the strap" severity error;
                swap <= '1';
                cycles(1);
                strap_b <= '0';
                cycles(10);
                junk_en   <= '1';
                iso_check <= '1';
                report "TB: roles swapped, A is slave and B is master" severity note;
            end if;

            b2b := false;
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
                if len = 0 or len > WIDTH then
                    k       := WIDTH;
                    n_mclip := n_mclip + 1;
                else
                    k := len;
                end if;
                if k < WIDTH then
                    n_mshrt := n_mshrt + 1;
                end if;
                plan_wlast(word)  <= '1';
                plan_mtx(word)    <= mtx;
                plan_sresp(word)  <= resp;
                plan_wbits(word)  <= k;
                plan_wfrm(word)   <= frame;
                plan_flen(frame)  <= k;
                if b2b then
                    plan_b2b(frame) <= '1';
                end if;
                plan_wcnt <= word + 1;

                m_tx_data  <= mtx;
                m_tx_bits  <= std_logic_vector(to_unsigned(len, CNT_BITS));
                m_tx_valid <= '1';
                loop
                    wait until rising_edge(clk);
                    exit when m_tx_ready = '1';
                end loop;
                m_tx_valid <= '0';
                frame := frame + 1;
                word  := word + 1;

                loop
                    wait until rising_edge(clk);
                    exit when m_rx_fcnt = frame;
                end loop;
                rnd(0, 3, v);
                b2b := v = 0 and f < NUM_FRAMES;
                if b2b then
                    n_b2b := n_b2b + 1;
                else
                    rnd(1, 30, g);
                    cycles(g);
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
        junk_en   <= '0';
        strap_b   <= '1';
        cycles(10);
        host_rd <= '1';
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
            elsif f = HOST_HOLD then
                rnd(1, WIDTH, n);
            else
                rnd(1, HOST_MAX, n);
            end if;
            rnd_bits(hbits);
            assert a_s_tx_ready = '1' and b_s_tx_ready = '1'
                report "host: frame " & integer'image(f) & " slaves not ready between frames" severity error;
            if f = HOST_URUN then
                resp := (others => '0');
            elsif prev_n = 0 then
                resp := prev;
            else
                rnd_bits(resp);
                host_resp <= resp;
                host_wr   <= '1';
                cycles(1);
                host_wr   <= '0';
                cycles(1);
            end if;
            prev   := resp;
            prev_n := n;
            if f = HOST_HOLD then
                host_rd <= '0';
            end if;
            cycles(2);
            hw0 := hw_n;

            host_cs_n <= '0';
            cycles(SCK_DIV);
            for i in 0 to n-1 loop
                host_mosi <= hbits(HOST_MAX-1-i);
                if f = 2 and i = 1 then
                    host_resp <= not resp;
                    host_wr   <= '1';
                end if;
                cycles(SCK_DIV);
                host_sclk <= '1';
                hrx(HOST_MAX-1-i) := miso_in;
                assert a_s_tx_ready = '0' and b_s_tx_ready = '0'
                    report "host: frame " & integer'image(f) & " tx_ready high during the frame" severity error;
                cycles(SCK_DIV);
                host_sclk <= '0';
            end loop;
            cycles(SCK_DIV);
            host_wr   <= '0';
            host_cs_n <= '1';
            host_mosi <= '0';

            for i in 0 to n-1 loop
                if i < WIDTH then
                    assert hrx(HOST_MAX-1-i) = resp(WIDTH-1-i)
                        report "host: frame " & integer'image(f) & " reply bit " & integer'image(i) & " wrong" severity error;
                else
                    assert hrx(HOST_MAX-1-i) = '0'
                        report "host: frame " & integer'image(f) & " reply bit " & integer'image(i) & " is not 0" severity error;
                end if;
            end loop;
            cycles(10);

            ew := 1;
            if f = HOST_HOLD then
                exp_rx := (others => '0');
                for i in 0 to n-1 loop
                    exp_rx(n-1-i) := hbits(HOST_MAX-1-i);
                end loop;
                assert hw_n = hw0 and a_s_rx_valid = '1' and to_integer(unsigned(a_s_rx_bits)) = n and a_s_rx_data = exp_rx
                    report "host: frame " & integer'image(f) & " not held in the buffer" severity error;
                sv_rx := exp_rx;
                sv_k  := n;
            elsif f = HOST_HOLD + 1 then
                assert hw_n = hw0 and a_s_rx_valid = '1' and to_integer(unsigned(a_s_rx_bits)) = sv_k and a_s_rx_data = sv_rx
                    report "host: frame " & integer'image(f) & " overwrote an unread word" severity error;
                host_rd <= '1';
                cycles(3);
                assert hw_n = hw0 + 1 and hw_data(hw0) = sv_rx and hw_bits(hw0) = sv_k
                    report "host: frame " & integer'image(f) & " held word not read back alone" severity error;
            else
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
            end if;

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

        assert n_b2b > 0 and n_mshrt > 0 and n_mclip > 0
            report "TB: coverage hole (back-to-back, shorter or clipped master frame)" severity error;
        report "TB: PASS - " & integer'image(frame) & " master frames, " & integer'image(word) & " words of " &
               integer'image(WIDTH) & " bits (" & integer'image(n_b2b) & " back-to-back, " &
               integer'image(n_mshrt) & " shorter, " & integer'image(n_mclip) &
               " with tx_bits 0 or over WIDTH), " & integer'image(HOST_FRAMES) & " host frames (" &
               integer'image(n_empty) & " empty, " & integer'image(n_short) & " shorter, " &
               integer'image(n_exact) & " exact, " & integer'image(n_long) & " longer)"
            severity note;
        sim_done <= '1';
        wait;
    end process stim_proc;

    ------------------------------------------------------------------
    -- Slave client: writes each reply once, checks each received word
    ------------------------------------------------------------------

    s_fdone    <= s_rx_fcnt + 1 when s_rx_valid = '1' and plan_wlast(s_rx_wcnt) = '1' else s_rx_fcnt;
    s_tx_data  <= plan_sresp(s_tx_cnt);
    s_tx_valid <= '1' when host_en = '0' and s_tx_cnt < plan_wcnt and
                           (s_tx_cnt = 0 or plan_wlast(s_tx_cnt-1) = '0' or s_fdone > plan_wfrm(s_tx_cnt-1)) else '0';

    slave_tx_proc: process
    begin
        wait until rising_edge(clk);
        if s_tx_valid = '1' and s_tx_ready = '1' then
            s_tx_cnt <= s_tx_cnt + 1;
        end if;
    end process slave_tx_proc;

    slave_rx_proc: process
        variable i : natural := 0;
    begin
        wait until rising_edge(clk);
        if chk_on = '1' and host_en = '0' and s_rx_valid = '1' then
            assert i < plan_wcnt
                report "slave: unexpected word " & hex(s_rx_data) severity error;
            assert to_integer(unsigned(s_rx_bits)) = plan_wbits(i)
                report "slave: word " & integer'image(i) & " reported " & integer'image(to_integer(unsigned(s_rx_bits))) &
                       " bits, expected " & integer'image(plan_wbits(i)) severity error;
            assert s_rx_data = top_bits(plan_mtx(i), plan_wbits(i))
                report "slave: word " & integer'image(i) & " is " & hex(s_rx_data) &
                       ", expected " & hex(top_bits(plan_mtx(i), plan_wbits(i))) severity error;
            if plan_wlast(i) = '1' then
                s_rx_fcnt <= s_rx_fcnt + 1;
            end if;
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
        if host_en = '1' and host_rd = '1' and a_s_rx_valid = '1' then
            assert b_s_rx_valid = '1' and b_s_rx_data = a_s_rx_data and b_s_rx_bits = a_s_rx_bits
                report "host: the two slaves report different words" severity error;
            hw_data(hw_n) <= a_s_rx_data;
            hw_bits(hw_n) <= to_integer(unsigned(a_s_rx_bits));
            hw_n <= hw_n + 1;
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
        if chk_on = '1' and m_rx_valid = '1' then
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
    begin
        wait until rising_edge(clk) and chk_on = '1';
        sclk_p := sclk_in;
        cs_p   := cs_n_in;
        mosi_p := mosi_in;
        miso_p := miso_in;
        loop
            wait until rising_edge(clk);

            assert sclk_in /= 'X' and cs_n_in /= 'X' and mosi_in /= 'X' and (miso_in /= 'X' or host_en = '1')
                report "bus: contention on a pad" severity error;

            if cs_n_in = '1' then
                assert sclk_in = '0'
                    report "bus: SCK high while CS# is high" severity error;
                assert miso_pad = 'L'
                    report "bus: MISO driven while CS# is high" severity error;
            end if;

            if host_en = '0' then
                -- frame boundaries
                if cs_p = '1' and cs_n_in = '0' then
                    assert sclk_in = '0'
                        report "bus: SCK high when CS# falls" severity error;
                    assert hi_cnt >= CS_MIN
                        report "bus: CS# high for " & integer'image(hi_cnt) & " cycles before frame " &
                               integer'image(frame) severity error;
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

            -- pins driven by the right port, unused roles silent
            if iso_check = '1' then
                assert (sclk_pad = '0' or sclk_pad = '1') and (cs_n_pad = '0' or cs_n_pad = '1') and
                       (mosi_pad = '0' or mosi_pad = '1')
                    report "bus: master pins not driven" severity error;
                if cs_n_in = '0' then
                    assert miso_pad = '0' or miso_pad = '1'
                        report "bus: MISO not driven by the slave while CS# is low" severity error;
                end if;
                if swap = '0' then
                    assert a_dbg_o = '0' and b_dbg_o = '1'
                        report "bus: dbg_o does not follow the strap" severity error;
                    assert a_s_rx_valid = '0' and a_s_tx_ready = '0'
                        report "bus: slave inside the master-strapped port A is active" severity error;
                    assert b_m_rx_valid = '0'
                        report "bus: master inside the slave-strapped port B ran a frame" severity error;
                else
                    assert a_dbg_o = '1' and b_dbg_o = '0'
                        report "bus: dbg_o does not follow the strap" severity error;
                    assert b_s_rx_valid = '0' and b_s_tx_ready = '0'
                        report "bus: slave inside the master-strapped port B is active" severity error;
                    assert a_m_rx_valid = '0'
                        report "bus: master inside the slave-strapped port A ran a frame" severity error;
                end if;
            end if;

            sclk_p := sclk_in;
            cs_p   := cs_n_in;
            mosi_p := mosi_in;
            miso_p := miso_in;
        end loop;
    end process bus_mon_proc;

    watchdog_proc: process
    begin
        wait until sim_done = '1' for TIMEOUT;
        assert sim_done = '1' report "TB: timeout" severity failure;
        wait;
    end process watchdog_proc;

end architecture sim;
