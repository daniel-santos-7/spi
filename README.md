# spi-dual-role

Dual-role SPI in VHDL-93: one set of pins and one shift core, used either as a master or as a slave.

- SPI mode 0, MSB first, one word each way per `CS#` frame
- One shift core (`spi_shift`) in `spi_port`, shared by both roles: the master and the slave only produce the timing strobes that move it
- One word size, `WIDTH` (default 64), for both roles
- Master: generates SCK and `CS#` and runs one frame of up to `WIDTH` bits (`tx_bits`) per `tx_valid`/`tx_ready` handshake
- Slave: follows an external SCK and `CS#`, frames of any length (words of up to `WIDTH` bits), oversampled by the system clock (no second clock domain)
- Role chosen by a strap input
- No tri-state: every pin is `_i`, `_o` and `_oe`

## Structure

```
rtl/spi_sync.vhdl     spi_port input synchronisers (two flip-flops each)
rtl/spi_shift.vhdl    shift core (one instance in spi_port)
rtl/spi_ctrl.vhdl     strobes for either role: master SCK/CS# FSM or slave edge detection
rtl/spi_port.vhdl     pins, role select and the shared shift core
tbs/tb_spi_port.vhdl  self-checking testbench: two ports on one bus
Makefile              GHDL analysis, simulation and Yosys synthesis
```

`make check` analyses and elaborates the design with GHDL (`TOP=spi_shift`, `spi_ctrl` or `spi_port`, default `spi_port`). `make synth` runs a generic Yosys synthesis of `TOP` with the GHDL plugin and prints the cell count.

`make sim` runs the testbench, which wires two `spi_port` instances to one modelled bus (pull resistors, no tri-state inside the design), runs random frames of random length (`tx_bits` from 0 to beyond `WIDTH`) with one as master and the other as slave, then swaps the roles, and finally straps both as slaves and drives the pins from a software host with frames of any length (empty, shorter than, equal to and longer than `WIDTH`), one of them with no reply written, and one word left unread while the next frame arrives. It checks the word and bit count the slave reports once per frame, that the buffer keeps an unread word and drops the next frame, the word the master receives, the reply bits the host samples, frame boundaries and length, SCK and `CS#` timing, back-to-back frames, pad contention, that the unused role in each port stays silent and that a master-strapped port takes no slave reply. It stops at the first error and prints `PASS` with coverage counts at the end. `make test` runs it with `WIDTH` = 16, 32 and 64. Generics go in `GENERICS`, e.g. `make sim GENERICS="-gSCK_DIV=7 -gSEED=3 -gNUM_FRAMES=200"` (`SCK_DIV` at least 5, because the slave needs SCK ≤ clk/10). `make wave` does the same and writes `build/tb_spi_port.ghw`.

## spi_port

| Generic | Default | Meaning |
|---------|---------|---------|
| `SCK_DIV` | 1 | Master SCK half-period in system cycles; SCK = clk / (2·`SCK_DIV`) |
| `WIDTH` | 64 | Word size and master frame length, in bits (at least 2) |
| `CNT_BITS` | 7 | Width of the bit count; 2^`CNT_BITS` must exceed `WIDTH` |

The input `dbg_i` picks the role:

| `dbg_i` | Role | SCK, `CS#`, MOSI | MISO |
|---------|------|------------------|------|
| 0 | master | driven (`_oe` = 1) | input |
| 1 | slave | inputs | driven while `CS#` is low, released otherwise |

`spi_port` holds a single `spi_shift`, and `dbg` selects what drives it: the master's strobes, `miso_i` as data in and `m_tx_data_i`, or the slave's strobes, the synchronised MOSI and `s_tx_data_i`. The core's `tx_valid` is the master's `start` in one role and the slave client's `s_tx_valid_i` in the other. The core's output bit goes to both `mosi_o` and `miso_o`; only the one whose `_oe` is set reaches the pin. The received word and count come out on both interfaces, and the core's `rx_valid` is routed to `m_rx_valid_o` or `s_rx_valid_o` by the role, as the role's `rx_ready` (`m_rx_ready_i` or `s_rx_ready_i`) is routed back to the core. The receive buffer is shared too: a word left unread when `dbg` changes comes out on the other role's interface.

Every asynchronous input goes through a two-flip-flop synchroniser, all in `spi_sync`: `dbg_i`, and SCK, `CS#` and MOSI on the way to the slave. The master needs none, since it only samples MISO at its own SCK edge. `dbg_o` gives the synchronised strap back to the client. It is a strap, not a run-time switch: change it only while the master is idle and no slave frame is in progress. While it is 1, the master's `tx_valid` is ignored, so no frame starts. While it is 0, the slave sees `CS#` as high, so master traffic never reaches it.

### Master interface (`m_`)

SCK idles low, `CS#` falls together with the first MOSI bit, MOSI changes on SCK falling edges, and MISO is sampled in the system cycle in which SCK rises. SCK, MOSI and `CS#` all come straight from flip-flops.

- **Start:** a frame starts when `m_tx_valid_i` and `m_tx_ready_o` are both high (a ready/valid handshake); `m_tx_data_i` and `m_tx_bits_i` are loaded in that cycle and the word goes out MSB first. `m_tx_ready_o` is high while the master is idle. Between two frames `CS#` stays high for at least 2 cycles (the cycle after the frame and the cycle in which the next word is accepted); a client that needs a longer gap, such as a flash's tSHSL, waits before raising `m_tx_valid_i`.
- **Frame:** *n* = `m_tx_bits_i` bits, with no gaps: `2·n·SCK_DIV` cycles with `CS#` low. A value of 0 or above `WIDTH` gives `WIDTH` bits. The word is left-aligned: the first *n* bits sent are `m_tx_data_i(WIDTH-1 downto WIDTH-n)`. `CS#` rises on the falling edge that ends the last bit.
- **Receive:** the frame's *n* bits go to the receive buffer, right-aligned on `m_rx_data_o` (the first bit in bit *n*-1, zeros above), and `m_rx_valid_o` rises in the second cycle with `CS#` high. It stays high, and the word held, until the client takes it with `m_rx_ready_i`; a client that keeps `m_rx_ready_i` high gets a one-cycle pulse. Since the client starts each frame itself, it can simply wait for the word before starting the next one.

The master knows nothing about commands. A flash read of one 32-bit word, for example, is a 64-bit frame of `03h`, the 24-bit address and 32 zeros; the data is in the low 32 bits of `m_rx_data_o`, the byte at the lowest address in `31 downto 24`.

### Slave interface (`s_`)

The slave runs entirely in the system clock domain, on the synchronised pins. SCK must stay at least 5 system cycles high and 5 low (SCK ≤ clk/10), which leaves time for MISO to update after a falling edge. MOSI is sampled on the SCK rising edge and MISO changes on the falling edge.

- **Receive:** when `CS#` rises, the word and the number of bits (unsigned) go to the receive buffer, on `s_rx_data_o` and `s_rx_bits_o`, and `s_rx_valid_o` rises one cycle later. It stays high, and the buffer holds the word, until the client takes it with `s_rx_ready_i`. The word is right-aligned: a frame of *n* < `WIDTH` bits leaves its bits in `n-1 downto 0` and zeros above. Reception stops at `WIDTH` bits: in a longer frame `s_rx_data_o` holds the first `WIDTH` bits, `s_rx_bits_o` reads `WIDTH`, and the rest is ignored. Every frame reports once, even one with no SCK edge, which comes out with `s_rx_bits_o` = 0. The host cannot be held back, so a frame that ends while the buffer is still full is dropped and the unread word is kept; a frame that ends in the cycle the client takes the word is stored. A client that keeps `s_rx_ready_i` high gets a one-cycle pulse per frame and never drops one.
- **Transmit:** the reply is written straight into the transmit shift register, with no buffer: `s_tx_data_i` is taken when `s_tx_valid_i` and `s_tx_ready_o` are both high, and `s_tx_ready_o` is the core's `tx_ready`: high between frames, from the cycle after the slave reports a frame up to the one in which it sees `CS#` fall (it is low while the port is strapped as master). A later write overwrites an earlier one, so the word that goes out is the last one taken before the slave sees `CS#` fall; a client may also hold `s_tx_valid_i` high and keep the reply up to date on `s_tx_data_i`. The word goes out MSB first, so the host gets the first *n* bits of the word in a frame of *n* bits, and zeros after the `WIDTH`-th bit. A frame with no write before it sends what the previous frame left in the register: zeros after a frame of `WIDTH` bits or more, the unsent bits of the previous reply after a shorter one.

The slave sees `CS#` through the synchroniser, so the edges are detected two to three cycles late. The host must keep at least 5 system cycles between `CS#` falling and the first SCK rise, so that the first bit is on MISO in time. The reply for the next frame must be written by the cycle in which the slave sees `CS#` fall: a client that writes it after `s_rx_valid_o` rises has one cycle when the host keeps `CS#` high for only two cycles, and the host's `CS#` high time beyond that is extra margin.

Neither side knows about commands: what the words mean, and whether a frame of the wrong length is used or dropped, is up to the client.

## spi_shift

A transmit and a receive shift register (`WIDTH` bits each) and a bit counter, moved by four one-cycle strobes, plus a ready/valid handshake that loads the transmit register and a receive buffer with its own ready/valid. It does not know which side of the link it is on.

- `start_i` (`CS#` falls): clears the receive register and the count.
- `tx_valid_i`/`tx_ready_o`: when both are high, `tx_data_i` is loaded into the transmit register and `tx_bits_i` into a length register (`tx_len`). `tx_ready_o` is high outside a frame (`ready_reg`, cleared by `start_i` and set again by `stop_i`), including the `start_i` cycle itself, so the master loads its word with `tx_valid_i` = `start_i`, and the slave's client can write, and overwrite, its reply any time between frames.
- `rise_i` (SCK rises): shifts `din_i` into the receive register and counts the bit, up to `WIDTH` bits; later bits are ignored.
- `fall_i` (SCK falls): shifts the transmit register, so `dout_o` (its MSB) shows the next bit, with zeros shifted in.
- Receive buffer (`rx_buf`, `rx_cnt`, `valid_reg`): while `valid_reg` is low, the buffer copies the receive register and the count on every cycle and `valid_reg` takes `stop_i`, so the buffer keeps the frame that just ended (`CS#` rises). While `valid_reg` is high, nothing changes until `rx_ready_i`, and then the same copy happens once, so a `stop_i` in that cycle is kept and `valid_reg` falls otherwise; a `stop_i` while `valid_reg` is high and `rx_ready_i` low drops the frame. `rx_valid_o` is `valid_reg`, with the word right-aligned on `rx_data_o` and the count on `rx_bits_o`; while it is low they follow the frame in progress and mean nothing.
- `tx_end_o`: high when the count equals `tx_len` or `WIDTH` (so a length of 0 or above `WIDTH` means `WIDTH`). Only the master uses it, to end its frame.

## spi_ctrl

Produces the four strobes for the role `dbg_i` selects. As master, an FSM (`IDLE`, `SCK_LO`, `SCK_HI`, `STOP`) generates SCK and `CS#` from `SCK_DIV`, times the strobes to its own clock (so no edge detection is involved) and ends the frame on the core's `tx_end` (the count reached `tx_bits`); its `stop` comes in the `STOP` cycle, the first one with `CS#` high, and `tx_valid_i` is ignored while `dbg_i` is 1. As slave, two registers detect the edges of the synchronised SCK and `CS#`.

## License

MIT
