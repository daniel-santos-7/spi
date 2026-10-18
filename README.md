# spi-dual-role

Dual-role SPI in VHDL-93: one set of pins and one shift core, used either as a master or as a slave.

- SPI mode 0, MSB first, one word of up to `WIDTH` bits per `CS#` frame
- Role chosen at run time by `role_req_i`, slave out of reset; the role only changes between frames
- One client interface for both roles, with ready/valid handshakes: `tx_*` to send, `rx_*` to receive
- Single clock domain: the slave oversamples SCK, `CS#` and MOSI with the system clock
- No tri-state: every pin is split into `_i`, `_o` and `_oe`

## Structure

```
rtl/spi_pkg.vhdl      package: bits_for and the generic defaults
rtl/spi_sync.vhdl     two-flip-flop synchronisers for SCK, CS# and MOSI
rtl/spi_edge.vhdl     slave edge detection on the synchronised CS# and SCK
rtl/spi_ctrl.vhdl     control: role, FSM, master SCK/CS#, pin enables
rtl/spi_buf.vhdl      one-word ready/valid buffer, zeros when empty (one for TX, one for RX)
rtl/spi_trx.vhdl      transceiver: transmit and receive shift registers, bit count
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

The testbench connects two ports to one modelled bus. It runs random master/slave traffic in both directions, then both ports as slaves driven by a software host with frames of any length, and checks every word, bit count, timing rule and pad. It also covers role changes in the middle of a frame and on the edges where a write or a frame starts, the words dropped by a role change, a reset in the middle of a frame, underruns, words written during a frame and a full receive buffer.

## Interface

| Generic | Default | Meaning |
|---------|---------|---------|
| `SCK_DIV` | 1 | Master SCK half-period in system cycles: SCK = clk / (2·`SCK_DIV`) |
| `WIDTH` | 32 | Word size in bits (at least 2) |
| `CNT_BITS` | 6 | Width of the bit count; 2^`CNT_BITS` must exceed `WIDTH` |

| Port | Direction | Meaning |
|------|-----------|---------|
| `clk_i`, `rst_i` | in | system clock, synchronous active-high reset |
| `role_req_i` | in | requested role, 1 = master; synchronous to `clk_i` |
| `role_ack_o` | out | role in effect |
| `sclk_*`, `cs_n_*`, `mosi_*`, `miso_*` | | pins, each as `_i`, `_o`, `_oe` |
| `tx_valid_i`, `tx_ready_o`, `tx_data_i`, `tx_bits_i` | | word to send; `tx_bits_i` is the master frame length |
| `rx_valid_o`, `rx_ready_i`, `rx_data_o`, `rx_bits_o` | | word received and its bit count |

**Roles.** As master the port drives SCK, `CS#` and MOSI; as slave it drives MISO only while selected. A role change requested during a frame takes effect when the frame ends; `role_ack_o` = `role_req_i` means it has taken effect. In the master role a buffered word wins over a switch back to slave, so stop the master writes before lowering `role_req_i`. There is no arbitration between masters: raise `role_req_i` only when no other master on the bus can start a frame.

**Handshakes.** A write (`tx_valid_i` and `tx_ready_o`) goes into a one-word transmit buffer, which a frame empties as it starts (the word moves to the shift register). `tx_ready_o` is high while the buffer is empty, and in the cycle a frame starts; a write made during a frame waits in the buffer for the next one. A received word stays on `rx_*` until taken with `rx_ready_i`; one that arrives while the buffer is full is dropped. Keep `tx_valid_i` low during reset, as in AXI.

**Role change and pending words.** A role change drops the words still pending in both buffers: a word not yet sent, and an unread received word, of either role. Read the last word before changing the role. A word belongs to the role `role_ack_o` shows in the cycle it is taken: the drop happens in the first cycle with the new `role_ack_o`, so a write taken in the cycle the change of `role_req_i` is seen (`role_ack_o` still old) is dropped too, and one taken from that first cycle on stays. A slave frame that starts in that first cycle (a `CS#` fall right after the switch, which only a colliding master can cause) is still taken, and sends the word written in the cycle of the switch, if any, since it reads the buffer before the drop.

## Master

- A write starts a frame in the next cycle, and `CS#` falls one cycle later with the first bit on MOSI. MOSI changes on SCK falls, and MISO is sampled on SCK rises.
- The frame has *n* = `tx_bits_i` bits (0 or more than `WIDTH` means `WIDTH`), taken from `tx_data_i(WIDTH-1 downto WIDTH-n)`. `CS#` is low for 2·*n*·`SCK_DIV` cycles.
- The word received is delivered right-aligned in the second cycle with `CS#` high.
- `CS#` stays high for at least 2 cycles between frames (with the next word written during the frame). A slave that needs a longer gap needs the client to wait before writing.

## Slave

- Each frame is delivered as one word, right-aligned, with its bit count (0 to `WIDTH`), one cycle after the port sees `CS#` rise. A frame longer than `WIDTH` keeps its first `WIDTH` bits.
- The reply can be written between frames and goes out in the next frame, which empties the buffer as the port sees `CS#` fall; a reply written during a frame waits for the next one. After `WIDTH` bits, or when the buffer was empty as the frame started (underrun), the slave sends zeros. Every frame uses the reply, an empty one too.
- If reset ends in the middle of a host frame, the port stays out of that frame and takes the next one.

Host timing, in system clock cycles (the port sees the pins 2 to 3 cycles late):

- SCK at least 5 cycles high and 5 low (SCK ≤ clk/10)
- at least 5 cycles from the `CS#` fall to the first SCK rise
- MISO is driven from 3–4 cycles after `CS#` falls until 3–4 cycles after it rises, so wait 4 cycles before selecting another slave that shares MISO
- the reply for a frame must be in the buffer by the time the port sees `CS#` fall, so keep `CS#` high for a few cycles if the client waits for the previous word first
- `CS#` must toggle to delimit frames (a `CS#` tied low is not supported)

## License

MIT
