GHDL      ?= ghdl
YOSYS     ?= yosys
BUILD     := build
GHDLFLAGS := --std=93 --workdir=$(BUILD)
TOP       ?= spi_port

RTL_SRCS  := rtl/spi_sync.vhdl rtl/spi_edge.vhdl rtl/spi_tx_buf.vhdl rtl/spi_trx.vhdl rtl/spi_rx_buf.vhdl rtl/spi_ctrl.vhdl rtl/spi_port.vhdl
TB_SRCS   := tbs/tb_spi_port.vhdl
TB        ?= tb_spi_port
GENERICS  ?=

.PHONY: all check sim test wave synth clean

all: check

$(BUILD):
	mkdir -p $@

check: | $(BUILD)
	$(GHDL) -a $(GHDLFLAGS) $(RTL_SRCS)
	$(GHDL) -e $(GHDLFLAGS) -o $(BUILD)/$(TOP) $(TOP)

sim: | $(BUILD)
	$(GHDL) -a $(GHDLFLAGS) $(RTL_SRCS) $(TB_SRCS)
	$(GHDL) -e $(GHDLFLAGS) -o $(BUILD)/$(TB) $(TB)
	$(BUILD)/$(TB) --assert-level=error $(GENERICS) $(SIMFLAGS)

test:
	@for w in 16 32 64; do $(MAKE) --no-print-directory sim GENERICS="-gWIDTH=$$w $(GENERICS)" || exit 1; done

wave: SIMFLAGS += --wave=$(BUILD)/$(TB).ghw
wave: sim

synth: $(RTL_SRCS) | $(BUILD)
	$(YOSYS) -m ghdl -q -l $(BUILD)/synth_$(TOP).log \
	  -p "ghdl --std=93 $(RTL_SRCS) -e $(TOP); \
	      synth -top $(TOP); \
	      write_verilog -noattr $(BUILD)/$(TOP).v; \
	      tee -q -o $(BUILD)/synth_$(TOP).stat stat"
	@sed -n '/=== $(TOP) ===/,$$p' $(BUILD)/synth_$(TOP).stat

clean:
	rm -rf $(BUILD) spi_sync spi_edge spi_tx_buf spi_trx spi_rx_buf spi_ctrl spi_port *.o
