`default_nettype none
module rv32_llm_soc #(
    parameter integer MEM_WORDS = 4096,
    parameter MEM_INIT0_FILE = "build/firmware_lane0.hex",
    parameter MEM_INIT1_FILE = "build/firmware_lane1.hex",
    parameter MEM_INIT2_FILE = "build/firmware_lane2.hex",
    parameter MEM_INIT3_FILE = "build/firmware_lane3.hex",
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
    localparam integer MEM_AW = $clog2(MEM_WORDS);
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
    wire [31:0] mem_rdata;

    wire [31:0] cpu_cycle_count;
    wire [31:0] cpu_retired_count;
    wire [31:0] cpu_debug_pc;
    wire [31:0] cpu_debug_insn;

    reg [31:0] peripheral_rdata;
    reg [7:0] led_reg;
    reg uart_valid;
    reg [7:0] uart_data_reg;
    wire uart_ready;

    wire ram_sel = (mem_addr < MEM_BYTES);
    wire bus_accept = mem_valid && !mem_ready;
    wire ram_accept = bus_accept && ram_sel;
    wire ram_read_en = ram_accept && !(|mem_wstrb);
    wire ram_write_en = ram_accept && (|mem_wstrb);
    wire [31:0] ram_rdata;

    wire accel_sel = (mem_addr[31:8] == ACCEL_BASE[31:8]);
    wire accel_write = bus_accept && accel_sel && (|mem_wstrb);
    wire accel_read  = bus_accept && accel_sel && !(|mem_wstrb);
    wire [31:0] accel_rdata;
    wire accel_irq;
    wire [31:0] accel_cycles;
    wire [31:0] accel_macs;

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

    soc_bram32 #(
        .WORDS(MEM_WORDS),
        .INIT0_FILE(MEM_INIT0_FILE),
        .INIT1_FILE(MEM_INIT1_FILE),
        .INIT2_FILE(MEM_INIT2_FILE),
        .INIT3_FILE(MEM_INIT3_FILE)
    ) system_memory (
        .clk(clk),
        .read_en(ram_read_en),
        .write_en(ram_write_en),
        .word_addr(mem_addr[MEM_AW+1:2]),
        .write_data(mem_wdata),
        .write_strobe(mem_wstrb),
        .read_data(ram_rdata)
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
            peripheral_rdata <= 32'd0;
            led_reg <= 8'd0;
            uart_valid <= 1'b0;
            uart_data_reg <= 8'd0;
        end else begin
            mem_ready <= 1'b0;
            uart_valid <= 1'b0;

            if (bus_accept) begin
                if (ram_sel) begin
                    mem_ready <= 1'b1;
                end else if (accel_sel) begin
                    mem_ready <= 1'b1;
                    peripheral_rdata <= accel_rdata;
                end else if (mem_addr == LED_ADDR) begin
                    mem_ready <= 1'b1;
                    peripheral_rdata <= {24'd0, led_reg};
                    if (|mem_wstrb)
                        led_reg <= mem_wdata[7:0];
                end else if (mem_addr == UART_STAT) begin
                    mem_ready <= 1'b1;
                    peripheral_rdata <= {31'd0, uart_ready};
                end else if (mem_addr == UART_DATA) begin
                    if (!(|mem_wstrb) || uart_ready) begin
                        mem_ready <= 1'b1;
                        peripheral_rdata <= 32'd0;
                        if (|mem_wstrb) begin
                            uart_data_reg <= mem_wdata[7:0];
                            uart_valid <= 1'b1;
                        end
                    end
                end else begin
                    mem_ready <= 1'b1;
                    peripheral_rdata <= 32'hBAD0_0000;
                end
            end
        end
    end

    assign mem_rdata = ram_sel ? ram_rdata : peripheral_rdata;
    assign led = led_reg;
endmodule
`default_nettype wire
