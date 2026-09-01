SHELL := /bin/bash
RISCV_PREFIX ?= riscv64-unknown-elf-
RISCV_GCC := $(RISCV_PREFIX)gcc
RISCV_OBJCOPY := $(RISCV_PREFIX)objcopy
RISCV_OBJDUMP := $(RISCV_PREFIX)objdump
RTL := rtl/cpu/apzn_rv32i_core.sv rtl/memory/soc_bram32.sv rtl/mmio_llm_accel.sv rtl/uart_tx.sv rtl/rv32_llm_soc.sv
CFLAGS := -march=rv32i -mabi=ilp32 -Os -g -ffreestanding -fno-builtin -fdata-sections -ffunction-sections -mstrict-align -Wall -Wextra
LDFLAGS := -nostdlib -nostartfiles -Wl,--gc-sections -Wl,-Map,build/firmware.map -T firmware/link.ld

.PHONY: all dirs firmware lint sim synth pnr bitstream manifest package clean tool-versions
all: sim bitstream manifest

dirs:
	mkdir -p build results

firmware: | dirs
	$(RISCV_GCC) $(CFLAGS) $(LDFLAGS) \
		firmware/start.S firmware/rv32i_selftest.S firmware/main.c \
		-o build/firmware.elf
	$(RISCV_OBJCOPY) -O binary build/firmware.elf build/firmware.bin
	$(RISCV_OBJDUMP) -d -S build/firmware.elf > build/firmware.disasm
	python3 scripts/bin2hex.py build/firmware.bin build/firmware.hex --words 4096 \
		--lane-prefix build/firmware_lane
	@test $$(stat -c%s build/firmware.bin) -le 16384
	@! grep -Eq '\<(mul|mulh|mulhsu|mulhu|div|divu|rem|remu)\>' build/firmware.disasm

lint: firmware
	verilator --lint-only -Wall -Wno-fatal --top-module rv32_llm_soc $(RTL)

sim: firmware
	iverilog -g2012 -Wall -s tb_rv32_llm_soc -o build/tb_soc $(RTL) tb/tb_rv32_llm_soc.sv
	vvp build/tb_soc | tee build/simulation.log
	grep -q "PASS: APZN RV32I core completed ISA, INT8 and INT4 accelerator tests" build/simulation.log

synth: firmware
	yosys -ql build/yosys.log synth/ulx3s.ys
	@test -s build/ulx3s.json

pnr: synth
	nextpnr-ecp5 --85k --package CABGA381 --speed 6 --json build/ulx3s.json \
		--lpf constraints/ulx3s_minimal.lpf --textcfg build/ulx3s.config \
		--freq 25 --log build/nextpnr.log
	@test -s build/ulx3s.config

bitstream: pnr
	ecppack --compress --input build/ulx3s.config --bit build/apzn_rv32i_llm_soc_ulx3s_85f.bit
	@test -s build/apzn_rv32i_llm_soc_ulx3s_85f.bit
	sha256sum build/apzn_rv32i_llm_soc_ulx3s_85f.bit > build/apzn_rv32i_llm_soc_ulx3s_85f.bit.sha256

manifest: bitstream sim
	python3 scripts/summarize.py | tee build/manifest_stdout.json

tool-versions: | dirs
	{ \
		echo "date_utc=$$(date -u +%FT%TZ)"; \
		uname -a; \
		$(RISCV_GCC) --version | head -n1; \
		iverilog -V 2>&1 | head -n2; \
		verilator --version; \
		yosys -V; \
		nextpnr-ecp5 --version; \
		ecppack --version 2>&1 | head -n2; \
	} | tee build/tool_versions.txt

package: manifest tool-versions
	tar --exclude='build/rv32_llm_soc.vcd' -czf build/apzn-rv32i-llm-soc-ulx3s-build.tar.gz \
		README.md README.ko.md Makefile docs rtl firmware tb constraints synth scripts results \
		build/firmware.elf build/firmware.bin build/firmware.hex build/firmware_lane?.hex \
		build/firmware.disasm build/firmware.map build/simulation.log build/yosys.log \
		build/nextpnr.log build/ulx3s.json build/ulx3s.config \
		build/apzn_rv32i_llm_soc_ulx3s_85f.bit build/apzn_rv32i_llm_soc_ulx3s_85f.bit.sha256 build/tool_versions.txt
	sha256sum build/apzn-rv32i-llm-soc-ulx3s-build.tar.gz > build/apzn-rv32i-llm-soc-ulx3s-build.tar.gz.sha256

clean:
	rm -rf build results/build_manifest.json
