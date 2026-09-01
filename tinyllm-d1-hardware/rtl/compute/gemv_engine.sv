`timescale 1ns/1ps
`default_nettype none

// Command-configured matrix-vector engine.
//
// Supported weight formats:
//   precision_int4 = 0: signed INT8 weight elements
//   precision_int4 = 1: two signed INT4 weights packed per byte, low nibble first
//
// The activation vector is signed INT8. Accumulation and result are signed INT32
// with deterministic two's-complement wraparound.
//
// Memory layout requirements:
//   x_base       aligned to LANES activation elements
//   INT8 w_base  and w_stride aligned to LANES bytes
//   INT4 w_base  and w_stride aligned to LANES/2 packed bytes
module gemv_engine #(
    parameter integer LANES      = 8,
    parameter integer LOG_ADDR_W = 16,
    parameter integer RESULT_AW  = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         start,
    input  wire                         precision_int4,
    input  wire [15:0]                  cfg_m,
    input  wire [15:0]                  cfg_k,
    input  wire [LOG_ADDR_W-1:0]        cfg_x_base,
    input  wire [LOG_ADDR_W-1:0]        cfg_w_base,
    input  wire [RESULT_AW-1:0]         cfg_y_base,
    input  wire [15:0]                  cfg_w_stride,

    output wire                         busy,
    output reg                          done,

    output wire                         act_rd_en,
    output wire [LOG_ADDR_W-1:0]        act_rd_base,
    input  wire [LANES*8-1:0]           act_rd_data,
    input  wire                         act_rd_valid,

    output wire                         w8_rd_en,
    output wire [LOG_ADDR_W-1:0]        w8_rd_base,
    input  wire [LANES*8-1:0]           w8_rd_data,
    input  wire                         w8_rd_valid,

    output wire                         w4_rd_en,
    output wire [LOG_ADDR_W-1:0]        w4_rd_base,
    input  wire [(LANES/2)*8-1:0]       w4_rd_data,
    input  wire                         w4_rd_valid,

    output wire                         result_wr_en,
    output wire [RESULT_AW-1:0]         result_wr_addr,
    output wire [31:0]                  result_wr_data,

    output wire                         issue_pulse,
    output wire                         mac_pulse,
    output wire [15:0]                  macs_this_cycle,
    output wire                         result_pulse,
    output wire                         active_precision_int4
);
    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_ISSUE = 3'd1;
    localparam [2:0] ST_WAIT  = 3'd2;
    localparam [2:0] ST_MAC   = 3'd3;
    localparam [2:0] ST_WRITE = 3'd4;

    reg [2:0] state;
    reg precision_int4_q;
    reg [15:0] m_q;
    reg [15:0] k_q;
    reg [15:0] row_q;
    reg [15:0] k_offset_q;
    reg [LOG_ADDR_W-1:0] x_base_q;
    reg [LOG_ADDR_W-1:0] row_w_base_q;
    reg [RESULT_AW-1:0] row_y_addr_q;
    reg [15:0] w_stride_q;
    reg signed [31:0] accumulator_q;
    reg signed [31:0] final_result_q;

    // Select and sign-extend the weight before multiplication so INT8 and INT4
    // modes share one physical multiplier bank. The first synthesized version
    // placed a multiplier in each precision branch, doubling DSP use.
    integer select_lane;
    reg [LANES*8-1:0] selected_weight_bus;
    always @* begin
        selected_weight_bus = {(LANES*8){1'b0}};
        for (select_lane = 0; select_lane < LANES; select_lane = select_lane + 1) begin
            if (precision_int4_q) begin
                selected_weight_bus[select_lane*8 +: 8] = {
                    {4{w4_rd_data[(select_lane/2)*8 + (select_lane%2)*4 + 3]}},
                    w4_rd_data[(select_lane/2)*8 + (select_lane%2)*4 +: 4]
                };
            end else begin
                selected_weight_bus[select_lane*8 +: 8] =
                    w8_rd_data[select_lane*8 +: 8];
            end
        end
    end

    integer lane;
    reg signed [31:0] group_sum;
    always @* begin
        group_sum = 32'sd0;
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            if ((k_offset_q + lane) < k_q) begin
                group_sum = group_sum
                    + $signed(act_rd_data[lane*8 +: 8])
                    * $signed(selected_weight_bus[lane*8 +: 8]);
            end
        end
    end

    wire selected_weight_valid = precision_int4_q ? w4_rd_valid : w8_rd_valid;
    wire last_group = (k_offset_q + LANES) >= k_q;
    wire last_row   = (row_q + 16'd1) >= m_q;
    wire [15:0] remaining = k_q - k_offset_q;

    assign busy = (state != ST_IDLE);
    assign act_rd_en   = (state == ST_ISSUE);
    assign w8_rd_en    = (state == ST_ISSUE) && !precision_int4_q;
    assign w4_rd_en    = (state == ST_ISSUE) &&  precision_int4_q;

    assign act_rd_base = x_base_q + k_offset_q;
    assign w8_rd_base  = row_w_base_q + k_offset_q;
    assign w4_rd_base  = row_w_base_q + (k_offset_q >> 1);

    assign result_wr_en   = (state == ST_WRITE);
    assign result_wr_addr = row_y_addr_q;
    assign result_wr_data = final_result_q;

    assign issue_pulse = (state == ST_ISSUE);
    assign mac_pulse = (state == ST_MAC);
    assign result_pulse = (state == ST_WRITE);
    assign macs_this_cycle = (remaining >= LANES) ? LANES : remaining;
    assign active_precision_int4 = precision_int4_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            precision_int4_q  <= 1'b0;
            m_q               <= 16'd0;
            k_q               <= 16'd0;
            row_q             <= 16'd0;
            k_offset_q        <= 16'd0;
            x_base_q          <= {LOG_ADDR_W{1'b0}};
            row_w_base_q      <= {LOG_ADDR_W{1'b0}};
            row_y_addr_q      <= {RESULT_AW{1'b0}};
            w_stride_q        <= 16'd0;
            accumulator_q     <= 32'sd0;
            final_result_q    <= 32'sd0;
            done              <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        precision_int4_q <= precision_int4;
                        m_q              <= cfg_m;
                        k_q              <= cfg_k;
                        row_q            <= 16'd0;
                        k_offset_q       <= 16'd0;
                        x_base_q         <= cfg_x_base;
                        row_w_base_q     <= cfg_w_base;
                        row_y_addr_q     <= cfg_y_base;
                        w_stride_q       <= cfg_w_stride;
                        accumulator_q    <= 32'sd0;
                        state            <= ST_ISSUE;
                    end
                end

                ST_ISSUE: begin
                    state <= ST_WAIT;
                end

                ST_WAIT: begin
                    if (act_rd_valid && selected_weight_valid)
                        state <= ST_MAC;
                end

                ST_MAC: begin
                    if (last_group) begin
                        final_result_q <= accumulator_q + group_sum;
                        state          <= ST_WRITE;
                    end else begin
                        accumulator_q <= accumulator_q + group_sum;
                        k_offset_q    <= k_offset_q + LANES;
                        state         <= ST_ISSUE;
                    end
                end

                ST_WRITE: begin
                    if (last_row) begin
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        row_q         <= row_q + 16'd1;
                        k_offset_q    <= 16'd0;
                        row_w_base_q  <= row_w_base_q + w_stride_q;
                        row_y_addr_q  <= row_y_addr_q + 1'b1;
                        accumulator_q <= 32'sd0;
                        state         <= ST_ISSUE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
