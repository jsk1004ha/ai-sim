.section .text
.align 2
.globl rv32i_selftest
.type rv32i_selftest, @function

// Returns 0 on success. A non-zero return value identifies the first failed
// architectural group. This code deliberately uses the RV32I instructions it
// is validating rather than relying only on compiler-generated coverage.
rv32i_selftest:
    li      a0, 1
    addi    zero, zero, 1
    bne     zero, zero, .Lfail
    lui     t0, 0x12345
    li      t1, 0x12345000
    bne     t0, t1, .Lfail

    li      a0, 2
    auipc   t0, 0
    addi    t0, t0, 12
    jal     t1, .Ljal_target
.Ljal_target:
    bne     t0, t1, .Lfail

    li      a0, 3
    la      t0, .Ljalr_target
    jalr    t1, 0(t0)
.Ljalr_return:
    j       .Lfail
.Ljalr_target:
    la      t2, .Ljalr_return
    bne     t1, t2, .Lfail

    li      a0, 4
    li      t0, -1
    li      t1, 1
    beq     t0, t1, .Lfail
    bne     t0, t1, .Lbne_ok
    j       .Lfail
.Lbne_ok:
    blt     t0, t1, .Lblt_ok
    j       .Lfail
.Lblt_ok:
    bge     t1, t0, .Lbge_ok
    j       .Lfail
.Lbge_ok:
    bltu    t1, t0, .Lbltu_ok
    j       .Lfail
.Lbltu_ok:
    bgeu    t0, t1, .Lbgeu_ok
    j       .Lfail
.Lbgeu_ok:

    li      a0, 5
    li      t0, 7
    li      t1, -3
    add     t2, t0, t1
    li      t3, 4
    bne     t2, t3, .Lfail
    sub     t2, t0, t1
    li      t3, 10
    bne     t2, t3, .Lfail
    slt     t2, t1, t0
    li      t3, 1
    bne     t2, t3, .Lfail
    sltu    t2, t1, t0
    bne     t2, zero, .Lfail

    li      a0, 6
    li      t0, 1
    li      t1, 3
    sll     t2, t0, t1
    li      t3, 8
    bne     t2, t3, .Lfail
    li      t0, 0x80000000
    li      t1, 1
    srl     t2, t0, t1
    li      t3, 0x40000000
    bne     t2, t3, .Lfail
    sra     t2, t0, t1
    li      t3, 0xc0000000
    bne     t2, t3, .Lfail
    li      t0, 0x55
    li      t1, 0x0f
    xor     t2, t0, t1
    li      t3, 0x5a
    bne     t2, t3, .Lfail
    or      t2, t0, t1
    li      t3, 0x5f
    bne     t2, t3, .Lfail
    and     t2, t0, t1
    li      t3, 0x05
    bne     t2, t3, .Lfail

    li      a0, 7
    li      t0, 7
    addi    t2, t0, -3
    li      t3, 4
    bne     t2, t3, .Lfail
    slti    t2, t0, 8
    li      t3, 1
    bne     t2, t3, .Lfail
    sltiu   t2, t0, -1
    bne     t2, t3, .Lfail
    li      t0, 1
    slli    t2, t0, 5
    li      t3, 32
    bne     t2, t3, .Lfail
    li      t0, 0x80000000
    srli    t2, t0, 4
    li      t3, 0x08000000
    bne     t2, t3, .Lfail
    srai    t2, t0, 4
    li      t3, 0xf8000000
    bne     t2, t3, .Lfail
    li      t0, 0x55
    xori    t2, t0, -1
    li      t3, 0xffffffaa
    bne     t2, t3, .Lfail
    ori     t2, t0, 0x0f
    li      t3, 0x5f
    bne     t2, t3, .Lfail
    andi    t2, t0, 0x0f
    li      t3, 0x05
    bne     t2, t3, .Lfail

    li      a0, 8
    la      t0, rv32i_test_scratch
    li      t1, 0xa1b2c3d4
    sw      t1, 0(t0)
    lw      t2, 0(t0)
    bne     t2, t1, .Lfail
    lb      t2, 0(t0)
    li      t3, -44
    bne     t2, t3, .Lfail
    lbu     t2, 0(t0)
    li      t3, 212
    bne     t2, t3, .Lfail
    lh      t2, 0(t0)
    li      t3, -15404
    bne     t2, t3, .Lfail
    lhu     t2, 0(t0)
    li      t3, 50132
    bne     t2, t3, .Lfail
    lb      t2, 3(t0)
    li      t3, -95
    bne     t2, t3, .Lfail

    li      t1, 0x11223344
    sb      t1, 1(t0)
    lbu     t2, 1(t0)
    li      t3, 0x44
    bne     t2, t3, .Lfail
    sh      t1, 2(t0)
    lhu     t2, 2(t0)
    li      t3, 0x3344
    bne     t2, t3, .Lfail
    lw      t2, 0(t0)
    li      t3, 0x334444d4
    bne     t2, t3, .Lfail

    li      a0, 9
    fence

    li      a0, 0
    ret

.Lfail:
    ret
.size rv32i_selftest, .-rv32i_selftest

.section .bss
.align 2
rv32i_test_scratch:
    .space 8
