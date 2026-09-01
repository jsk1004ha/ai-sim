`default_nettype none

// 32-bit, byte-write-enable, single-clock block RAM built from four independent
// 8-bit lanes. The lane organization matches ECP5 DP16KD inference templates
// while preserving RV32I byte/halfword/word stores.
module soc_bram32 #(
    parameter integer WORDS = 4096,
    parameter INIT0_FILE = "build/firmware_lane0.hex",
    parameter INIT1_FILE = "build/firmware_lane1.hex",
    parameter INIT2_FILE = "build/firmware_lane2.hex",
    parameter INIT3_FILE = "build/firmware_lane3.hex"
) (
    input  wire                       clk,
    input  wire                       read_en,
    input  wire                       write_en,
    input  wire [$clog2(WORDS)-1:0]   word_addr,
    input  wire [31:0]                write_data,
    input  wire [3:0]                 write_strobe,
    output wire [31:0]                read_data
);
    (* ram_style = "block" *) reg [7:0] lane0 [0:WORDS-1];
    (* ram_style = "block" *) reg [7:0] lane1 [0:WORDS-1];
    (* ram_style = "block" *) reg [7:0] lane2 [0:WORDS-1];
    (* ram_style = "block" *) reg [7:0] lane3 [0:WORDS-1];

    reg [7:0] read_lane0;
    reg [7:0] read_lane1;
    reg [7:0] read_lane2;
    reg [7:0] read_lane3;

    initial begin
        $readmemh(INIT0_FILE, lane0);
        $readmemh(INIT1_FILE, lane1);
        $readmemh(INIT2_FILE, lane2);
        $readmemh(INIT3_FILE, lane3);
    end

    always @(posedge clk) begin
        if (read_en)
            read_lane0 <= lane0[word_addr];
        if (write_en && write_strobe[0])
            lane0[word_addr] <= write_data[7:0];
    end

    always @(posedge clk) begin
        if (read_en)
            read_lane1 <= lane1[word_addr];
        if (write_en && write_strobe[1])
            lane1[word_addr] <= write_data[15:8];
    end

    always @(posedge clk) begin
        if (read_en)
            read_lane2 <= lane2[word_addr];
        if (write_en && write_strobe[2])
            lane2[word_addr] <= write_data[23:16];
    end

    always @(posedge clk) begin
        if (read_en)
            read_lane3 <= lane3[word_addr];
        if (write_en && write_strobe[3])
            lane3[word_addr] <= write_data[31:24];
    end

    assign read_data = {read_lane3, read_lane2, read_lane1, read_lane0};
endmodule

`default_nettype wire
