PYTHON ?= python3
IVERILOG ?= iverilog
VVP ?= vvp
YOSYS ?= yosys

RTL := \
	rtl/memory/sdp_ram.sv \
	rtl/memory/banked_sram.sv \
	rtl/compute/gemv_engine.sv \
	rtl/control/tinyllm_d1_core.sv

.PHONY: all test sim synth synth-xilinx metrics clean

all: test sim synth metrics

test:
	$(PYTHON) -m pytest

build:
	mkdir -p build results/simulation results/synthesis

sim: build
	$(IVERILOG) -g2012 -Wall -s tb_tinyllm_d1_core \
		-o build/tb_tinyllm_d1_core.vvp $(RTL) tb/tb_tinyllm_d1_core.sv \
		2>&1 | tee results/simulation/iverilog_compile.log
	$(VVP) build/tb_tinyllm_d1_core.vvp \
		2>&1 | tee results/simulation/iverilog_run.log

synth: build
	$(YOSYS) -Q -l results/synthesis/generic.log synthesis/generic.ys

synth-xilinx: build
	$(YOSYS) -Q -l results/synthesis/xilinx7.log synthesis/xilinx7.ys

metrics:
	$(PYTHON) scripts/collect_results.py

clean:
	rm -rf build results/simulation results/synthesis results/summary.json
