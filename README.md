# spi-dual-role

Dual-role SPI in VHDL-93: one set of pins and one shift core, used either as a master or as a slave.

- SPI mode 0, MSB first, one word of up to `WIDTH` bits per `CS#` frame
- Role chosen at run time by `role_req_i`, slave out of reset; the role only changes between frames
- One client interface for both roles: `tx_*` (ready/valid, ready a one-cycle pulse) to send, `rx_*` (a one-cycle valid pulse) to receive
- Single clock domain: the slave oversamples SCK, `CS#` and MOSI with the system clock
- No tri-state: every pin is split into `_i`, `_o` and `_oe`

## Structure

```
rtl/spi_pkg.vhdl      package: bits_for and the generic defaults
rtl/spi_sync.vhdl     two-flip-flop synchronisers for SCK, CS# and MOSI
rtl/spi_edge.vhdl     slave edge detection on the synchronised CS# and SCK
rtl/spi_ctrl.vhdl     control: role, FSM, master SCK/CS#, pin enables
rtl/spi_trx.vhdl      transceiver: shift registers, bit count, tx_ready and rx_valid pulses
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

Testbench generics: `SCK_DIV` (master SCK half-period for the main phases, at least 5 since the other port is a slave; default 5), `NUM_FRAMES` (60 per master/slave phase), `HOST_FRAMES` (30), `SEED` (1), `WIDTH` (32), `CNT_BITS` (7, so `WIDTH` = 64 fits).

The testbench connects two ports to one modelled bus. It runs random master/slave traffic in both directions, then both ports as slaves driven by a software host with frames of any length, and checks every word, bit count, timing rule and pad. It also covers role changes in the middle of a frame and on the edges where a word is offered or a frame starts, a reset in the middle of a frame, underruns, replies offered one cycle too late, and words offered during a frame. Last, one port masters a behavioural slave with dividers 0 to 3 (clk/2 to clk/8), checking every SCK phase, that MOSI is stable at each SCK rise, and the bits both ways. Throughout, it checks that `tx_ready_o` and `rx_valid_o` are one-cycle pulses and that the testbench itself only changes `role_req_i` with `tx_valid_i` low.

`make synth TOP=spi_port` gives 350 cells with the default generics (Yosys generic cells, `WIDTH` = 32, `DIV_BITS` = 8).

## Interface

| Generic | Default | Meaning |
|---------|---------|---------|
| `DIV_BITS` | 8 | Width of `sck_div_i` |
| `WIDTH` | 32 | Word size in bits (at least 2) |
| `CNT_BITS` | 6 | Width of the bit count; 2^`CNT_BITS` must exceed `WIDTH` |

| Port | Direction | Meaning |
|------|-----------|---------|
| `clk_i`, `rst_i` | in | system clock, synchronous active-high reset |
| `role_req_i` | in | requested role, 1 = master; synchronous to `clk_i` |
| `sck_div_i` | in | master SCK half-period minus one, in system cycles: SCK = clk / (2·(`sck_div_i`+1)); taken as each master frame starts |
| `role_ack_o` | out | role in effect |
| `sclk_*`, `cs_n_*`, `mosi_*`, `miso_*` | | pins, each as `_i`, `_o`, `_oe` |
| `tx_valid_i`, `tx_ready_o`, `tx_data_i`, `tx_bits_i` | | word to send; `tx_bits_i` is the master frame length |
| `rx_valid_o`, `rx_data_o`, `rx_bits_o` | out | word received (one-cycle pulse) and its bit count |

**Roles.** As master the port drives SCK, `CS#` and MOSI; as slave it drives MISO only while selected. A role change requested during a frame takes effect when the frame ends; `role_ack_o` = `role_req_i` means it has taken effect. There is no arbitration between masters: raise `role_req_i` only when no other master on the bus can start a frame.

**Handshakes.** There are no buffers: the word to send is taken as a frame starts. The client holds `tx_valid_i` and `tx_data_i`/`tx_bits_i` until `tx_ready_o`, a one-cycle pulse from a flip-flop. The word is loaded into the transmit shift register as the frame starts, and `tx_ready_o` pulses in the next cycle; if `tx_valid_i` is low as the frame starts, the frame sends zeros and `tx_ready_o` does not pulse (a word offered later waits for the next frame). A received word is reported by `rx_valid_o` high for one cycle (from a flip-flop) after its frame ends; there is no `rx_ready`, so the client takes it in that cycle. `rx_data_o`/`rx_bits_o` keep the word until the next frame starts. Keep `tx_valid_i` low during reset, as in AXI.

**Role change.** Change `role_req_i` only while `tx_valid_i` is low. An offered word must be held until `tx_ready_o`, and it is taken by the next frame of the role in effect, so a client with a word pending waits for `tx_ready_o` before changing the role. No word is held between frames, so a role change drops nothing.

## Master

- A word offered (`tx_valid_i`) to an idle master starts a frame in that cycle; in the next cycle `tx_ready_o` pulses and `CS#` falls with the first bit on MOSI. A word offered during a frame starts the next one once it ends. MOSI changes on SCK falls, and MISO is sampled on SCK rises.
- The frame has *n* = `tx_bits_i` bits (0 or more than `WIDTH` means `WIDTH`), taken from `tx_data_i(WIDTH-1 downto WIDTH-n)`. `CS#` is low for 2·*n*·(`sck_div_i`+1) cycles, with `sck_div_i` as the frame started; changing it during a frame only affects the next one.
- The word received is delivered right-aligned in the second cycle with `CS#` high.
- `CS#` stays high for at least 2 cycles between frames (with the next word offered during the frame). A slave that needs a longer gap needs the client to wait before offering the word.
- Between frames the master keeps driving MOSI, with the last frame's leftover bits; its value is meaningless while `CS#` is high.

## Slave

- Each frame is delivered as one word, right-aligned, with its bit count (0 to `WIDTH`), one cycle after the port sees `CS#` rise. A frame longer than `WIDTH` keeps its first `WIDTH` bits.
- The reply is offered on `tx_*` and held until `tx_ready_o` pulses, in the cycle after the port sees `CS#` fall; it goes out in that frame. After `WIDTH` bits, or when `tx_valid_i` is low as the port sees `CS#` fall (underrun, no `tx_ready_o` pulse), the slave sends zeros. Every frame takes a reply, an empty one too.
- If reset ends in the middle of a host frame, the port stays out of that frame and takes the next one.

Host timing, in system clock cycles (the port sees the pins 2 to 3 cycles late):

- SCK at least 5 cycles high and 5 low (SCK ≤ clk/10)
- at least 5 cycles from the `CS#` fall to the first SCK rise
- MISO is driven from 3–4 cycles after `CS#` falls until 3–4 cycles after it rises, so wait 4 cycles before selecting another slave that shares MISO
- the reply for a frame must be offered by the time the port sees `CS#` fall, so keep `CS#` high for a few cycles if the client waits for the previous word first
- `CS#` must toggle to delimit frames (a `CS#` tied low is not supported)

## Limitations

- SPI mode 0 and MSB first only.
- One word of up to `WIDTH` bits per `CS#` frame; no multi-word frames.
- As a slave, SCK ≤ clk/10 (the pins are sampled with the system clock).
- One `CS#`: as a master the port selects a single slave.
- No arbitration between masters. If another master starts a frame while the port is a master, the bus is in contention; a port that becomes a slave during such a frame sits it out.
- No receive backpressure: the client must take each word in its `rx_valid_o` cycle.
- No status flags: an underrun is only visible as a frame without a `tx_ready_o` pulse.

## License

MIT
