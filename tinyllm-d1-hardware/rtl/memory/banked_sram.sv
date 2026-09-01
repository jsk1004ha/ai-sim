`default_nettype none

// Power-of-two banked SRAM with one host write port and one aligned vector read port.
// Logical address mapping:
//   bank = logical_address % BANKS
//   row  = logical_address / BANKS
// A vector read must start at a BANKS-aligned logical address and returns one word
// from every bank in ascending bank order.
module banked_sram #(
    parameter integer DATA_W         = 8,
    parameter integer BANKS          = 8,
    parameter integer DEPTH_PER_BANK = 256,
    parameter integer LOG_ADDR_W     = 16,
    parameter integer BANK_BITS      = $clog2(BANKS),
    parameter integer BANK_ADDR_W    = $clog2(DEPTH_PER_BANK)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         host_wr_en,
    input  wire [LOG_ADDR_W-1:0]        host_wr_addr,
    input  wire [DATA_W-1:0]            host_wr_data,

    input  wire                         vec_rd_en,
    input  wire [LOG_ADDR_W-1:0]        vec_rd_base,
    output wire [BANKS*DATA_W-1:0]      vec_rd_data,
    output wire                         vec_rd_valid
);
    wire [BANK_BITS-1:0] host_bank = host_wr_addr[BANK_BITS-1:0];
    wire [BANK_ADDR_W-1:0] host_row = host_wr_addr[LOG_ADDR_W-1:BANK_BITS];
    wire [BANK_ADDR_W-1:0] read_row = vec_rd_base[LOG_ADDR_W-1:BANK_BITS];

    wire [BANKS-1:0] bank_rd_valid;

    genvar bank;
    generate
        for (bank = 0; bank < BANKS; bank = bank + 1) begin : GEN_BANKS
            wire [DATA_W-1:0] bank_rd_data;
            wire bank_wr_en = host_wr_en && (host_bank == bank);

            sdp_ram #(
                .DATA_W(DATA_W),
                .DEPTH(DEPTH_PER_BANK),
                .ADDR_W(BANK_ADDR_W)
            ) u_ram (
                .clk(clk),
                .rst_n(rst_n),
                .wr_en(bank_wr_en),
                .wr_addr(host_row),
                .wr_data(host_wr_data),
                .rd_en(vec_rd_en),
                .rd_addr(read_row),
                .rd_data(bank_rd_data),
                .rd_valid(bank_rd_valid[bank])
            );

            assign vec_rd_data[bank*DATA_W +: DATA_W] = bank_rd_data;
        end
    endgenerate

    assign vec_rd_valid = &bank_rd_valid;
endmodule

`default_nettype wire
