`default_nettype none
module uart_tx #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       resetn,
    input  wire       valid,
    input  wire [7:0] data,
    output wire       ready,
    output wire       tx
);
    localparam integer DIVISOR = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer DIV_W = $clog2(DIVISOR);

    reg [9:0] shift_reg;
    reg [3:0] bit_count;
    reg [DIV_W-1:0] baud_count;
    reg busy;

    assign ready = !busy;
    assign tx = busy ? shift_reg[0] : 1'b1;

    always @(posedge clk) begin
        if (!resetn) begin
            shift_reg <= 10'h3ff;
            bit_count <= 4'd0;
            baud_count <= {DIV_W{1'b0}};
            busy <= 1'b0;
        end else begin
            if (valid && !busy) begin
                shift_reg <= {1'b1, data, 1'b0};
                bit_count <= 4'd10;
                baud_count <= DIVISOR-1;
                busy <= 1'b1;
            end else if (busy) begin
                if (baud_count == 0) begin
                    shift_reg <= {1'b1, shift_reg[9:1]};
                    baud_count <= DIVISOR-1;
                    bit_count <= bit_count - 1'b1;
                    if (bit_count == 1)
                        busy <= 1'b0;
                end else begin
                    baud_count <= baud_count - 1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
