# Executed hardware flow

1. `riscv64-unknown-elf-gcc` compiles freestanding RV32I firmware.
2. Icarus Verilog executes the firmware on PicoRV32 and compares accelerator results through firmware self-tests.
3. Verilator performs structural/SystemVerilog lint.
4. Yosys `synth_ecp5` maps the CPU, block RAM, MMIO and INT8/INT4 accelerator to ECP5 primitives.
5. nextpnr-ecp5 performs packing, placement, routing and static timing analysis for `LFE5U-85F-6BG381C` at 25 MHz.
6. `ecppack` emits a directly programmable ULX3S `.bit` file.
7. `scripts/summarize.py` records hashes, tool versions, simulation status and physical implementation metrics.

CI does not have an attached FPGA, so board execution is intentionally not claimed. The generated bitstream is the final configuration artifact consumed by `fujprog` or `openFPGALoader` on an actual ULX3S-85F.
