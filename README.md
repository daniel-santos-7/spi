# spi-dual-role

Dual-role SPI in VHDL-93: one set of pins and one shift core, used either as a master or as a slave.

- SPI mode 0, MSB first, one word of up to `WIDTH` bits per `CS#` frame
- Split into control (`spi_ctrl`) and datapath (`spi_datapath`), one of each in `spi_port`, shared by both roles: the control produces the timing strobes for the selected role and the datapath shifts, counts and buffers
- One word size, `WIDTH` (default 32), for both roles; one client interface for both roles: the word to send goes straight into the shift register (`tx_*`) and a one-word receive buffer delivers the word received (`rx_*`), both behind a ready/valid handshake
- Master: generates SCK and `CS#`; each write is one frame of 1 to `WIDTH` bits (`tx_bits`)
- Slave: follows an external SCK and `CS#` and reports one word per frame, with its bit count; a frame longer than `WIDTH` bits keeps its first `WIDTH` bits. Oversampled by the system clock (no second clock domain)
- Role chosen by a strap input, slave out of reset; the role changes only between frames
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

`make sim` runs the testbench, which wires two `spi_port` instances to one modelled bus (pull resistors, no tri-state inside the design), runs random frames with one as master and the other as slave (`tx_bits` from 0 to beyond `WIDTH`), then swaps the roles, and finally straps both as slaves and drives the pins from a software host with frames of any length (empty, shorter than `WIDTH`, exactly `WIDTH` and longer, up to `2·WIDTH+8` bits). In one phase 0 frame both straps flip in the middle of the frame and back before it ends, which must change nothing, and in the last one the master's strap drops for good in the middle of the frame, which must only take effect after it. In that last phase one frame goes out with no reply written right after a shorter frame, a reply written before an empty frame must go out in the next one, a word offered during a frame must not be taken, and one word is left unread while the next frame arrives. It checks every word both sides report, and the bit count the slave reports (the first `WIDTH` bits and a count of `WIDTH` for a longer frame), that the buffer keeps an unread word and drops what follows, that `tx_ready` stays low during a frame, that the underrun frame sends zeros, the reply bits the host samples (zeros after the `WIDTH`-th), frame boundaries and length, SCK and `CS#` timing, back-to-back frames, pad contention, that SCK, `CS#` and MOSI are driven by the master only, that `role_ack_o` follows the strap and changes only with `CS#` high, and that a slave port ignores `tx_bits` (driven all ones). It stops at the first error and prints `PASS` with coverage counts at the end. `make test` runs it with `WIDTH` = 16, 32 and 64. Generics go in `GENERICS`, e.g. `make sim GENERICS="-gSCK_DIV=7 -gSEED=3 -gNUM_FRAMES=200"` (`SCK_DIV` at least 5, because the slave needs SCK ≤ clk/10). `make wave` does the same and writes `build/tb_spi_port.ghw`.

## spi_port

| Generic | Default | Meaning |
|---------|---------|---------|
| `SCK_DIV` | 1 | Master SCK half-period in system cycles; SCK = clk / (2·`SCK_DIV`) |
| `WIDTH` | 32 | Word size, in bits (at least 2) |
| `CNT_BITS` | 6 | Width of the bit count; 2^`CNT_BITS` must exceed `WIDTH` |

The input `role_req_i`, a control signal synchronous to `clk_i` (it has no synchroniser), requests the role and the output `role_ack_o` gives the role in effect; out of reset the port is a slave:

| `role_req_i` | Role | SCK, `CS#`, MOSI | MISO |
|--------------|------|------------------|------|
| 0 | slave | inputs | driven while `CS#` is low, released otherwise |
| 1 | master | driven (`_oe` = 1) | input |

`spi_port` is structural only: it instantiates `spi_sync`, `spi_ctrl` and `spi_datapath` and wires them to the pins, with no logic of its own, behind one client interface shared by both roles: transmit (`tx_valid_i`, `tx_ready_o`, `tx_data_i`, `tx_bits_i`) and receive (`rx_valid_o`, `rx_ready_i`, `rx_data_o`, `rx_bits_o`). The FSM in `spi_ctrl` picks which strobes drive the datapath (the master's during a master frame, the slave's during a slave frame), and its role in effect (`role_ack_o`, which `spi_port` also gives out) selects the datapath's data in (`miso_i` or the synchronised MOSI, in `spi_datapath`) and the pin enables (in `spi_ctrl`). `tx_bits_i` only matters as master; a slave always sends up to `WIDTH` bits. The datapath drives the same bit on `mosi_o` and `miso_o`; only the one whose `_oe` is set reaches the pin. A word left in the receive buffer when the role changes is still delivered on `rx_*`. A transmit word written and not yet sent when the role changes goes out in the other role's next frame.

Every asynchronous input goes through a two-flip-flop synchroniser, all in `spi_sync`: SCK, `CS#` and MOSI on the way to the slave. The master needs none, since it only samples MISO at its own SCK edge. The control follows `role_req_i` only between frames: the FSM goes from the idle slave state (`S_IDLE`) to the idle master state (`M_IDLE`) when `role_req_i` is 1, and back when it is 0, so `role_req_i` may change at any time: a change during a frame, in either role, takes effect when that frame ends, and a change undone before the frame ends has no effect. `role_ack_o` changes when the role does, always with `CS#` high, so `role_ack_o` = `role_req_i` tells the client that a change has taken effect (for instance, that a write will start a master frame). While the role is slave, `tx_valid_i` only loads the slave's reply and never starts a master frame. While the role is master, the slave's edge detection follows the master's own `CS#` and SCK, and keeps doing so for a few cycles after a switch to slave; `spi_ctrl` passes on the slave strobes only in the `S_FRAME` state (and the slave's `start` only in `S_IDLE`), so the port's own traffic never reaches the slave logic.

### Master role (`role_req_i` = 1)

SCK idles low, `CS#` falls together with the first MOSI bit, MOSI changes on SCK falling edges, and MISO is sampled in the system cycle in which SCK rises. SCK, MOSI and `CS#` all come straight from flip-flops, and so do their `_oe`, high for as long as the role is master.

- **Transmit:** `tx_data_i` goes straight into the shift register, and `tx_bits_i` into the master control, when `tx_valid_i` and `tx_ready_o` are both high, and that write starts a frame. `tx_ready_o` is high while the port is idle and low during a frame, master or slave.
- **Start:** an idle master starts a frame in the cycle a word is written, so between two frames `CS#` stays high for at least 2 cycles (the cycle after the frame, and the cycle in which the next word is written and the frame starts); a client that needs a longer gap, such as a flash's tSHSL, waits before writing.
- **Word length:** `tx_bits_i` is the number of bits of the frame, *n*; 0 or above `WIDTH` means `WIDTH`. The word is left-aligned: the *n* bits sent are `tx_data_i(WIDTH-1 downto WIDTH-n)`. `CS#` is low for `2·n·SCK_DIV` cycles and rises on the falling edge that ends the last bit.
- **Receive:** the word received in each frame goes to the receive buffer, right-aligned on `rx_data_o` (the first bit in bit *n*-1, zeros above) with its count on `rx_bits_o`, in the second cycle with `CS#` high. `rx_valid_o` stays high, and the word held, until the client takes it with `rx_ready_i`; a word that arrives while the buffer is full is dropped. A client that keeps `rx_ready_i` high gets a one-cycle pulse per frame and never drops one.

The master knows nothing about commands. A transaction that needs more than `WIDTH` bits under one `CS#` needs a larger `WIDTH`: a flash read of one 32-bit word, `03h` with the 24-bit address and then 32 bits of data, is one 64-bit frame with `WIDTH` = 64, and the data is in `31 downto 0` of the word received, the byte at the lowest address in `31 downto 24`.

### Slave role (`role_req_i` = 0, default)

The slave runs entirely in the system clock domain, on the synchronised pins. SCK must stay at least 5 system cycles high and 5 low (SCK ≤ clk/10), which leaves time for MISO to update after a falling edge. MOSI is sampled on the SCK rising edge and MISO changes on the falling edge.

- **Receive:** each frame is reported as one word, one cycle after the slave sees `CS#` rise, on `rx_data_o`, with the number of bits (unsigned) on `rx_bits_o`, from 0 (a frame with no SCK edge) to `WIDTH`. The word is right-aligned: a word of *n* < `WIDTH` bits has them in `n-1 downto 0` and zeros above. If the host sends more than `WIDTH` bits, the word holds the first `WIDTH` and the count is `WIDTH`; the bits after them are dropped. `rx_valid_o` stays high, and the buffer holds the word, until the client takes it with `rx_ready_i`. The host cannot be held back, so a word that arrives while the buffer is still full is dropped and the unread word is kept; a word that arrives in the cycle the client takes the previous one is stored. A client that keeps `rx_ready_i` high gets a one-cycle pulse per frame and never drops one.
- **Transmit:** the reply goes straight into the shift register through the same handshake (`tx_valid_i`, `tx_ready_o`, `tx_data_i`; `tx_bits_i` is ignored). It is written between frames, while `tx_ready_o` is high, and goes out in the next frame that clocks it; a second write before that frame replaces the first, and `tx_ready_o` does not tell whether the host has taken the reply. If `CS#` falls with no word written since the last frame with bits (underrun), the frame goes out as zeros. After `WIDTH` bits the slave sends zeros. `tx_ready_o` is low during a frame. A word written before an empty frame stays for the next one.

The slave sees `CS#` through the synchroniser, so the edges are detected two to three cycles late. The host must keep at least 5 system cycles between `CS#` falling and the first SCK rise, so that the first bit is on MISO in time. The reply for the next frame must be written by the cycle in which the slave sees `CS#` fall: the word of the previous frame is reported one cycle after the slave sees `CS#` rise, so a client that waits for it before writing needs the host to keep `CS#` high for a few cycles.

Neither side knows about commands: what the words mean, and whether a frame of the wrong length is used or dropped, is up to the client.

## spi_datapath

The registers that hold and move the data, driven by the control's one-cycle strobes and write (`load_i`). It decides nothing about frames; it reports the bit count back as status (`done_o`). The only thing it knows about the role is which pin feeds the receive register: `miso_i` as master, the synchronised MOSI as slave (`role_i`, the role in effect from the control). Its output bit goes to both `mosi_o` and `miso_o`.

- `start_i` (`CS#` falls): clears the receive register and the count.
- `rise_i` (SCK rises): shifts `din_i` into the receive register and counts the bit, until the count reaches `WIDTH`; later bits are ignored.
- `fall_i` (SCK falls): shifts the transmit register, with zeros shifted in, so `dout_o` (its MSB) shows the next bit, and zeros after the `WIDTH`-th.
- `stop_i` (`CS#` rises): offers the word and its count to the receive buffer, and clears the transmit register if the frame had at least one bit (the count only returns to 0 at `start_i`), so an underrun after a shorter frame sends zeros, not what that frame left. After an empty frame the word written before it stays for the next one.
- `load_i` (a client write): copies `tx_data_i` into the transmit register and `tx_bits_i` into `wlen_reg`.
- `done_o`: the count has reached `wlen_reg` or `WIDTH`, so a length of 0 or above `WIDTH` gives `WIDTH` bits. Only the master control uses it, to end its frame.

The receive buffer holds one word, with a ready/valid handshake on the output. While it is empty (`rx_valid_reg` low), it copies the receive register and the count on every cycle and `rx_valid_reg` takes `stop_i`, so it keeps the word offered in the cycle it fills. While it is full, nothing changes until the client's `rx_ready`, and then the same copy happens once, so a word offered in that cycle is kept and `rx_valid_reg` falls otherwise. There is no ready towards the shift register: the link cannot be held back, so a word that arrives while the buffer is full and `rx_ready` is low is dropped. The outputs follow the receive register while `rx_valid_o` is low and mean nothing then.

## spi_ctrl

Holds the role in effect, produces the four strobes and the client write for that role, drives the pin enables and owns the transmit handshake. One FSM (`S_IDLE`, `S_FRAME`, `M_IDLE`, `M_SCK_LO`, `M_SCK_HI`, `M_STOP`) tracks the role and the frame. Out of reset it is in `S_IDLE`, the idle slave: on the slave's `start` it goes to `S_FRAME`, and back on the slave's `stop`; with no `start` and `role_req_i` at 1 it goes to `M_IDLE`, the idle master. In `M_IDLE` a write starts a frame (the FSM tests `tx_valid_i` alone, since `ready_reg` is always 1 there) in that cycle (the datapath takes the word in the same cycle) and the FSM goes through `M_SCK_LO`, `M_SCK_HI` and `M_STOP` back to `M_IDLE`, generating SCK and `CS#` from `SCK_DIV` and timing the strobes to its own clock (so no edge detection is involved); with no write and `role_req_i` at 0 it goes back to `S_IDLE`. The master frame ends at the falling edge where the datapath's `done_i` is high; its `stop` comes in the `M_STOP` cycle, the first one with `CS#` high.

- `role_reg` is the role in effect (1 = master), set on `S_IDLE → M_IDLE` and cleared on `M_IDLE → S_IDLE`, so it is 1 exactly in the master states. It drives `sclk_oe`, `cs_n_oe`, `mosi_oe` and `role_ack_o`, which goes both to the pin and to the datapath; `miso_oe` is high while the role is slave and the `CS#` pin, unsynchronised, is low.
- `tx_ready_o` comes from a flip-flop (`ready_reg`) that the FSM keeps high exactly while it is in `S_IDLE` or `M_IDLE`, between frames, and a write (`load_o`) is `tx_valid_i` and `ready_reg`; a second write before a frame replaces the first. `m_start`, the master's `start` strobe, is a write with `role_reg` at 1, so a slave reply written in `S_IDLE` gives no `start`.
- The strobes are the master's (`m_start`, `stop_reg` and the SCK edges in `M_SCK_LO`/`M_SCK_HI`) or the slave's: `start` only in `S_IDLE`, `stop`, `rise` and `fall` only in `S_FRAME`. Gating them by state rather than by role matters right after a switch from master to slave, when the edge detection still sees the master's own `CS#` rise. Two registers detect the edges of the synchronised SCK and `CS#`.

## License

MIT
