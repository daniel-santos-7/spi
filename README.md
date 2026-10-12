# spi-dual-role

Dual-role SPI in VHDL-93: one set of pins and one shift core, used either as a master or as a slave.

- SPI mode 0, MSB first, one word of up to `WIDTH` bits per `CS#` frame
- Split into control (`spi_ctrl`) and datapath (`spi_datapath`), one of each in `spi_port`, shared by both roles: the control produces the timing strobes for the selected role and the datapath shifts, counts and buffers
- One word size, `WIDTH` (default 32), for both roles; one client interface for both roles: the word to send goes straight into the shift register (`tx_*`) and a one-word receive buffer delivers the word received (`rx_*`), both behind a ready/valid handshake
- Master: generates SCK and `CS#`; each write is one frame of 1 to `WIDTH` bits (`tx_bits`)
- Slave: follows an external SCK and `CS#` and reports one word per frame, with its bit count; a frame longer than `WIDTH` bits keeps its first `WIDTH` bits. Oversampled by the system clock (no second clock domain)
- Slave by default; a strap input lets client writes start master frames, and the port drives SCK, `CS#` and MOSI only during those frames
- No tri-state: every pin is `_i`, `_o` and `_oe`

## Structure

```
rtl/spi_sync.vhdl     spi_port input synchronisers (two flip-flops each)
rtl/spi_datapath.vhdl datapath: shift registers, bit count, frame length and receive buffer
rtl/spi_ctrl.vhdl     control: master SCK/CS# FSM, slave edge detection, transmit ready
rtl/spi_port.vhdl     structural top: instantiates spi_sync, spi_ctrl and spi_datapath
tbs/tb_spi_port.vhdl  self-checking testbench: two ports on one bus
Makefile              GHDL analysis, simulation and Yosys synthesis
```

`make check` analyses and elaborates the design with GHDL (`TOP=spi_datapath`, `spi_ctrl` or `spi_port`, default `spi_port`). `make synth` runs a generic Yosys synthesis of `TOP` with the GHDL plugin and prints the cell count.

`make sim` runs the testbench, which wires two `spi_port` instances to one modelled bus (pull resistors, no tri-state inside the design), runs random frames with one as master and the other as slave (`tx_bits` from 0 to beyond `WIDTH`), then swaps the roles, and finally straps both as slaves and drives the pins from a software host with frames of any length (empty, shorter than `WIDTH`, exactly `WIDTH` and longer, up to `2·WIDTH+8` bits). In one phase 0 frame both straps flip in the middle of the frame and back before it ends, which must change nothing. In that last phase one frame goes out with no reply written right after a shorter frame, a reply written before an empty frame must go out in the next one, a word offered during a frame must not be taken, and one word is left unread while the next frame arrives. It checks every word both sides report, and the bit count the slave reports (the first `WIDTH` bits and a count of `WIDTH` for a longer frame), that the buffer keeps an unread word and drops what follows, that `tx_ready` stays low during a frame, that the underrun frame sends zeros, the reply bits the host samples (zeros after the `WIDTH`-th), frame boundaries and length, SCK and `CS#` timing, back-to-back frames, pad contention, that SCK, `CS#` and MOSI are driven only by the master and only during its frames (`CS#` driven high for one cycle at the end), and that a slave port ignores `tx_bits` (driven all ones) and never drives them. It stops at the first error and prints `PASS` with coverage counts at the end. `make test` runs it with `WIDTH` = 16, 32 and 64. Generics go in `GENERICS`, e.g. `make sim GENERICS="-gSCK_DIV=7 -gSEED=3 -gNUM_FRAMES=200"` (`SCK_DIV` at least 5, because the slave needs SCK ≤ clk/10). `make wave` does the same and writes `build/tb_spi_port.ghw`.

## spi_port

| Generic | Default | Meaning |
|---------|---------|---------|
| `SCK_DIV` | 1 | Master SCK half-period in system cycles; SCK = clk / (2·`SCK_DIV`) |
| `WIDTH` | 32 | Word size, in bits (at least 2) |
| `CNT_BITS` | 6 | Width of the bit count; 2^`CNT_BITS` must exceed `WIDTH` |

The port is a slave by default. The input `dbg_i` only decides what a client write does:

| `dbg_i` | A write | SCK, `CS#`, MOSI | MISO |
|---------|---------|------------------|------|
| 0 | loads the slave's reply | inputs | driven while `CS#` is low and the port is not running a master frame |
| 1 | starts a master frame | driven only during that frame (`_oe` = 1), inputs otherwise | input during that frame |

Between frames nobody drives SCK, `CS#` or MOSI, so the board needs a pull-up on `CS#` and a pull-down on SCK (mode 0 idles low). The master drives `CS#` high in the last cycle of its frame and then releases it.

`spi_port` is structural only: it instantiates `spi_sync`, `spi_ctrl` and `spi_datapath` and wires them to the pins, with no logic of its own, behind one client interface shared by both roles: transmit (`tx_valid_i`, `tx_ready_o`, `tx_data_i`, `tx_bits_i`) and receive (`rx_valid_o`, `rx_ready_i`, `rx_data_o`, `rx_bits_o`). The FSM in `spi_ctrl` decides, frame by frame, which strobes drive the datapath (the master's during a master frame, the slave's during a slave frame), and its `drv_o` (a master frame is running) selects the datapath's data in (`miso_i` or the synchronised MOSI, in `spi_datapath`) and the pin enables (in `spi_ctrl`). `tx_bits_i` only matters as master; a slave always sends up to `WIDTH` bits. The datapath drives the same bit on `mosi_o` and `miso_o`; only the one whose `_oe` is set reaches the pin. A word left in the receive buffer is delivered on `rx_*` whatever `dbg_i` does.

Every asynchronous input goes through a two-flip-flop synchroniser, all in `spi_sync`: `dbg_i`, and SCK, `CS#` and MOSI on the way to the slave. The master needs none, since it only samples MISO at its own SCK edge. The control looks at the synchronised `dbg_i` only in `IDLE`, at the cycle of a write, so `dbg_i` may change at any time: a frame already running, in either role, is not affected. A reply written with `dbg_i` at 0 and not yet sent stays in the shift register and goes out in the next frame, master or slave. With `dbg_i` at 1 the port still answers a frame from another master, but every write starts a master frame, so it cannot load a reply. During a master frame the slave's edge detection follows the port's own `CS#` and SCK, but `spi_ctrl` passes on the slave strobes only in the `SLAVE` state (and the slave's `start` only in `IDLE`), so the port's own traffic never reaches the slave logic.

There is no arbitration between masters. A port with `dbg_i` at 1 sees another master's `CS#` through the synchroniser; a write in the two or three cycles before it sees `CS#` fall starts a master frame on a busy bus. Use one master enabled per bus, or keep the client from writing while another master may start.

### Master role (`dbg_i` = 1)

SCK idles low, `CS#` falls together with the first MOSI bit, MOSI changes on SCK falling edges, and MISO is sampled in the system cycle in which SCK rises. SCK, MOSI and `CS#` all come straight from flip-flops, and so do their `_oe`, high from the first cycle with `CS#` low to the first one with `CS#` high.

- **Transmit:** `tx_data_i` goes straight into the shift register, and `tx_bits_i` into the master control, when `tx_valid_i` and `tx_ready_o` are both high, and that write starts a frame. `tx_ready_o` is high while the port is idle and low during a frame, master or slave.
- **Start:** an idle master starts a frame in the cycle a word is written, so between two frames `CS#` stays high for at least 2 cycles (the cycle after the frame, and the cycle in which the next word is written and the frame starts); a client that needs a longer gap, such as a flash's tSHSL, waits before writing.
- **Word length:** `tx_bits_i` is the number of bits of the frame, *n*; 0 or above `WIDTH` means `WIDTH`. The word is left-aligned: the *n* bits sent are `tx_data_i(WIDTH-1 downto WIDTH-n)`. `CS#` is low for `2·n·SCK_DIV` cycles and rises on the falling edge that ends the last bit.
- **Receive:** the word received in each frame goes to the receive buffer, right-aligned on `rx_data_o` (the first bit in bit *n*-1, zeros above) with its count on `rx_bits_o`, in the second cycle with `CS#` high. `rx_valid_o` stays high, and the word held, until the client takes it with `rx_ready_i`; a word that arrives while the buffer is full is dropped. A client that keeps `rx_ready_i` high gets a one-cycle pulse per frame and never drops one.

The master knows nothing about commands. A transaction that needs more than `WIDTH` bits under one `CS#` needs a larger `WIDTH`: a flash read of one 32-bit word, `03h` with the 24-bit address and then 32 bits of data, is one 64-bit frame with `WIDTH` = 64, and the data is in `31 downto 0` of the word received, the byte at the lowest address in `31 downto 24`.

### Slave role (default)

The slave runs entirely in the system clock domain, on the synchronised pins. SCK must stay at least 5 system cycles high and 5 low (SCK ≤ clk/10), which leaves time for MISO to update after a falling edge. MOSI is sampled on the SCK rising edge and MISO changes on the falling edge.

- **Receive:** each frame is reported as one word, one cycle after the slave sees `CS#` rise, on `rx_data_o`, with the number of bits (unsigned) on `rx_bits_o`, from 0 (a frame with no SCK edge) to `WIDTH`. The word is right-aligned: a word of *n* < `WIDTH` bits has them in `n-1 downto 0` and zeros above. If the host sends more than `WIDTH` bits, the word holds the first `WIDTH` and the count is `WIDTH`; the bits after them are dropped. `rx_valid_o` stays high, and the buffer holds the word, until the client takes it with `rx_ready_i`. The host cannot be held back, so a word that arrives while the buffer is still full is dropped and the unread word is kept; a word that arrives in the cycle the client takes the previous one is stored. A client that keeps `rx_ready_i` high gets a one-cycle pulse per frame and never drops one.
- **Transmit:** the reply goes straight into the shift register through the same handshake (`tx_valid_i`, `tx_ready_o`, `tx_data_i`; `tx_bits_i` is ignored). It is written with `dbg_i` at 0, between frames, while `tx_ready_o` is high, and goes out in the next frame that clocks it; a second write before that frame replaces the first, and `tx_ready_o` does not tell whether the host has taken the reply. If `CS#` falls with no word written since the last frame with bits (underrun), the frame goes out as zeros. After `WIDTH` bits the slave sends zeros. `tx_ready_o` is low during a frame. A word written before an empty frame stays for the next one.

The slave sees `CS#` through the synchroniser, so the edges are detected two to three cycles late. The host must keep at least 5 system cycles between `CS#` falling and the first SCK rise, so that the first bit is on MISO in time. The reply for the next frame must be written by the cycle in which the slave sees `CS#` fall: the word of the previous frame is reported one cycle after the slave sees `CS#` rise, so a client that waits for it before writing needs the host to keep `CS#` high for a few cycles.

Neither side knows about commands: what the words mean, and whether a frame of the wrong length is used or dropped, is up to the client.

## spi_datapath

The registers that hold and move the data, driven by the control's one-cycle strobes and write (`load_i`). It decides nothing about frames; it reports the bit count back as status (`done_o`). The only thing it knows about the role is which pin feeds the receive register: `miso_i` during a master frame (`drv_i` from the control), the synchronised MOSI otherwise. Its output bit goes to both `mosi_o` and `miso_o`.

- `start_i` (`CS#` falls): clears the receive register and the count.
- `rise_i` (SCK rises): shifts `din_i` into the receive register and counts the bit, until the count reaches `WIDTH`; later bits are ignored.
- `fall_i` (SCK falls): shifts the transmit register, with zeros shifted in, so `dout_o` (its MSB) shows the next bit, and zeros after the `WIDTH`-th.
- `stop_i` (`CS#` rises): offers the word and its count to the receive buffer, and clears the transmit register if the frame had at least one bit (the count only returns to 0 at `start_i`), so an underrun after a shorter frame sends zeros, not what that frame left. After an empty frame the word written before it stays for the next one.
- `load_i` (a client write): copies `tx_data_i` into the transmit register and `tx_bits_i` into `wlen_reg`.
- `done_o`: the count has reached `wlen_reg` or `WIDTH`, so a length of 0 or above `WIDTH` gives `WIDTH` bits. Only the master control uses it, to end its frame.

The receive buffer holds one word, with a ready/valid handshake on the output. While it is empty (`rx_valid_reg` low), it copies the receive register and the count on every cycle and `rx_valid_reg` takes `stop_i`, so it keeps the word offered in the cycle it fills. While it is full, nothing changes until the client's `rx_ready`, and then the same copy happens once, so a word offered in that cycle is kept and `rx_valid_reg` falls otherwise. There is no ready towards the shift register: the link cannot be held back, so a word that arrives while the buffer is full and `rx_ready` is low is dropped. The outputs follow the receive register while `rx_valid_o` is low and mean nothing then.

## spi_ctrl

Produces the four strobes and the client write, drives the pin enables and owns the transmit handshake. One FSM (`IDLE`, `SCK_LO`, `SCK_HI`, `STOP`, `SLAVE`) tracks the frame; there is no role register. `IDLE` is a slave waiting for `CS#`: on the slave's `start` it goes to `SLAVE`, and back on the slave's `stop`. A write in `IDLE` with `dbg_i` at 1 (`m_start`) starts a master frame instead, in that cycle (the datapath takes the word in the same cycle), and takes priority over a slave `start` in the same cycle; the FSM then goes through `SCK_LO`, `SCK_HI` and `STOP`, generating SCK and `CS#` from `SCK_DIV` and timing the strobes to its own clock (so no edge detection is involved). The frame ends at the falling edge where the datapath's `done_i` is high; its `stop` comes in the `STOP` cycle, the first one with `CS#` high.

- `tx_ready_o` comes from a flip-flop (`ready_reg`) that the FSM keeps high exactly while it is in `IDLE`, between frames, and a write (`load_o`) is `tx_valid_i` and `ready_reg`; a second write before a frame replaces the first.
- `drv_reg` is high from `m_start` to the end of `STOP`, so for the whole master frame. It drives `sclk_oe`, `cs_n_oe` and `mosi_oe`, and `drv_o` to the datapath; `miso_oe` is high while the `CS#` pin, unsynchronised, is low and `drv_reg` is low.
- The strobes are the master's (`m_start`, `stop_reg` and the SCK edges in `SCK_LO`/`SCK_HI`) or the slave's: `start` only in `IDLE`, `stop`, `rise` and `fall` only in `SLAVE`. Two registers detect the edges of the synchronised SCK and `CS#`.

## License

MIT
