# spi-dual-role

Dual-role SPI in VHDL-93: one set of pins and one shift core, used either as a master or as a slave.

- SPI mode 0, MSB first, one word of up to `WIDTH` bits per `CS#` frame
- Role picked frame by frame: a master for the frames its client starts, a slave for the frames another master starts
- Ready/valid handshakes for each role: `m_tx_*` starts a master frame and `m_rx_*` returns its word; `s_tx_*` sets the slave reply and `s_rx_*` returns the word of each slave frame; both share one receive buffer
- Single clock domain: the slave oversamples SCK, `CS#` and MOSI with the system clock
- No tri-state: every pin is split into `_i`, `_o` and `_oe`

## Structure

```
rtl/spi_sync.vhdl     two-flip-flop synchronisers for SCK, CS# and MOSI
rtl/spi_ctrl.vhdl     control: FSM and role of each frame, master SCK/CS#, pin enables, TX handshakes
rtl/spi_trx.vhdl      transceiver: shift registers, slave reply, bit count, frame length
rtl/spi_rx_buf.vhdl   one-word receive buffer shared by both roles, a ready/valid pair per role
rtl/spi_port.vhdl     structural top
tbs/tb_spi_port.vhdl  self-checking testbench: two ports on one bus
```

## Build and test

Requires GHDL and Yosys with the GHDL plugin.

```sh
make check               # analyse and elaborate (TOP=spi_port by default)
make synth TOP=spi_ctrl  # Yosys synthesis, prints the cell count
make sim                 # run the testbench, ends with "TB: PASS"
make test                # make sim with WIDTH = 16, 32 and 64
make wave                # make sim plus build/tb_spi_port.ghw
make sim GENERICS="-gSCK_DIV=7 -gSEED=3 -gNUM_FRAMES=200"
```

The testbench connects two ports to one modelled bus. It runs random master/slave traffic with A as master, then B, then a master picked at random for each frame, then both ports as slaves driven by a software host with frames of any length, and checks every word, bit count, timing rule and pad. It also covers a master write held while the bus is busy, a master word left unread while the port is the slave of the next frame (its word is dropped), slave replies kept through the port's own master frames, a reset in the middle of a frame, underruns, refused writes and a full receive buffer.

## Interface

| Generic | Default | Meaning |
|---------|---------|---------|
| `SCK_DIV` | 1 | Master SCK half-period in system cycles: SCK = clk / (2·`SCK_DIV`) |
| `WIDTH` | 32 | Word size in bits (at least 2) |
| `CNT_BITS` | 6 | Width of the bit count; 2^`CNT_BITS` must exceed `WIDTH` |

| Port | Direction | Meaning |
|------|-----------|---------|
| `clk_i`, `rst_i` | in | system clock, synchronous active-high reset |
| `sclk_*`, `cs_n_*`, `mosi_*`, `miso_*` | | pins, each as `_i`, `_o`, `_oe` |
| `m_tx_valid_i`, `m_tx_ready_o`, `m_tx_data_i`, `m_tx_bits_i` | | master frame to send; `m_tx_bits_i` is its length |
| `s_tx_valid_i`, `s_tx_ready_o`, `s_tx_data_i` | | slave reply for the next frame another master starts |
| `m_rx_valid_o`, `m_rx_ready_i`, `m_rx_data_o` | | word received in a master frame (its length is the one written) |
| `s_rx_valid_o`, `s_rx_ready_i`, `s_rx_data_o`, `s_rx_bits_o` | | word received in a slave frame and its bit count |

**Roles.** There is no role input. Between frames the port drives nothing but listens; a master write taken while the bus is free makes it the master of the next frame (it drives SCK, `CS#` and MOSI until the frame ends), and a `CS#` fall from another master makes it a slave (it drives MISO only while selected). The port only starts a frame when it has seen `CS#` high, but it sees the pins 2 to 3 cycles late and takes one more cycle to drop `m_tx_ready_o`, so two masters that start within 3 to 4 cycles of each other collide: there is no arbitration, so the system must keep masters from starting at the same time.

**Bus.** The port releases every pin it does not need: SCK, `CS#` and MOSI outside its own master frames, MISO outside its slave frames, and all of them during reset. The bus needs a pull-up on `CS#` and a pull-down on SCK, which hold it idle (mode 0) in reset and between frames; without the pull-up a floating `CS#` can keep the port from ever becoming a master, start spurious slave frames, and select other slaves on the bus. Pull-downs on MOSI and MISO keep them defined while nobody drives them.

**Handshakes.** A master write (`m_tx_valid_i` and `m_tx_ready_o`) starts a frame in the same cycle. `m_tx_ready_o` is high only between frames with the bus free: low during any frame of the port, out of reset until `CS#` is seen high, and while another master holds `CS#` low (from 3 to 4 cycles after the fall). A slave reply (`s_tx_valid_i` and `s_tx_ready_o`) goes into a reply register of its own: `s_tx_ready_o` is high under the same condition as `m_tx_ready_o` (no frame running, the bus free), so a reply is written between frames; it then waits in that register through any master frames of the port until the next slave frame, and a second reply before that frame replaces the first. A ready only drops when a write is taken or a frame starts (a master write drops both). A received word goes into one buffer for both roles and comes out on the data and bits of both channels (the same buffer drives them) with the valid of the role the port had in that frame (`m_rx_valid_o` only after a master frame, `s_rx_valid_o` only after a slave frame; never both), and stays there until taken with the ready of that role (the other ready is ignored). A word that arrives while the buffer is full is dropped, whichever role it is from: a word left unread on one channel makes the port lose the next word of either role. Keep the valids low during reset, as in AXI.

## Master

- A write starts a frame in the same cycle. `CS#` falls with the first MOSI bit, MOSI changes on SCK falls, and MISO is sampled on SCK rises.
- The frame has *n* = `m_tx_bits_i` bits (0 or more than `WIDTH` means `WIDTH`), taken from `m_tx_data_i(WIDTH-1 downto WIDTH-n)`. `CS#` is low for 2·*n*·`SCK_DIV` cycles.
- The *n* bits received are delivered right-aligned on `m_rx_*` in the first cycle with `CS#` high. There is no bit count: it is always *n*.
- `CS#` stays high for at least 4 cycles between frames, whichever port was the master of the previous one. A slave that needs a longer gap needs the client to wait before writing.

## Slave

- Each frame is delivered on `s_rx_*` as one word, right-aligned, with its bit count (0 to `WIDTH`), one cycle after the port sees `CS#` rise. A frame longer than `WIDTH` keeps its first `WIDTH` bits.
- The reply goes out in the next slave frame; master frames of the port in between leave it in place. After `WIDTH` bits, or when no reply was written since the last slave frame with bits (underrun), the slave sends zeros. A reply written before an empty frame stays for the next one.
- If reset ends in the middle of a host frame, the port stays out of that frame and takes the next one; it takes no master write until `CS#` rises.

Host timing, in system clock cycles (the port sees the pins 2 to 3 cycles late):

- SCK at least 5 cycles high and 5 low (SCK ≤ clk/10)
- at least 5 cycles from the `CS#` fall to the first SCK rise
- MISO is driven from 3–4 cycles after `CS#` falls until 3–4 cycles after it rises, so wait 4 cycles before selecting another slave that shares MISO
- the reply for a frame must be written by the time the port sees `CS#` fall (a reply taken in that very cycle still goes out in that frame), so keep `CS#` high for a few cycles if the client waits for the previous word first
- `CS#` must toggle to delimit frames (a `CS#` tied low is not supported)

## License

MIT
