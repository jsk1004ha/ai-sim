OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K
}
SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text*)
    } > RAM
    .rodata : { *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss*) *(.sbss*) *(COMMON)
        __bss_end = .;
    } > RAM
    . = ORIGIN(RAM) + LENGTH(RAM);
    _stack_top = .;
}
