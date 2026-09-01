`default_nettype none
module rv32_llm_soc #(
    parameter integer MEM_WORDS = 4096,
    parameter         MEM_INIT_FILE = "build/firmware.hex",
    parameter integer CLK_HZ = 25_000_000
) (
    input  wire       clk,
    input  wire       resetn,
    output wire [7:0] led,
    output wire       uart_txd,
    output wire       cpu_trap,
    output wire       accel_busy,
    output wire       accel_done
);
    localparam integer MEM_BYTES = MEM_WORDS*4;
    localparam [31:0] ACCEL_BASE = 32'h1000_0000;
    localparam [31:0] LED_ADDR   = 32'h2000_0000;
    localparam [31:0] UART_DATA  = 32'h2000_0004;
    localparam [31:0] UART_STAT  = 32'h2000_0008;

    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    wire [31:0] cpu_cycle_count;
    wire [31:0] cpu_retired_count;
    wire [31:0] cpu_debug_pc;
    wire [31:0] cpu_debug_insn;

    // Force the 16 KiB firmware/data store into ECP5 DP16KD block RAM rather
    // than spending tens of thousands of LUTs on distributed memory.
    (* ram_style = "block" *) reg [31:0] memory [0:MEM_WORDS-1];
    reg [7:0] led_reg;
    reg uart_valid;
    reg [7:0] uart_data_reg;
    wire uart_ready;

    wire accel_sel = (mem_addr[31:8] == ACCEL_BASE[31:8]);
    wire accel_write = mem_valid && !mem_ready && accel_sel && (|mem_wstrb);
    wire accel_read  = mem_valid && !mem_ready && accel_sel && !(|mem_wstrb);
    wire [31:0] accel_rdata;
    wire accel_irq;
    wire [31:0] accel_cycles;
    wire [31:0] accel_macs;

    integer i;
    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1)
            memory[i] = 32'h0000_0013;
        $readmemh(MEM_INIT_FILE, memory);
    end

    // Project-owned CPU. PicoRV32 and every other external CPU core have been
    // removed from this SoC integration.
    apzn_rv32i_core #(
        .RESET_PC(32'h0000_0000)
    ) cpu (
        .clk(clk),
        .resetn(resetn),
        .trap(cpu_trap),
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .cycle_count(cpu_cycle_count),
        .retired_count(cpu_retired_count),
        .debug_pc(cpu_debug_pc),
        .debug_insn(cpu_debug_insn)
    );

    mmio_llm_accel #(
        .M_MAX(2),
        .K_MAX(8),
        .LANES(4)
    ) accel (
        .clk(clk),
        .resetn(resetn),
        .mmio_valid(accel_write || accel_read),
        .mmio_addr(mem_addr[7:0]),
        .mmio_wdata(mem_wdata),
        .mmio_wstrb(mem_wstrb),
        .mmio_rdata(accel_rdata),
        .irq(accel_irq),
        .busy_o(accel_busy),
        .done_o(accel_done),
        .cycle_count_o(accel_cycles),
        .mac_count_o(accel_macs)
    );

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(115200)) uart (
        .clk(clk), .resetn(resetn),
        .valid(uart_valid), .data(uart_data_reg),
        .ready(uart_ready), .tx(uart_txd)
    );

    always @(posedge clk) begin
        if (!resetn) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
            led_reg <= 8'd0;
            uart_valid <= 1'b0;
            uart_data_reg <= 8'd0;
        end else begin
            mem_ready <= 1'b0;
            uart_valid <= 1'b0;

            if (mem_valid && !mem_ready) begin
                if (mem_addr < MEM_BYTES) begin
                    mem_ready <= 1'b1;
                    mem_rdata <= memory[mem_addr[$clog2(MEM_BYTES)-1:2]];
                    if (mem_wstrb[0]) memory[mem_addr[$clog2(MEM_BYTES)-1:2]][7:0]   <= mem_wdata[7:0];
                    if (mem_wstrb[1]) memory[mem_addr[$clog2(MEM_BYTES)-1:2]][15:8]  <= mem_wdata[15:8];
                    if (mem_wstrb[2]) memory[mem_addr[$clog2(MEM_BYTES)-1:2]][23:16] <= mem_wdata[23:16];
                    if (mem_wstrb[3]) memory[mem_addr[$clog2(MEM_BYTES)-1:2]][31:24] <= mem_wdata[31:24];
                end else if (accel_sel) begin
                    mem_ready <= 1'b1;
                    mem_rdata <= accel_rdata;
                end else if (mem_addr == LED_ADDR) begin
                    mem_ready <= 1'b1;
                    mem_rdata <= {24'd0, led_reg};
                    if (|mem_wstrb)
                        led_reg <= mem_wdata[7:0];
                end else if (mem_addr == UART_STAT) begin
                    mem_ready <= 1'b1;
                    mem_rdata <= {31'd0, uart_ready};
                end else if (mem_addr == UART_DATA) begin
                    if (!(|mem_wstrb) || uart_ready) begin
                        mem_ready <= 1'b1;
                        mem_rdata <= 32'd0;
                        if (|mem_wstrb) begin
                            uart_data_reg <= mem_wdata[7:0];
                            uart_valid <= 1'b1;
                        end
                    end
                end else begin
                    mem_ready <= 1'b1;
                    mem_rdata <= 32'hBAD0_0000;
                end
            end
        end
    end

    assign led = led_reg;
endmodule
`default_nettype wire
