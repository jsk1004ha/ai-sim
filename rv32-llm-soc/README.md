# RV32 TinyLLM SoC — physically implemented FPGA CPU system

This project turns the earlier standalone LLM arithmetic RTL into a complete, firmware-driven CPU SoC:

- PicoRV32 RV32I CPU pinned to a specific upstream commit
- 16 KiB synthesizable instruction/data RAM
- memory-mapped signed INT8 and packed signed INT4 GEMV accelerator
- 32-bit accumulators and results
- UART transmitter and eight LED outputs
- real firmware compiled by the RISC-V GNU toolchain
- CPU-level self-test in Icarus Verilog
- Verilator lint
- Yosys ECP5 synthesis
- nextpnr-ecp5 placement, routing and timing analysis
- `ecppack` ULX3S-85F bitstream generation

The firmware computes known INT8 and INT4 vectors through MMIO. `0xA5` on the LEDs and the UART message `ALL TESTS PASS` mean the CPU, bus, firmware and accelerator agreed. Error codes are `0xE1` for INT8 and `0xE4` for INT4.

## Target

- Board: ULX3S v2.x/v3.0.x
- FPGA: Lattice ECP5 `LFE5U-85F-6BG381C`
- Clock: on-board 25 MHz oscillator
- UART: FTDI receive pin, 115200 8-N-1

## Reproduce

```bash
make tool-versions
make lint
make sim
make bitstream
make manifest
make package
```

Required programs: `riscv64-unknown-elf-gcc`, `iverilog`, `verilator`, `yosys`, `nextpnr-ecp5`, and `ecppack`.

## Program an actual board

Connect ULX3S USB1 and run either command from OSS CAD Suite:

```bash
fujprog build/rv32_llm_soc_ulx3s_85f.bit
# or
openFPGALoader -b ulx3s build/rv32_llm_soc_ulx3s_85f.bit
```

A successful physical run ends with LEDs `0xA5`; the FTDI serial port prints the boot and test results at 115200 baud.

## Scope

This is a real FPGA CPU SoC and produces a placed-and-routed bitstream. It is not an ASIC tapeout, a full Transformer processor, or proof of board execution inside CI. The accelerator is deliberately small so that CPU/firmware/bus/RTL/physical-flow integration can be verified before adding DMA, external SDRAM, attention and larger tensor arrays.
