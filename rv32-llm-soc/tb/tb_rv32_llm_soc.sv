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
        .MEM_INIT_FILE("build/firmware.hex"),
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
                $display("FAIL: CPU trapped at cycle %0d, LED=%02x", cycles, led);
                $fatal(1);
            end
            if (led == 8'hA5) begin
                $display("PASS: RV32 firmware completed INT8 and INT4 accelerator tests at cycle %0d", cycles);
                $finish;
            end
            if ((led == 8'hE1) || (led == 8'hE4)) begin
                $display("FAIL: firmware reported accelerator error LED=%02x at cycle %0d", led, cycles);
                $fatal(1);
            end
        end
        $display("FAIL: timeout, LED=%02x", led);
        $fatal(1);
    end
endmodule
`default_nettype wire
