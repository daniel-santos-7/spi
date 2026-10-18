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

The testbench connects two ports to one modelled bus. It runs random master/slave traffic in both directions, then both ports as slaves driven by a software host with frames of any length, and checks every word, bit count, timing rule and pad. It also covers role changes in the middle of a frame and on the edges where a write or a frame starts, a reset in the middle of a frame, underruns and words offered during a frame.

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
| `rx_valid_o`, `rx_data_o`, `rx_bits_o` | out | word received and its bit count, for one cycle |
| `rx_ready_i` | in | not used |

**Roles.** As master the port drives SCK, `CS#` and MOSI; as slave it drives MISO only while selected. A role change requested during a frame takes effect when the frame ends; `role_ack_o` = `role_req_i` means it has taken effect. In the master role a word offered wins over a switch back to slave, and a word still offered when the port becomes a master starts a frame: lower `tx_valid_i` before changing `role_req_i`. There is no arbitration between masters: raise `role_req_i` only when no other master on the bus can start a frame.

**Handshakes.** There is no transmit buffer: the word on `tx_*` is taken straight into the shift register as a frame starts, and `tx_ready_o` is high for that one cycle only (it is the start strobe). Hold `tx_valid_i`, `tx_data_i` and `tx_bits_i` until `tx_ready_o`, as in AXI; a word offered during a frame waits for the next start. There is no receive buffer either: a received word is on `rx_data_o`/`rx_bits_o` only in the cycle `rx_valid_o` is high (it is the stop strobe), and the client must take it then; `rx_ready_i` is not used. Keep `tx_valid_i` low during reset, as in AXI.

**Role change and pending words.** No word is ever pending inside the port: the word to send is taken only at a start, so it is up to the client to withdraw it, and a received word is reported as its frame ends. The role changes in the cycle after `role_req_i` changes. A slave frame that starts in the first cycle as a slave (a `CS#` fall right after the switch, which only a colliding master can cause) is still taken, with the reply offered then.

## Master

- A word offered while no frame runs starts a frame: it is taken (`tx_ready_o`) in that cycle, and `CS#` falls in the next one with the first bit on MOSI. MOSI changes on SCK falls, and MISO is sampled on SCK rises.
- The frame has *n* = `tx_bits_i` bits (0 or more than `WIDTH` means `WIDTH`), taken from `tx_data_i(WIDTH-1 downto WIDTH-n)`. `CS#` is low for 2·*n*·`SCK_DIV` cycles.
- The word received is delivered right-aligned in the first cycle with `CS#` high.
- `CS#` stays high for at least 2 cycles between frames (with the next word offered during the frame). A slave that needs a longer gap needs the client to wait before offering the next word.

## Slave

- Each frame is delivered as one word, right-aligned, with its bit count (0 to `WIDTH`), in the cycle the port sees `CS#` rise. A frame longer than `WIDTH` keeps its first `WIDTH` bits.
- The reply is taken as the port sees `CS#` fall, so offer it before that and hold it until `tx_ready_o`; a reply offered during a frame waits for the next one. After `WIDTH` bits, or when no reply was offered at the start (underrun), the slave sends zeros. Every frame takes the reply, an empty one too.
- If reset ends in the middle of a host frame, the port stays out of that frame and takes the next one.

Host timing, in system clock cycles (the port sees the pins 2 to 3 cycles late):

- SCK at least 5 cycles high and 5 low (SCK ≤ clk/10)
- at least 5 cycles from the `CS#` fall to the first SCK rise
- MISO is driven from 3–4 cycles after `CS#` falls until 3–4 cycles after it rises, so wait 4 cycles before selecting another slave that shares MISO
- the reply for a frame must be offered by the time the port sees `CS#` fall, so keep `CS#` high for a few cycles if the client waits for the previous word first
- `CS#` must toggle to delimit frames (a `CS#` tied low is not supported)

## License

MIT
