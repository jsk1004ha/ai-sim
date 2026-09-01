#include <stdint.h>

#define MMIO32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))
#define ACCEL_BASE   0x10000000u
#define LED_REG      0x20000000u
#define UART_DATA    0x20000004u
#define UART_STATUS  0x20000008u

#define ACC_CONTROL  MMIO32(ACCEL_BASE + 0x00u)
#define ACC_STATUS   MMIO32(ACCEL_BASE + 0x04u)
#define ACC_CONFIG   MMIO32(ACCEL_BASE + 0x08u)
#define ACC_CYCLES   MMIO32(ACCEL_BASE + 0x0cu)
#define ACC_MACS     MMIO32(ACCEL_BASE + 0x10u)
#define ACC_A(i)     MMIO32(ACCEL_BASE + 0x20u + 4u*(i))
#define ACC_W8(i)    MMIO32(ACCEL_BASE + 0x40u + 4u*(i))
#define ACC_W4(i)    MMIO32(ACCEL_BASE + 0x60u + 4u*(i))
#define ACC_Y(i)     MMIO32(ACCEL_BASE + 0x80u + 4u*(i))

static void uart_putc(char c) {
    while ((MMIO32(UART_STATUS) & 1u) == 0u) { }
    MMIO32(UART_DATA) = (uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s != '\0') uart_putc(*s++);
}

static uint32_t pack4(int8_t a, int8_t b, int8_t c, int8_t d) {
    return ((uint32_t)(uint8_t)a) |
           ((uint32_t)(uint8_t)b << 8) |
           ((uint32_t)(uint8_t)c << 16) |
           ((uint32_t)(uint8_t)d << 24);
}

static uint32_t pack8_nibbles(int8_t a0, int8_t a1, int8_t a2, int8_t a3,
                              int8_t a4, int8_t a5, int8_t a6, int8_t a7) {
    return ((uint32_t)a0 & 0xfu) |
           (((uint32_t)a1 & 0xfu) << 4) |
           (((uint32_t)a2 & 0xfu) << 8) |
           (((uint32_t)a3 & 0xfu) << 12) |
           (((uint32_t)a4 & 0xfu) << 16) |
           (((uint32_t)a5 & 0xfu) << 20) |
           (((uint32_t)a6 & 0xfu) << 24) |
           (((uint32_t)a7 & 0xfu) << 28);
}

static int wait_accel(void) {
    for (uint32_t timeout = 0; timeout < 100000u; ++timeout) {
        uint32_t status = ACC_STATUS;
        if (status & 2u)
            return (status & 4u) ? -1 : 0;
    }
    return -2;
}

static int test_int8(void) {
    ACC_CONTROL = 4u;
    ACC_CONFIG = (8u << 8) | 2u;
    ACC_A(0) = pack4(3, -2, 5, 1);
    ACC_A(1) = pack4(-4, 7, 2, -1);

    ACC_W8(0) = pack4(1, 2, -3, 4);
    ACC_W8(1) = pack4(2, -1, 5, 3);
    ACC_W8(2) = pack4(-2, 1, 1, -1);
    ACC_W8(3) = pack4(3, 2, -4, 5);

    ACC_CONTROL = 1u;
    if (wait_accel() != 0) return -1;
    if ((int32_t)ACC_Y(0) != -20) return -2;
    if ((int32_t)ACC_Y(1) != -15) return -3;
    if (ACC_MACS != 16u) return -4;
    if (ACC_CYCLES != 4u) return -5;
    return 0;
}

static int test_int4(void) {
    ACC_CONTROL = 4u;
    ACC_CONFIG = (8u << 8) | 2u;
    ACC_A(0) = pack4(3, -2, 5, 1);
    ACC_A(1) = pack4(-4, 7, 2, -1);

    ACC_W4(0) = pack8_nibbles(-8, -7, -6, -5, -4, -3, -2, -1);
    ACC_W4(1) = pack8_nibbles(0, 1, 2, 3, 4, 5, 6, 7);

    ACC_CONTROL = 3u;
    if (wait_accel() != 0) return -1;
    if ((int32_t)ACC_Y(0) != -53) return -2;
    if ((int32_t)ACC_Y(1) != 35) return -3;
    if (ACC_MACS != 16u) return -4;
    if (ACC_CYCLES != 4u) return -5;
    return 0;
}

int main(void) {
    MMIO32(LED_REG) = 0x01u;
    uart_puts("RV32 TinyLLM SoC boot\r\n");

    int r8 = test_int8();
    if (r8 != 0) {
        MMIO32(LED_REG) = 0xE1u;
        uart_puts("INT8 FAIL\r\n");
        for (;;) { }
    }
    MMIO32(LED_REG) = 0x18u;
    uart_puts("INT8 PASS\r\n");

    int r4 = test_int4();
    if (r4 != 0) {
        MMIO32(LED_REG) = 0xE4u;
        uart_puts("INT4 FAIL\r\n");
        for (;;) { }
    }

    MMIO32(LED_REG) = 0xA5u;
    uart_puts("INT4 PASS - ALL TESTS PASS\r\n");
    for (;;) { }
}
