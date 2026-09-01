# RV32 TinyLLM SoC — 실제 FPGA 구현 가능한 CPU 시스템

기존의 독립형 연산 RTL을 다음과 같은 완전한 CPU SoC로 확장한 프로젝트다.

- PicoRV32 기반 RV32I CPU
- 16 KiB 명령어·데이터 RAM
- MMIO 방식 signed INT8 / packed signed INT4 GEMV 가속기
- INT32 누산 및 결과
- UART 송신기와 ULX3S LED 8개
- RISC-V GCC로 컴파일되는 실제 펌웨어
- CPU가 펌웨어를 실행하는 Icarus Verilog 통합 시뮬레이션
- Verilator RTL lint
- Yosys ECP5 합성
- nextpnr-ecp5 배치·배선·정적 타이밍 분석
- ecppack 기반 ULX3S-85F 비트스트림 생성

펌웨어가 MMIO로 입력과 가중치를 기록하고 INT8 및 INT4 결과, MAC 수, 사이클 수를 검사한다. 성공하면 LED가 `0xA5`가 되고 UART에 `ALL TESTS PASS`를 출력한다. INT8 실패는 `0xE1`, INT4 실패는 `0xE4`다.

## 실제 보드 대상

- ULX3S v2.x/v3.0.x
- Lattice ECP5 `LFE5U-85F-6BG381C`
- 온보드 25 MHz 클럭
- FTDI UART 115200 8-N-1

## 빌드

```bash
make tool-versions
make lint
make sim
make bitstream
make manifest
make package
```

## 보드에 기록

```bash
fujprog build/rv32_llm_soc_ulx3s_85f.bit
# 또는
openFPGALoader -b ulx3s build/rv32_llm_soc_ulx3s_85f.bit
```

CI에는 물리 FPGA가 연결되어 있지 않으므로 실제 보드에서 LED를 확인했다는 주장은 하지 않는다. 대신 CPU 펌웨어 통합 시뮬레이션, FPGA 합성, 실제 디바이스 배치·배선, 타이밍 분석, 최종 `.bit` 생성까지 자동화한다.
