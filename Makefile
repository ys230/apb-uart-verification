VERILATOR ?= verilator
PYTHON ?= python3
WAIT_CYCLES ?= 0
TEST ?= all
SEED ?= 1
N_TRANSACTIONS ?= 1000
TRACE ?= 0
WAVES ?= 0
COVERAGE_FILE ?=
FPGA_CLK_HZ ?= 50000000
FPGA_BAUD ?= 115200
PNR_SEED ?= 1

RTL := rtl/sync_fifo.sv rtl/uart_tx.sv rtl/uart_rx.sv rtl/apb_uart.sv
ASSERTIONS := assertions/apb_uart_assertions.sv
TB := tb/tb_top.sv
BUILD_DIR := build/wait$(WAIT_CYCLES)-trace$(TRACE)
SIM := $(BUILD_DIR)/Vtb_top
FIFO_SIM := build/fifo/Vfifo_tb
FPGA_RTL := fpga/rtl/apb_uart_echo_master.sv fpga/rtl/fpga_uart_demo.sv
FPGA_BUILD_DIR := build/fpga-demo-wait$(WAIT_CYCLES)
FPGA_SIM := $(FPGA_BUILD_DIR)/Vfpga_demo_tb
TRACE_FLAG := $(if $(filter 1,$(TRACE)),--trace,)
WAVES_PLUSARG := $(if $(filter 1,$(WAVES)),+WAVES,)
COVERAGE_PLUSARG := $(if $(COVERAGE_FILE),+verilator+coverage+file+$(COVERAGE_FILE),)

.PHONY: lint test test-fifo regress mutation waves clean lint-fpga test-fpga synth timing-reference test-hardware-tools fpga-evidence

lint:
	$(VERILATOR) --lint-only -Wall --top-module apb_uart $(RTL)
	$(VERILATOR) --lint-only --timing --assert -Wall --top-module tb_top \
		-GWAIT_CYCLES=0 $(RTL) $(ASSERTIONS) $(TB)

$(SIM): $(RTL) $(ASSERTIONS) $(TB) Makefile
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert --coverage $(TRACE_FLAG) -Wall \
		--top-module tb_top -GWAIT_CYCLES=$(WAIT_CYCLES) \
		--Mdir $(BUILD_DIR) $(RTL) $(ASSERTIONS) $(TB)

test: $(SIM)
	$(SIM) +TEST=$(TEST) +SEED=$(SEED) +N_TRANSACTIONS=$(N_TRANSACTIONS) $(WAVES_PLUSARG) $(COVERAGE_PLUSARG)

$(FIFO_SIM): rtl/sync_fifo.sv tb/fifo_tb.sv Makefile
	mkdir -p build/fifo
	$(VERILATOR) --binary --timing --assert --coverage -Wall \
		--top-module fifo_tb --Mdir build/fifo rtl/sync_fifo.sv tb/fifo_tb.sv

test-fifo: $(FIFO_SIM)
	$(FIFO_SIM) $(COVERAGE_PLUSARG)

waves:
	$(MAKE) test TRACE=1 TEST=$(TEST) SEED=$(SEED) N_TRANSACTIONS=$(N_TRANSACTIONS) WAVES=1

regress:
	$(PYTHON) scripts/regress.py

mutation:
	$(PYTHON) scripts/check_mutation.py

lint-fpga:
	$(VERILATOR) --lint-only -Wall --top-module fpga_uart_demo \
		-GCLK_HZ=$(FPGA_CLK_HZ) -GBAUD_RATE=$(FPGA_BAUD) $(RTL) $(FPGA_RTL)
	$(VERILATOR) --lint-only --timing --assert -Wall --top-module fpga_demo_tb \
		-GWAIT_CYCLES=$(WAIT_CYCLES) $(RTL) $(FPGA_RTL) tb/fpga_demo_tb.sv

$(FPGA_SIM): $(RTL) $(FPGA_RTL) tb/fpga_demo_tb.sv Makefile
	mkdir -p $(FPGA_BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall --top-module fpga_demo_tb \
		-GWAIT_CYCLES=$(WAIT_CYCLES) --Mdir $(FPGA_BUILD_DIR) \
		$(RTL) $(FPGA_RTL) tb/fpga_demo_tb.sv

test-fpga: $(FPGA_SIM)
	$(FPGA_SIM)

synth:
	$(PYTHON) scripts/run_synthesis.py --wait-cycles $(WAIT_CYCLES)

timing-reference:
	$(PYTHON) scripts/run_timing_reference.py --clock-hz $(FPGA_CLK_HZ) \
		--baud $(FPGA_BAUD) --seed $(PNR_SEED)

test-hardware-tools:
	$(PYTHON) -c 'import serial; print("pySerial", serial.VERSION)'
	$(PYTHON) -m unittest discover -s tests -p 'test_fpga_uart.py' -v

fpga-evidence:
	$(PYTHON) scripts/publish_fpga_evidence.py

clean:
	rm -rf build/fifo build/wait*-trace* build/fpga-demo-wait* build/tb_top.vcd
