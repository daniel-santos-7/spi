# spi-dual-role

Dual-role SPI in VHDL-93: one set of pins and one shift core, used either as a master or as a slave.

- SPI mode 0, MSB first, frames of one or more words under one `CS#`
- One shift core (`spi_shift`) in `spi_port`, shared by both roles: the master and the slave only produce the timing strobes that move it
- One word size, `WIDTH` (default 32), for both roles, with a one-word transmit buffer and a one-word receive buffer, each behind a ready/valid handshake
- Master: generates SCK and `CS#`; a word written while a frame runs is chained onto it with no gap, so a frame is as long as the client keeps writing (the last word can be shorter, `tx_bits`)
- Slave: follows an external SCK and `CS#`, frames of any length, reported word by word, oversampled by the system clock (no second clock domain)
- Role chosen by a strap input
- No tri-state: every pin is `_i`, `_o` and `_oe`

## Structure

```
rtl/spi_sync.vhdl     spi_port input synchronisers (two flip-flops each)
rtl/spi_buf.vhdl      one-word ready/valid buffer (transmit and receive instances in spi_port)
rtl/spi_shift.vhdl    shift core (one instance in spi_port)
rtl/spi_ctrl.vhdl     strobes for either role: master SCK/CS# FSM or slave edge detection
rtl/spi_port.vhdl     pins, role select, the buffers and the shared shift core
tbs/tb_spi_port.vhdl  self-checking testbench: two ports on one bus
Makefile              GHDL analysis, simulation and Yosys synthesis
```

`make check` analyses and elaborates the design with GHDL (`TOP=spi_buf`, `spi_shift`, `spi_ctrl` or `spi_port`, default `spi_port`). `make synth` runs a generic Yosys synthesis of `TOP` with the GHDL plugin and prints the cell count.

`make sim` runs the testbench, which wires two `spi_port` instances to one modelled bus (pull resistors, no tri-state inside the design), runs random frames of one to three chained words with one as master and the other as slave (the last word of random length, `tx_bits` from 0 to beyond `WIDTH`), then swaps the roles, and finally straps both as slaves and drives the pins from a software host with frames of any length (empty, shorter than `WIDTH`, exactly `WIDTH` and up to three words). In that last phase one frame goes out with no reply written right after a shorter frame, a reply written before an empty frame must go out in the next one, a second word written during a frame of exactly `WIDTH` bits must be dropped when `CS#` rises, and one word is left unread while the next frame arrives. It checks every word, bit count and last flag both sides report, that the buffer keeps an unread word and drops what follows, that `tx_ready` falls after each write, that the underrun frame sends zeros, the reply bits the host samples, frame boundaries and length (chained words with no gap), SCK and `CS#` timing, back-to-back frames, pad contention, that the unused role in each port stays silent and that a master-strapped port takes no slave reply. It stops at the first error and prints `PASS` with coverage counts at the end. `make test` runs it with `WIDTH` = 16, 32 and 64. Generics go in `GENERICS`, e.g. `make sim GENERICS="-gSCK_DIV=7 -gSEED=3 -gNUM_FRAMES=200"` (`SCK_DIV` at least 5, because the slave needs SCK ≤ clk/10). `make wave` does the same and writes `build/tb_spi_port.ghw`.

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

`spi_port` holds a single `spi_shift` between two `spi_buf` instances, one for transmit and one for receive, and `dbg` selects what drives them: the master's strobes, `miso_i` as data in and the master client's `m_tx_*`, or the slave's strobes, the synchronised MOSI and the slave client's `s_tx_*` (with a word length of `WIDTH`, since the slave has no `tx_bits`). The transmit buffer holds the word, its length and the chain flag (the core's `busy` when it was written); the client's `tx_ready` is `not tx_pend and tx_open`, high while the buffer is empty and the core takes a word. The receive buffer holds the word, the count and the last flag. The buffers' `tx_ready` and `rx_valid` go to the role's interface, and the role's `rx_ready` back to the receive buffer. The core's output bit goes to both `mosi_o` and `miso_o`; only the one whose `_oe` is set reaches the pin. The received word, count and last flag come out on both interfaces. Both buffers are shared: a word left in either when `dbg` changes is seen by the other role.

Every asynchronous input goes through a two-flip-flop synchroniser, all in `spi_sync`: `dbg_i`, and SCK, `CS#` and MOSI on the way to the slave. The master needs none, since it only samples MISO at its own SCK edge. `dbg_o` gives the synchronised strap back to the client. It is a strap, not a run-time switch: change it only while the master is idle and no slave frame is in progress. While it is 1, the master's `tx_valid` is ignored, so no frame starts. While it is 0, the slave sees `CS#` as high, so master traffic never reaches it.

### Master interface (`m_`)

SCK idles low, `CS#` falls together with the first MOSI bit, MOSI changes on SCK falling edges, and MISO is sampled in the system cycle in which SCK rises. SCK, MOSI and `CS#` all come straight from flip-flops.

- **Transmit:** `m_tx_data_i` and `m_tx_bits_i` go into the transmit buffer when `m_tx_valid_i` and `m_tx_ready_o` are both high. `m_tx_ready_o` is high while the buffer is empty, both between frames and during a frame once the word in the buffer has started to go out, until the last bit of the current word; it is low while the port is strapped as slave.
- **Start:** an idle master starts a frame the cycle after a word reaches the buffer, so between two frames `CS#` stays high for at least 3 cycles (the cycle after the frame, the cycle in which the next word is accepted and the cycle in which the frame starts); a client that needs a longer gap, such as a flash's tSHSL, waits before writing.
- **Chaining:** a word written while a frame runs goes out right after the current word, with no gap and no `CS#` edge, if the current word is a full one (`WIDTH` bits). When a full word ends with the buffer empty, `CS#` rises on the falling edge that ends its last bit.
- **Word length:** `m_tx_bits_i` is the number of bits of that word, *n*; 0 or above `WIDTH` means `WIDTH`. The word is left-aligned: the first *n* bits sent are `m_tx_data_i(WIDTH-1 downto WIDTH-n)`. A word shorter than `WIDTH` always ends the frame; a word written while it goes out is dropped when the frame ends. A frame of *k* full words and a last word of *n* bits has `CS#` low for `2·(k·WIDTH+n)·SCK_DIV` cycles.
- **Receive:** every word received goes to the receive buffer, right-aligned on `m_rx_data_o` (the first bit in bit *n*-1, zeros above), with `m_rx_last_o` high on the last word of the frame. A word is reported when the first bit of the next one arrives, or, for the last one, in the second cycle with `CS#` high. `m_rx_valid_o` stays high, and the word held, until the client takes it with `m_rx_ready_i`; a word that arrives while the buffer is full is dropped. A client that keeps `m_rx_ready_i` high gets a one-cycle pulse per word and never drops one.

The master knows nothing about commands. A flash read of one 32-bit word, for example, is a frame of two 32-bit words, `03h` with the 24-bit address and then 32 zeros; the data is the second word received (`m_rx_last_o` high), the byte at the lowest address in `31 downto 24`.

### Slave interface (`s_`)

The slave runs entirely in the system clock domain, on the synchronised pins. SCK must stay at least 5 system cycles high and 5 low (SCK ≤ clk/10), which leaves time for MISO to update after a falling edge. MOSI is sampled on the SCK rising edge and MISO changes on the falling edge.

- **Receive:** the frame is reported word by word on `s_rx_data_o`, with the number of bits (unsigned) on `s_rx_bits_o` and `s_rx_last_o` high on the last word: a word when the first bit of the next one arrives, and the last one, which may have from 0 to `WIDTH` bits, one cycle after the slave sees `CS#` rise. Every frame ends with exactly one last word, even one with no SCK edge, which comes out with `s_rx_bits_o` = 0. Each word is right-aligned: a word of *n* < `WIDTH` bits has them in `n-1 downto 0` and zeros above. `s_rx_valid_o` stays high, and the buffer holds the word, until the client takes it with `s_rx_ready_i`. The host cannot be held back, so a word that arrives while the buffer is still full is dropped and the unread word is kept; a word that arrives in the cycle the client takes the previous one is stored. A client that keeps `s_rx_ready_i` high gets a one-cycle pulse per word and never drops one.
- **Transmit:** reply words go into the transmit buffer through a ready/valid handshake (`s_tx_valid_i`, `s_tx_ready_o`, `s_tx_data_i`), and the buffer is never overwritten. The first word of a frame is written between frames and goes out when the slave sees `CS#` fall; if `CS#` falls with the buffer empty (underrun), the whole frame goes out as zeros, and no word is taken until it ends. Once a word has started to go out, the buffer takes the next one, which follows it with no gap; if the buffer is still empty when a word ends, the rest of the frame is zeros. A word written during a frame that the host ends before it starts is dropped when `CS#` rises, while one written between frames stays until a frame takes it, even across an empty frame. `s_tx_ready_o` is low while the port is strapped as master.

The slave sees `CS#` through the synchroniser, so the edges are detected two to three cycles late. The host must keep at least 5 system cycles between `CS#` falling and the first SCK rise, so that the first bit is on MISO in time. The first reply word of the next frame must be written by the cycle in which the slave sees `CS#` fall: the last word of the previous frame is reported one cycle after the slave sees `CS#` rise, so a client that waits for it before writing needs the host to keep `CS#` high for a few cycles. A chained word must be written before the current word's last bit; the slave sees the falling edge after it late too, so it has to be in the buffer a few cycles before that edge.

Neither side knows about commands: what the words mean, how many make a frame, and whether a frame of the wrong length is used or dropped, is up to the client.

## spi_buf

A one-word buffer with a ready/valid handshake on each side (`WIDTH` bits of data). While it is empty (`valid_reg` low), it copies `in_data_i` on every cycle and `valid_reg` takes `in_valid_i`, so it keeps the word offered in the cycle it fills. While it is full, nothing changes until `out_ready_i`, and then the same copy happens once, so a word offered in that cycle is kept and `valid_reg` falls otherwise. It has no `in_ready`: the transmit side offers a word only while the buffer is empty, and the receive side drops a word that arrives while it is full and `out_ready_i` is low. `out_data_o` follows the input while `out_valid_o` is low and means nothing then.

## spi_shift

A transmit and a receive shift register (`WIDTH` bits each) and a bit counter, moved by four one-cycle strobes, between the transmit and the receive `spi_buf`. It does not know which side of the link it is on.

- `start_i` (`CS#` falls): clears the receive register and the count, and loads the transmit register from the transmit buffer.
- `rise_i` (SCK rises): shifts `din_i` into the receive register and counts the bit. At a count of `WIDTH` (`word_end`), the word just completed is offered to the receive buffer instead, and the new bit starts the next word with a count of 1.
- `fall_i` (SCK falls): shifts the transmit register, with zeros shifted in, so `dout_o` (its MSB) shows the next bit; at a count of `WIDTH` it loads the register from the transmit buffer instead.
- `stop_i` (`CS#` rises): offers the word in progress to the receive buffer as the last one.
- Load (`load`: `start_i`, or `fall_i` at a count of `WIDTH`): copies the transmit buffer's word into the transmit register and its length into `tx_len`, and `tx_valid_i` (the buffer is full) into `send_reg`, which gates `dout_o`: a word loaded from an empty buffer is sent as zeros.
- `tx_pop_o`: takes the word out of the transmit buffer at the next `rise_i` after a load from a full buffer, when its first bit is sent, so an empty frame, or a frame that ends right after the last full word, leaves it there; and at `stop_i` when the word's chain flag (`tx_chain_i`) is set, so a word written during a frame that did not reach it never becomes the first word of the next frame.
- `tx_open_o`: the transmit buffer may take a word: between frames (`busy_reg` low; it is set by `start_i` and cleared by `stop_i`, and comes out on `busy_o` for the chain flag) or during a frame whose current word came from the buffer (`send_reg`) and has not reached its end (`tx_end`). So after an underrun nothing is taken until the frame ends, and a master takes no word after its last word has reached its end; one written during a shorter last word is taken and then dropped.
- `tx_end_o`: the current word is the last one: its count reached `tx_len` (a length of 0 or above `WIDTH` never matches), or it reached `WIDTH` with the transmit buffer empty. Only the master uses it, to end its frame.
- `rx_valid_o` (`stop_i or word_end`), with the receive register on `rx_data_o`, the count on `rx_bits_o` and `stop_i` on `rx_last_o`: the word offered to the receive buffer.

## spi_ctrl

Produces the four strobes for the role `dbg_i` selects. As master, an FSM (`IDLE`, `SCK_LO`, `SCK_HI`, `STOP`) generates SCK and `CS#` from `SCK_DIV`, times the strobes to its own clock (so no edge detection is involved) and starts a frame when the transmit buffer is full (`tx_pend`) and ends it on the core's `tx_end`, checked at the end of each bit; its `stop` comes in the `STOP` cycle, the first one with `CS#` high, and `tx_valid_i` (`tx_pend`) is ignored while `dbg_i` is 1. As slave, two registers detect the edges of the synchronised SCK and `CS#`.

## License

MIT
