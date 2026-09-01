# RV32 TinyLLM SoC memory map

| Address | Function |
|---|---|
| `0x0000_0000`–`0x0000_3fff` | 16 KiB instruction/data block RAM |
| `0x1000_0000` | Accelerator control: bit 0 start, bit 1 INT4 mode, bit 2 clear status |
| `0x1000_0004` | Accelerator status: bit 0 busy, bit 1 done, bit 2 error |
| `0x1000_0008` | Configuration: bits 7:0 M, bits 15:8 K |
| `0x1000_000c` | Accelerator active cycles |
| `0x1000_0010` | Executed MAC count |
| `0x1000_0020`–`0x1000_0027` | Eight signed INT8 activations |
| `0x1000_0040`–`0x1000_004f` | Sixteen signed INT8 weights |
| `0x1000_0060`–`0x1000_0067` | Sixteen packed signed INT4 weights |
| `0x1000_0080`–`0x1000_0087` | Two signed INT32 results |
| `0x2000_0000` | Eight board LEDs |
| `0x2000_0004` | UART transmit data |
| `0x2000_0008` | UART status bit 0 = ready |
