`default_nettype none

// TinyLLM memory-mapped dot/GEMV accelerator.
// - Activations: signed INT8
// - Weights: signed INT8 or packed signed INT4
// - Accumulation/results: signed INT32 with two's-complement wraparound
// - Fixed storage capacity: M_MAX rows x K_MAX columns
// - Runtime-configurable M and K inside those limits
module mmio_llm_accel #(
    parameter integer M_MAX = 2,
    parameter integer K_MAX = 8,
    parameter integer LANES = 4
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        mmio_valid,
    input  wire [7:0]  mmio_addr,
    input  wire [31:0] mmio_wdata,
    input  wire [3:0]  mmio_wstrb,
    output reg  [31:0] mmio_rdata,
    output wire        irq,

    output wire        busy_o,
    output wire        done_o,
    output wire [31:0] cycle_count_o,
    output wire [31:0] mac_count_o
);
    localparam integer A_WORDS  = (K_MAX + 3) / 4;
    localparam integer W8_WORDS = (M_MAX*K_MAX + 3) / 4;
    localparam integer W4_WORDS = (M_MAX*K_MAX + 7) / 8;

    localparam [7:0] REG_CONTROL = 8'h00;
    localparam [7:0] REG_STATUS  = 8'h04;
    localparam [7:0] REG_CONFIG  = 8'h08;
    localparam [7:0] REG_CYCLES  = 8'h0c;
    localparam [7:0] REG_MACS    = 8'h10;
    localparam [7:0] REG_A_BASE  = 8'h20;
    localparam [7:0] REG_W8_BASE = 8'h40;
    localparam [7:0] REG_W4_BASE = 8'h60;
    localparam [7:0] REG_Y_BASE  = 8'h80;

    reg signed [7:0] activation [0:K_MAX-1];
    reg signed [7:0] weight_i8  [0:M_MAX*K_MAX-1];
    reg signed [3:0] weight_i4  [0:M_MAX*K_MAX-1];
    reg signed [31:0] result    [0:M_MAX-1];

    reg [7:0] cfg_m;
    reg [7:0] cfg_k;
    reg       mode_int4;
    reg       busy;
    reg       done;
    reg       error;
    reg [7:0] row_index;
    reg [7:0] k_index;
    reg signed [31:0] accumulator;
    reg [31:0] cycle_count;
    reg [31:0] mac_count;

    integer i;
    integer byte_index;
    integer nibble_index;
    integer selected_index;
    reg signed [31:0] group_sum;
    reg [7:0] active_lanes;

    wire write_enable = mmio_valid && (|mmio_wstrb);
    wire start_request = write_enable && (mmio_addr == REG_CONTROL) && mmio_wdata[0];
    wire clear_request = write_enable && (mmio_addr == REG_CONTROL) && mmio_wdata[2];
    wire final_group = (k_index + LANES) >= cfg_k;
    wire final_row   = (row_index + 1) >= cfg_m;

    always @* begin
        group_sum = 32'sd0;
        active_lanes = 8'd0;
        for (i = 0; i < LANES; i = i + 1) begin
            if ((k_index + i) < cfg_k) begin
                selected_index = row_index*K_MAX + k_index + i;
                if (mode_int4)
                    group_sum = group_sum + $signed(activation[k_index+i]) * $signed(weight_i4[selected_index]);
                else
                    group_sum = group_sum + $signed(activation[k_index+i]) * $signed(weight_i8[selected_index]);
                active_lanes = active_lanes + 1'b1;
            end
        end
    end

    always @* begin
        mmio_rdata = 32'h0000_0000;
        case (mmio_addr)
            REG_CONTROL: mmio_rdata = {29'd0, 1'b0, mode_int4, 1'b0};
            REG_STATUS:  mmio_rdata = {29'd0, error, done, busy};
            REG_CONFIG:  mmio_rdata = {16'd0, cfg_k, cfg_m};
            REG_CYCLES:  mmio_rdata = cycle_count;
            REG_MACS:    mmio_rdata = mac_count;
            default: begin
                if ((mmio_addr >= REG_Y_BASE) && (mmio_addr < REG_Y_BASE + M_MAX*4))
                    mmio_rdata = result[(mmio_addr-REG_Y_BASE) >> 2];
                else
                    mmio_rdata = 32'h0000_0000;
            end
        endcase
    end

    always @(posedge clk) begin
        if (!resetn) begin
            cfg_m       <= M_MAX;
            cfg_k       <= K_MAX;
            mode_int4   <= 1'b0;
            busy        <= 1'b0;
            done        <= 1'b0;
            error       <= 1'b0;
            row_index   <= 8'd0;
            k_index     <= 8'd0;
            accumulator <= 32'sd0;
            cycle_count <= 32'd0;
            mac_count   <= 32'd0;
            for (i = 0; i < K_MAX; i = i + 1)
                activation[i] <= 8'sd0;
            for (i = 0; i < M_MAX*K_MAX; i = i + 1) begin
                weight_i8[i] <= 8'sd0;
                weight_i4[i] <= 4'sd0;
            end
            for (i = 0; i < M_MAX; i = i + 1)
                result[i] <= 32'sd0;
        end else begin
            if (clear_request) begin
                done  <= 1'b0;
                error <= 1'b0;
            end

            if (write_enable && !busy) begin
                if (mmio_addr == REG_CONFIG) begin
                    cfg_m <= mmio_wdata[7:0];
                    cfg_k <= mmio_wdata[15:8];
                end

                if ((mmio_addr >= REG_A_BASE) && (mmio_addr < REG_A_BASE + A_WORDS*4)) begin
                    for (i = 0; i < 4; i = i + 1) begin
                        byte_index = ((mmio_addr-REG_A_BASE) >> 2)*4 + i;
                        if (mmio_wstrb[i] && (byte_index < K_MAX))
                            activation[byte_index] <= mmio_wdata[i*8 +: 8];
                    end
                end

                if ((mmio_addr >= REG_W8_BASE) && (mmio_addr < REG_W8_BASE + W8_WORDS*4)) begin
                    for (i = 0; i < 4; i = i + 1) begin
                        byte_index = ((mmio_addr-REG_W8_BASE) >> 2)*4 + i;
                        if (mmio_wstrb[i] && (byte_index < M_MAX*K_MAX))
                            weight_i8[byte_index] <= mmio_wdata[i*8 +: 8];
                    end
                end

                if ((mmio_addr >= REG_W4_BASE) && (mmio_addr < REG_W4_BASE + W4_WORDS*4)) begin
                    for (i = 0; i < 8; i = i + 1) begin
                        nibble_index = ((mmio_addr-REG_W4_BASE) >> 2)*8 + i;
                        if (mmio_wstrb[i/2] && (nibble_index < M_MAX*K_MAX))
                            weight_i4[nibble_index] <= mmio_wdata[i*4 +: 4];
                    end
                end
            end

            if (start_request && !busy) begin
                if ((cfg_m == 0) || (cfg_m > M_MAX) || (cfg_k == 0) || (cfg_k > K_MAX)) begin
                    error <= 1'b1;
                    done  <= 1'b1;
                end else begin
                    mode_int4   <= mmio_wdata[1];
                    busy        <= 1'b1;
                    done        <= 1'b0;
                    error       <= 1'b0;
                    row_index   <= 8'd0;
                    k_index     <= 8'd0;
                    accumulator <= 32'sd0;
                    cycle_count <= 32'd0;
                    mac_count   <= 32'd0;
                end
            end else if (busy) begin
                cycle_count <= cycle_count + 1'b1;
                mac_count   <= mac_count + active_lanes;
                if (final_group) begin
                    result[row_index] <= accumulator + group_sum;
                    if (final_row) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        row_index   <= row_index + 1'b1;
                        k_index     <= 8'd0;
                        accumulator <= 32'sd0;
                    end
                end else begin
                    k_index     <= k_index + LANES;
                    accumulator <= accumulator + group_sum;
                end
            end
        end
    end

    assign irq = done && !error;
    assign busy_o = busy;
    assign done_o = done;
    assign cycle_count_o = cycle_count;
    assign mac_count_o = mac_count;
endmodule

`default_nettype wire
