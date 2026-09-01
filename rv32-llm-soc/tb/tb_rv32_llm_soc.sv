`timescale 1ns/1ps
`default_nettype none
module tb_rv32_llm_soc;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    wire [7:0] led;
    wire uart_txd;
    wire cpu_trap;
    wire accel_busy;
    wire accel_done;

    always #5 clk = ~clk;

    rv32_llm_soc #(
        .MEM_WORDS(4096),
        .MEM_INIT0_FILE("build/firmware_lane0.hex"),
        .MEM_INIT1_FILE("build/firmware_lane1.hex"),
        .MEM_INIT2_FILE("build/firmware_lane2.hex"),
        .MEM_INIT3_FILE("build/firmware_lane3.hex"),
        .CLK_HZ(1_000_000)
    ) dut (
        .clk(clk), .resetn(resetn), .led(led), .uart_txd(uart_txd),
        .cpu_trap(cpu_trap), .accel_busy(accel_busy), .accel_done(accel_done)
    );

    integer cycles;
    initial begin
        $dumpfile("build/rv32_llm_soc.vcd");
        $dumpvars(0, tb_rv32_llm_soc);
        repeat (10) @(posedge clk);
        resetn <= 1'b1;
        for (cycles = 0; cycles < 2_000_000; cycles = cycles + 1) begin
            @(posedge clk);
            if (cpu_trap) begin
                $display("FAIL: APZN CPU trapped at cycle %0d PC=%08x INSN=%08x LED=%02x",
                         cycles, dut.cpu_debug_pc, dut.cpu_debug_insn, led);
                $fatal(1);
            end
            if (led == 8'hA5) begin
                $display("PASS: APZN RV32I core completed ISA, INT8 and INT4 accelerator tests at cycle %0d retired=%0d",
                         cycles, dut.cpu_retired_count);
                $finish;
            end
            if (led[7:4] == 4'hC) begin
                $display("FAIL: APZN RV32I directed ISA self-test group %0d failed at cycle %0d",
                         led[3:0], cycles);
                $fatal(1);
            end
            if ((led == 8'hE1) || (led == 8'hE4)) begin
                $display("FAIL: firmware reported accelerator error LED=%02x at cycle %0d", led, cycles);
                $fatal(1);
            end
        end
        $display("FAIL: timeout, LED=%02x PC=%08x INSN=%08x retired=%0d",
                 led, dut.cpu_debug_pc, dut.cpu_debug_insn, dut.cpu_retired_count);
        $fatal(1);
    end
endmodule
`default_nettype wire
