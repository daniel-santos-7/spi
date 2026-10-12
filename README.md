# spi-dual-role

Dual-role SPI in VHDL-93: one set of pins and one shift core, used either as a master or as a slave.

- SPI mode 0, MSB first, one word of up to `WIDTH` bits per `CS#` frame
- One shift core (`spi_shift`) in `spi_port`, shared by both roles: the master and the slave only produce the timing strobes that move it
- One word size, `WIDTH` (default 32), for both roles; one client interface for both roles: the word to send goes straight into the shift register (`tx_*`) and a one-word receive buffer delivers the word received (`rx_*`), both behind a ready/valid handshake
- Master: generates SCK and `CS#`; each write is one frame of 1 to `WIDTH` bits (`tx_bits`)
- Slave: follows an external SCK and `CS#` and reports one word per frame, with its bit count; a frame longer than `WIDTH` bits keeps its first `WIDTH` bits. Oversampled by the system clock (no second clock domain)
- Role chosen by a strap input
- No tri-state: every pin is `_i`, `_o` and `_oe`

## Structure

```
rtl/spi_sync.vhdl     spi_port input synchronisers (two flip-flops each)
rtl/spi_shift.vhdl    shift core (one instance in spi_port)
rtl/spi_ctrl.vhdl     strobes for either role: master SCK/CS# FSM or slave edge detection
rtl/spi_port.vhdl     pins, role select, the receive buffer and the shared shift core
tbs/tb_spi_port.vhdl  self-checking testbench: two ports on one bus
Makefile              GHDL analysis, simulation and Yosys synthesis
```

`make check` analyses and elaborates the design with GHDL (`TOP=spi_shift`, `spi_ctrl` or `spi_port`, default `spi_port`). `make synth` runs a generic Yosys synthesis of `TOP` with the GHDL plugin and prints the cell count.

`make sim` runs the testbench, which wires two `spi_port` instances to one modelled bus (pull resistors, no tri-state inside the design), runs random frames with one as master and the other as slave (`tx_bits` from 0 to beyond `WIDTH`), then swaps the roles, and finally straps both as slaves and drives the pins from a software host with frames of any length (empty, shorter than `WIDTH`, exactly `WIDTH` and longer, up to `2·WIDTH+8` bits). In that last phase one frame goes out with no reply written right after a shorter frame, a reply written before an empty frame must go out in the next one, a word offered during a frame must not be taken, and one word is left unread while the next frame arrives. It checks every word both sides report, and the bit count the slave reports (the first `WIDTH` bits and a count of `WIDTH` for a longer frame), that the buffer keeps an unread word and drops what follows, that `tx_ready` stays low during a frame, that the underrun frame sends zeros, the reply bits the host samples (zeros after the `WIDTH`-th), frame boundaries and length, SCK and `CS#` timing, back-to-back frames, pad contention, that a slave port ignores `tx_bits` (driven all ones) and that the master inside it stays idle. It stops at the first error and prints `PASS` with coverage counts at the end. `make test` runs it with `WIDTH` = 16, 32 and 64. Generics go in `GENERICS`, e.g. `make sim GENERICS="-gSCK_DIV=7 -gSEED=3 -gNUM_FRAMES=200"` (`SCK_DIV` at least 5, because the slave needs SCK ≤ clk/10). `make wave` does the same and writes `build/tb_spi_port.ghw`.

## spi_port

| Generic | Default | Meaning |
|---------|---------|---------|
| `SCK_DIV` | 1 | Master SCK half-period in system cycles; SCK = clk / (2·`SCK_DIV`) |
| `WIDTH` | 32 | Word size, in bits (at least 2) |
| `CNT_BITS` | 6 | Width of the bit count; 2^`CNT_BITS` must exceed `WIDTH` |

The input `dbg_i` picks the role:

| `dbg_i` | Role | SCK, `CS#`, MOSI | MISO |
|---------|------|------------------|------|
| 0 | master | driven (`_oe` = 1) | input |
| 1 | slave | inputs | driven while `CS#` is low, released otherwise |

`spi_port` holds a single `spi_shift` and, in `rx_buf_proc`, a single receive buffer with the word and the bit count, behind one client interface shared by both roles: transmit (`tx_valid_i`, `tx_ready_o`, `tx_data_i`, `tx_bits_i`) and receive (`rx_valid_o`, `rx_ready_i`, `rx_data_o`, `rx_bits_o`). `dbg` selects the strobes that drive the core (the master's or the slave's) and its data in (`miso_i` or the synchronised MOSI). `tx_bits_i` only matters as master; a slave always sends up to `WIDTH` bits. The core's output bit goes to both `mosi_o` and `miso_o`; only the one whose `_oe` is set reaches the pin. A word left in the receive buffer when `dbg` changes is still delivered on `rx_*`. A transmit word written and not yet sent when `dbg` changes goes out in the other role's next frame.

The receive buffer holds one word, with a ready/valid handshake on the output. While it is empty (`valid` low), it copies the core's word on every cycle and `valid` takes the core's `rx_valid`, so it keeps the word offered in the cycle it fills. While it is full, nothing changes until the client's `rx_ready`, and then the same copy happens once, so a word offered in that cycle is kept and `valid` falls otherwise. There is no ready towards the core: it cannot be held back, so a word that arrives while the buffer is full and `rx_ready` is low is dropped. The outputs follow the core while `rx_valid` is low and mean nothing then.

Every asynchronous input goes through a two-flip-flop synchroniser, all in `spi_sync`: `dbg_i`, and SCK, `CS#` and MOSI on the way to the slave. The master needs none, since it only samples MISO at its own SCK edge. `dbg_o` gives the synchronised strap back to the client. It is a strap, not a run-time switch: change it only while the master is idle, no slave frame is in progress and no slave reply is written but not yet sent. While it is 1, `tx_valid_i` only loads the slave's reply and never starts a master frame. While it is 0, the slave sees `CS#` as high, so master traffic never reaches it.

### Master role (`dbg_i` = 0)

SCK idles low, `CS#` falls together with the first MOSI bit, MOSI changes on SCK falling edges, and MISO is sampled in the system cycle in which SCK rises. SCK, MOSI and `CS#` all come straight from flip-flops.

- **Transmit:** `tx_data_i` goes straight into the shift register, and `tx_bits_i` into the master control, when `tx_valid_i` and `tx_ready_o` are both high, and that write starts a frame. `tx_ready_o` is high while the master is idle and low during a frame.
- **Start:** an idle master starts a frame in the cycle a word is written, so between two frames `CS#` stays high for at least 2 cycles (the cycle after the frame, and the cycle in which the next word is written and the frame starts); a client that needs a longer gap, such as a flash's tSHSL, waits before writing.
- **Word length:** `tx_bits_i` is the number of bits of the frame, *n*; 0 or above `WIDTH` means `WIDTH`. The word is left-aligned: the *n* bits sent are `tx_data_i(WIDTH-1 downto WIDTH-n)`. `CS#` is low for `2·n·SCK_DIV` cycles and rises on the falling edge that ends the last bit.
- **Receive:** the word received in each frame goes to the receive buffer, right-aligned on `rx_data_o` (the first bit in bit *n*-1, zeros above) with its count on `rx_bits_o`, in the second cycle with `CS#` high. `rx_valid_o` stays high, and the word held, until the client takes it with `rx_ready_i`; a word that arrives while the buffer is full is dropped. A client that keeps `rx_ready_i` high gets a one-cycle pulse per frame and never drops one.

The master knows nothing about commands. A transaction that needs more than `WIDTH` bits under one `CS#` needs a larger `WIDTH`: a flash read of one 32-bit word, `03h` with the 24-bit address and then 32 bits of data, is one 64-bit frame with `WIDTH` = 64, and the data is in `31 downto 0` of the word received, the byte at the lowest address in `31 downto 24`.

### Slave role (`dbg_i` = 1)

The slave runs entirely in the system clock domain, on the synchronised pins. SCK must stay at least 5 system cycles high and 5 low (SCK ≤ clk/10), which leaves time for MISO to update after a falling edge. MOSI is sampled on the SCK rising edge and MISO changes on the falling edge.

- **Receive:** each frame is reported as one word, one cycle after the slave sees `CS#` rise, on `rx_data_o`, with the number of bits (unsigned) on `rx_bits_o`, from 0 (a frame with no SCK edge) to `WIDTH`. The word is right-aligned: a word of *n* < `WIDTH` bits has them in `n-1 downto 0` and zeros above. If the host sends more than `WIDTH` bits, the word holds the first `WIDTH` and the count is `WIDTH`; the bits after them are dropped. `rx_valid_o` stays high, and the buffer holds the word, until the client takes it with `rx_ready_i`. The host cannot be held back, so a word that arrives while the buffer is still full is dropped and the unread word is kept; a word that arrives in the cycle the client takes the previous one is stored. A client that keeps `rx_ready_i` high gets a one-cycle pulse per frame and never drops one.
- **Transmit:** the reply goes straight into the shift register through the same handshake (`tx_valid_i`, `tx_ready_o`, `tx_data_i`; `tx_bits_i` is ignored). It is written between frames, while `tx_ready_o` is high, and goes out in the next frame that clocks it; a second write before that frame replaces the first, and `tx_ready_o` does not tell whether the host has taken the reply. If `CS#` falls with no word written since the last frame with bits (underrun), the frame goes out as zeros. After `WIDTH` bits the slave sends zeros. `tx_ready_o` is low during a frame. A word written before an empty frame stays for the next one.

The slave sees `CS#` through the synchroniser, so the edges are detected two to three cycles late. The host must keep at least 5 system cycles between `CS#` falling and the first SCK rise, so that the first bit is on MISO in time. The reply for the next frame must be written by the cycle in which the slave sees `CS#` fall: the word of the previous frame is reported one cycle after the slave sees `CS#` rise, so a client that waits for it before writing needs the host to keep `CS#` high for a few cycles.

Neither side knows about commands: what the words mean, and whether a frame of the wrong length is used or dropped, is up to the client.

## spi_shift

A transmit and a receive shift register (`WIDTH` bits each) and a bit counter, moved by four one-cycle strobes. The client writes the transmit register directly; the received word goes to the active role's receive buffer. It does not know which side of the link it is on.

- `start_i` (`CS#` falls): clears the receive register and the count, and clears `ready_reg` (set again by `stop_i`).
- `rise_i` (SCK rises): shifts `din_i` into the receive register and counts the bit, until the count reaches `WIDTH`; later bits are ignored.
- `fall_i` (SCK falls): shifts the transmit register, with zeros shifted in, so `dout_o` (its MSB) shows the next bit, and zeros after the `WIDTH`-th.
- `stop_i` (`CS#` rises): offers the word to the receive buffer and clears the transmit register if the frame had at least one bit (the count only returns to 0 at `start_i`), so an underrun after a shorter frame sends zeros, not what that frame left. After an empty frame the word written before it stays for the next one.
- Write (`tx_valid_i` and `tx_ready_o`): copies `tx_data_i` into the transmit register; `dout_o` is its MSB.
- `tx_ready_o` (`ready_reg`): the transmit register may take a word, only between frames. A second write before a frame replaces the first.
- `rx_valid_o` (`stop_i`), with the receive register on `rx_data_o` and the count on `rx_bits_o`: the word offered to the receive buffer.

## spi_ctrl

Produces the four strobes for the role `dbg_i` selects. As master, an FSM (`IDLE`, `SCK_LO`, `SCK_HI`, `STOP`) generates SCK and `CS#` from `SCK_DIV` and times the strobes to its own clock (so no edge detection is involved). It starts a frame in the cycle the client's `tx_valid_i` is high in `IDLE` (the core takes the word in that cycle), latches the length (`wlen`, from `tx_bits_i`) and counts the bits sent (`wcnt`); at each falling edge the frame ends when the count reaches the length or `WIDTH`, so a length of 0 or above `WIDTH` gives `WIDTH` bits. Its `stop` comes in the `STOP` cycle, the first one with `CS#` high, and `tx_valid_i` is ignored while `dbg_i` is 1. As slave, two registers detect the edges of the synchronised SCK and `CS#`.

## License

MIT
