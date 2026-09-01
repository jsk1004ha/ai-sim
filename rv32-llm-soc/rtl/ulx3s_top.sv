`default_nettype none
module ulx3s_top (
    input  wire       clk_25mhz,
    output wire [7:0] led,
    output wire       ftdi_rxd
);
    reg [7:0] por_count = 8'd0;
    wire resetn = &por_count;
    wire cpu_trap;
    wire accel_busy;
    wire accel_done;
    wire [7:0] soc_led;

    always @(posedge clk_25mhz) begin
        if (!resetn)
            por_count <= por_count + 1'b1;
    end

    rv32_llm_soc #(
        .MEM_WORDS(4096),
        .MEM_INIT_FILE("build/firmware.hex"),
        .CLK_HZ(25_000_000)
    ) soc (
        .clk(clk_25mhz),
        .resetn(resetn),
        .led(soc_led),
        .uart_txd(ftdi_rxd),
        .cpu_trap(cpu_trap),
        .accel_busy(accel_busy),
        .accel_done(accel_done)
    );

    assign led = cpu_trap ? (soc_led | 8'hF0) : soc_led;
endmodule
`default_nettype wire
