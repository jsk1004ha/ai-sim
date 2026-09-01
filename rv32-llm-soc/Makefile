SHELL := /bin/bash
PICORV32_COMMIT := a473fc8fca393771d83b0ffcf0b14db3393339d8
RISCV_PREFIX ?= riscv64-unknown-elf-
RISCV_GCC := $(RISCV_PREFIX)gcc
RISCV_OBJCOPY := $(RISCV_PREFIX)objcopy
RISCV_OBJDUMP := $(RISCV_PREFIX)objdump
RTL := third_party/picorv32.v rtl/mmio_llm_accel.sv rtl/uart_tx.sv rtl/rv32_llm_soc.sv
CFLAGS := -march=rv32i -mabi=ilp32 -Os -g -ffreestanding -fno-builtin -fdata-sections -ffunction-sections -mstrict-align -Wall -Wextra
LDFLAGS := -nostdlib -nostartfiles -Wl,--gc-sections -Wl,-Map,build/firmware.map -T firmware/link.ld

.PHONY: all dirs fetch-cpu firmware lint sim synth pnr bitstream manifest package clean tool-versions
all: sim bitstream manifest

dirs:
	mkdir -p build results third_party

fetch-cpu: | dirs
	@if [ ! -s third_party/picorv32.v ]; then \
		curl -fsSL https://raw.githubusercontent.com/YosysHQ/picorv32/$(PICORV32_COMMIT)/picorv32.v -o third_party/picorv32.v; \
		curl -fsSL https://raw.githubusercontent.com/YosysHQ/picorv32/$(PICORV32_COMMIT)/COPYING -o third_party/PICORV32_LICENSE; \
	fi
	sha256sum third_party/picorv32.v third_party/PICORV32_LICENSE > build/third_party.sha256

firmware: fetch-cpu
	$(RISCV_GCC) $(CFLAGS) $(LDFLAGS) firmware/start.S firmware/main.c -o build/firmware.elf
	$(RISCV_OBJCOPY) -O binary build/firmware.elf build/firmware.bin
	$(RISCV_OBJDUMP) -d -S build/firmware.elf > build/firmware.disasm
	python3 scripts/bin2hex.py build/firmware.bin build/firmware.hex --words 4096
	@test $$(stat -c%s build/firmware.bin) -le 16384

lint: firmware
	verilator --lint-only -Wall -Wno-fatal --top-module rv32_llm_soc $(RTL)

sim: firmware
	iverilog -g2012 -Wall -s tb_rv32_llm_soc -o build/tb_soc $(RTL) tb/tb_rv32_llm_soc.sv
	vvp build/tb_soc | tee build/simulation.log
	grep -q "PASS: RV32 firmware completed" build/simulation.log

synth: firmware
	yosys -ql build/yosys.log synth/ulx3s.ys
	@test -s build/ulx3s.json

pnr: synth
	nextpnr-ecp5 --85k --package CABGA381 --speed 6 --json build/ulx3s.json \
		--lpf constraints/ulx3s_minimal.lpf --textcfg build/ulx3s.config \
		--freq 25 --log build/nextpnr.log
	@test -s build/ulx3s.config

bitstream: pnr
	ecppack --compress --input build/ulx3s.config --bit build/rv32_llm_soc_ulx3s_85f.bit
	@test -s build/rv32_llm_soc_ulx3s_85f.bit
	sha256sum build/rv32_llm_soc_ulx3s_85f.bit > build/rv32_llm_soc_ulx3s_85f.bit.sha256

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
	tar --exclude='build/rv32_llm_soc.vcd' -czf build/rv32-llm-soc-ulx3s-build.tar.gz \
		README.md README.ko.md Makefile docs rtl firmware tb constraints synth scripts third_party results \
		build/firmware.elf build/firmware.bin build/firmware.hex build/firmware.disasm build/firmware.map \
		build/simulation.log build/yosys.log build/nextpnr.log build/ulx3s.json build/ulx3s.config \
		build/rv32_llm_soc_ulx3s_85f.bit build/rv32_llm_soc_ulx3s_85f.bit.sha256 build/tool_versions.txt
	sha256sum build/rv32-llm-soc-ulx3s-build.tar.gz > build/rv32-llm-soc-ulx3s-build.tar.gz.sha256

clean:
	rm -rf build results/build_manifest.json third_party/picorv32.v third_party/PICORV32_LICENSE
