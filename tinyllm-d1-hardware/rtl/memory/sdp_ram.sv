`default_nettype none

// Simple synchronous 1-read/1-write RAM.
// Read-during-write to the same address returns the old value (read-first behavior
// with nonblocking assignments in simulation). The memory contents are intentionally
// not reset so FPGA/ASIC SRAM inference remains possible.
module sdp_ram #(
    parameter integer DATA_W = 8,
    parameter integer DEPTH  = 256,
    parameter integer ADDR_W = $clog2(DEPTH)
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  wr_en,
    input  wire [ADDR_W-1:0]     wr_addr,
    input  wire [DATA_W-1:0]     wr_data,

    input  wire                  rd_en,
    input  wire [ADDR_W-1:0]     rd_addr,
    output reg  [DATA_W-1:0]     rd_data,
    output reg                   rd_valid
);
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
            rd_data  <= {DATA_W{1'b0}};
        end else begin
            rd_valid <= rd_en;
            if (wr_en)
                mem[wr_addr] <= wr_data;
            if (rd_en)
                rd_data <= mem[rd_addr];
        end
    end
endmodule

`default_nettype wire
