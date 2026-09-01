`default_nettype none

// TinyLLM-D1: a command-driven decode-oriented LLM arithmetic core.
//
// This top level is a complete synthesizable datapath from host-loaded on-chip
// SRAMs, through an INT8 / packed-INT4 GEMV engine, to a host-readable result
// SRAM. Command fields are consumed by hardware; they are not metadata-only.
module tinyllm_d1_core #(
    parameter integer LANES               = 8,
    parameter integer LOG_ADDR_W          = 16,
    parameter integer ACT_DEPTH_PER_BANK  = 256,
    parameter integer W8_DEPTH_PER_BANK   = 512,
    parameter integer W4_DEPTH_PER_BANK   = 512,
    parameter integer RESULT_DEPTH        = 256,
    parameter integer RESULT_AW           = $clog2(RESULT_DEPTH),
    parameter integer LANE_BITS           = $clog2(LANES),
    parameter integer W4_BANKS            = LANES / 2,
    parameter integer W4_BANK_BITS        = $clog2(W4_BANKS)
) (
    input  wire                      clk,
    input  wire                      rst_n,

    // One-request-at-a-time host port. Byte-addressed for activation/weight
    // spaces and word-addressed for result/CSR spaces.
    input  wire                      host_valid,
    input  wire                      host_write,
    input  wire [2:0]                host_space,
    input  wire [LOG_ADDR_W-1:0]     host_addr,
    input  wire [31:0]               host_wdata,
    input  wire [3:0]                host_wstrb,
    output wire                      host_ready,
    output reg  [31:0]               host_rdata,
    output reg                       host_rvalid,

    // 128-bit command interface.
    input  wire                      cmd_valid,
    input  wire [127:0]              cmd_data,
    output wire                      cmd_ready,

    // Completion channel. done_valid is held until done_ready.
    output reg                       done_valid,
    input  wire                      done_ready,
    output reg  [15:0]               done_tag,
    output reg  [7:0]                done_status,

    output wire                      busy,
    output wire                      irq_done
);
    localparam [2:0] SPACE_ACT    = 3'd0;
    localparam [2:0] SPACE_W8     = 3'd1;
    localparam [2:0] SPACE_W4     = 3'd2;
    localparam [2:0] SPACE_RESULT = 3'd3;
    localparam [2:0] SPACE_CSR    = 3'd4;

    localparam [7:0] OP_GEMV_I8   = 8'h01;
    localparam [7:0] OP_QGEMV_I4  = 8'h02;

    localparam [7:0] STATUS_OK             = 8'h00;
    localparam [7:0] ERR_BAD_OPCODE        = 8'h01;
    localparam [7:0] ERR_ZERO_DIMENSION    = 8'h02;
    localparam [7:0] ERR_X_ALIGNMENT       = 8'h03;
    localparam [7:0] ERR_W_ALIGNMENT       = 8'h04;
    localparam [7:0] ERR_X_RANGE           = 8'h05;
    localparam [7:0] ERR_W_RANGE           = 8'h06;
    localparam [7:0] ERR_Y_RANGE           = 8'h07;
    localparam [7:0] ERR_BAD_STRIDE        = 8'h08;

    localparam integer ACT_CAPACITY = LANES * ACT_DEPTH_PER_BANK;
    localparam integer W8_CAPACITY  = LANES * W8_DEPTH_PER_BANK;
    localparam integer W4_CAPACITY  = W4_BANKS * W4_DEPTH_PER_BANK;

    wire [7:0]  cmd_opcode   = cmd_data[127:120];
    wire [7:0]  cmd_flags    = cmd_data[119:112];
    wire [15:0] cmd_m        = cmd_data[111:96];
    wire [15:0] cmd_k        = cmd_data[95:80];
    wire [15:0] cmd_x_base   = cmd_data[79:64];
    wire [15:0] cmd_w_base   = cmd_data[63:48];
    wire [15:0] cmd_y_base   = cmd_data[47:32];
    wire [15:0] cmd_w_stride = cmd_data[31:16];
    wire [15:0] cmd_tag      = cmd_data[15:0];

    // The flags field is reserved for future saturation and fused-bias modes.
    wire unused_cmd_flags = |cmd_flags;

    wire opcode_is_i8 = (cmd_opcode == OP_GEMV_I8);
    wire opcode_is_i4 = (cmd_opcode == OP_QGEMV_I4);
    wire opcode_valid = opcode_is_i8 || opcode_is_i4;

    wire [31:0] k_groups = ({16'd0, cmd_k} + LANES - 1) >> LANE_BITS;
    wire [31:0] x_physical_bytes = k_groups * LANES;
    wire [31:0] i4_row_bytes = ({16'd0, cmd_k} + 32'd1) >> 1;
    wire [31:0] required_row_bytes = opcode_is_i4 ? i4_row_bytes : {16'd0, cmd_k};
    wire [31:0] physical_row_bytes = opcode_is_i4
                                    ? (k_groups * W4_BANKS)
                                    : (k_groups * LANES);
    wire [31:0] x_end = {16'd0, cmd_x_base} + x_physical_bytes;
    wire [31:0] y_end = {16'd0, cmd_y_base} + {16'd0, cmd_m};
    wire [31:0] row_span = (cmd_m > 0)
                         ? ({16'd0, cmd_m} - 32'd1) * {16'd0, cmd_w_stride}
                         : 32'd0;
    wire [31:0] w_end = {16'd0, cmd_w_base} + row_span + physical_row_bytes;

    reg [7:0] command_error;
    always @* begin
        command_error = STATUS_OK;
        if (!opcode_valid)
            command_error = ERR_BAD_OPCODE;
        else if ((cmd_m == 0) || (cmd_k == 0))
            command_error = ERR_ZERO_DIMENSION;
        else if (cmd_x_base[LANE_BITS-1:0] != {LANE_BITS{1'b0}})
            command_error = ERR_X_ALIGNMENT;
        else if (cmd_w_stride < required_row_bytes[15:0])
            command_error = ERR_BAD_STRIDE;
        else if (opcode_is_i8 &&
                 ((cmd_w_base[LANE_BITS-1:0] != {LANE_BITS{1'b0}}) ||
                  (cmd_w_stride[LANE_BITS-1:0] != {LANE_BITS{1'b0}})))
            command_error = ERR_W_ALIGNMENT;
        else if (opcode_is_i4 &&
                 ((cmd_w_base[W4_BANK_BITS-1:0] != {W4_BANK_BITS{1'b0}}) ||
                  (cmd_w_stride[W4_BANK_BITS-1:0] != {W4_BANK_BITS{1'b0}})))
            command_error = ERR_W_ALIGNMENT;
        else if (x_end > ACT_CAPACITY)
            command_error = ERR_X_RANGE;
        else if (y_end > RESULT_DEPTH)
            command_error = ERR_Y_RANGE;
        else if (opcode_is_i8 && (w_end > W8_CAPACITY))
            command_error = ERR_W_RANGE;
        else if (opcode_is_i4 && (w_end > W4_CAPACITY))
            command_error = ERR_W_RANGE;
    end

    reg engine_start;
    reg engine_precision_i4;
    reg [15:0] engine_m;
    reg [15:0] engine_k;
    reg [LOG_ADDR_W-1:0] engine_x_base;
    reg [LOG_ADDR_W-1:0] engine_w_base;
    reg [RESULT_AW-1:0] engine_y_base;
    reg [15:0] engine_w_stride;

    wire engine_busy;
    wire engine_done;

    wire act_rd_en;
    wire [LOG_ADDR_W-1:0] act_rd_base;
    wire [LANES*8-1:0] act_rd_data;
    wire act_rd_valid;

    wire w8_rd_en;
    wire [LOG_ADDR_W-1:0] w8_rd_base;
    wire [LANES*8-1:0] w8_rd_data;
    wire w8_rd_valid;

    wire w4_rd_en;
    wire [LOG_ADDR_W-1:0] w4_rd_base;
    wire [W4_BANKS*8-1:0] w4_rd_data;
    wire w4_rd_valid;

    wire engine_result_wr_en;
    wire [RESULT_AW-1:0] engine_result_wr_addr;
    wire [31:0] engine_result_wr_data;
    wire engine_issue_pulse;
    wire engine_mac_pulse;
    wire [15:0] engine_macs_this_cycle;
    wire engine_result_pulse;
    wire engine_active_precision_i4;

    assign busy = engine_start || engine_busy;
    assign irq_done = done_valid;
    assign cmd_ready = !busy && !done_valid;
    wire cmd_fire = cmd_valid && cmd_ready;

    // Host write acceptance is blocked while compute owns the scratchpads.
    reg [1:0] read_kind_q;
    localparam [1:0] READ_NONE   = 2'd0;
    localparam [1:0] READ_RESULT = 2'd1;
    localparam [1:0] READ_CSR    = 2'd2;

    wire host_is_mem_write = host_write &&
                           ((host_space == SPACE_ACT) ||
                            (host_space == SPACE_W8)  ||
                            (host_space == SPACE_W4));
    assign host_ready = (read_kind_q == READ_NONE) &&
                        (!host_is_mem_write || !busy);
    wire host_fire = host_valid && host_ready;

    wire act_host_we = host_fire && host_write &&
                       (host_space == SPACE_ACT) && host_wstrb[0];
    wire w8_host_we  = host_fire && host_write &&
                       (host_space == SPACE_W8) && host_wstrb[0];
    wire w4_host_we  = host_fire && host_write &&
                       (host_space == SPACE_W4) && host_wstrb[0];

    banked_sram #(
        .DATA_W(8),
        .BANKS(LANES),
        .DEPTH_PER_BANK(ACT_DEPTH_PER_BANK),
        .LOG_ADDR_W(LOG_ADDR_W)
    ) u_activation_sram (
        .clk(clk),
        .rst_n(rst_n),
        .host_wr_en(act_host_we),
        .host_wr_addr(host_addr),
        .host_wr_data(host_wdata[7:0]),
        .vec_rd_en(act_rd_en),
        .vec_rd_base(act_rd_base),
        .vec_rd_data(act_rd_data),
        .vec_rd_valid(act_rd_valid)
    );

    banked_sram #(
        .DATA_W(8),
        .BANKS(LANES),
        .DEPTH_PER_BANK(W8_DEPTH_PER_BANK),
        .LOG_ADDR_W(LOG_ADDR_W)
    ) u_int8_weight_sram (
        .clk(clk),
        .rst_n(rst_n),
        .host_wr_en(w8_host_we),
        .host_wr_addr(host_addr),
        .host_wr_data(host_wdata[7:0]),
        .vec_rd_en(w8_rd_en),
        .vec_rd_base(w8_rd_base),
        .vec_rd_data(w8_rd_data),
        .vec_rd_valid(w8_rd_valid)
    );

    banked_sram #(
        .DATA_W(8),
        .BANKS(W4_BANKS),
        .DEPTH_PER_BANK(W4_DEPTH_PER_BANK),
        .LOG_ADDR_W(LOG_ADDR_W)
    ) u_int4_weight_sram (
        .clk(clk),
        .rst_n(rst_n),
        .host_wr_en(w4_host_we),
        .host_wr_addr(host_addr),
        .host_wr_data(host_wdata[7:0]),
        .vec_rd_en(w4_rd_en),
        .vec_rd_base(w4_rd_base),
        .vec_rd_data(w4_rd_data),
        .vec_rd_valid(w4_rd_valid)
    );

    wire result_host_rd_en = host_fire && !host_write &&
                             (host_space == SPACE_RESULT);
    wire [RESULT_AW-1:0] result_host_rd_addr = host_addr[RESULT_AW-1:0];
    wire [31:0] result_host_rd_data;
    wire result_host_rd_valid;

    sdp_ram #(
        .DATA_W(32),
        .DEPTH(RESULT_DEPTH),
        .ADDR_W(RESULT_AW)
    ) u_result_sram (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(engine_result_wr_en),
        .wr_addr(engine_result_wr_addr),
        .wr_data(engine_result_wr_data),
        .rd_en(result_host_rd_en),
        .rd_addr(result_host_rd_addr),
        .rd_data(result_host_rd_data),
        .rd_valid(result_host_rd_valid)
    );

    gemv_engine #(
        .LANES(LANES),
        .LOG_ADDR_W(LOG_ADDR_W),
        .RESULT_AW(RESULT_AW)
    ) u_gemv_engine (
        .clk(clk),
        .rst_n(rst_n),
        .start(engine_start),
        .precision_int4(engine_precision_i4),
        .cfg_m(engine_m),
        .cfg_k(engine_k),
        .cfg_x_base(engine_x_base),
        .cfg_w_base(engine_w_base),
        .cfg_y_base(engine_y_base),
        .cfg_w_stride(engine_w_stride),
        .busy(engine_busy),
        .done(engine_done),
        .act_rd_en(act_rd_en),
        .act_rd_base(act_rd_base),
        .act_rd_data(act_rd_data),
        .act_rd_valid(act_rd_valid),
        .w8_rd_en(w8_rd_en),
        .w8_rd_base(w8_rd_base),
        .w8_rd_data(w8_rd_data),
        .w8_rd_valid(w8_rd_valid),
        .w4_rd_en(w4_rd_en),
        .w4_rd_base(w4_rd_base),
        .w4_rd_data(w4_rd_data),
        .w4_rd_valid(w4_rd_valid),
        .result_wr_en(engine_result_wr_en),
        .result_wr_addr(engine_result_wr_addr),
        .result_wr_data(engine_result_wr_data),
        .issue_pulse(engine_issue_pulse),
        .mac_pulse(engine_mac_pulse),
        .macs_this_cycle(engine_macs_this_cycle),
        .result_pulse(engine_result_pulse),
        .active_precision_int4(engine_active_precision_i4)
    );

    reg [7:0] last_error_q;
    reg [7:0] last_opcode_q;
    reg [63:0] total_cycles_q;
    reg [63:0] busy_cycles_q;
    reg [63:0] command_count_q;
    reg [63:0] mac_count_q;
    reg [63:0] activation_read_bytes_q;
    reg [63:0] weight_read_bytes_q;
    reg [63:0] result_write_bytes_q;

    reg [31:0] csr_read_latch_q;
    reg clear_counters_pulse;

    function [31:0] csr_read_mux;
        input [15:0] csr_addr;
        begin
            case (csr_addr)
                16'h0000: csr_read_mux = 32'h0001_0000;
                16'h0001: csr_read_mux = {8'd0, last_opcode_q, last_error_q,
                                           5'd0, done_valid, busy, 1'b0};
                16'h0002: csr_read_mux = total_cycles_q[31:0];
                16'h0003: csr_read_mux = total_cycles_q[63:32];
                16'h0004: csr_read_mux = busy_cycles_q[31:0];
                16'h0005: csr_read_mux = busy_cycles_q[63:32];
                16'h0006: csr_read_mux = command_count_q[31:0];
                16'h0007: csr_read_mux = command_count_q[63:32];
                16'h0008: csr_read_mux = mac_count_q[31:0];
                16'h0009: csr_read_mux = mac_count_q[63:32];
                16'h000A: csr_read_mux = activation_read_bytes_q[31:0];
                16'h000B: csr_read_mux = activation_read_bytes_q[63:32];
                16'h000C: csr_read_mux = weight_read_bytes_q[31:0];
                16'h000D: csr_read_mux = weight_read_bytes_q[63:32];
                16'h000E: csr_read_mux = result_write_bytes_q[31:0];
                16'h000F: csr_read_mux = result_write_bytes_q[63:32];
                16'h0010: csr_read_mux = ACT_CAPACITY;
                16'h0011: csr_read_mux = W8_CAPACITY;
                16'h0012: csr_read_mux = W4_CAPACITY;
                16'h0013: csr_read_mux = RESULT_DEPTH;
                16'h0014: csr_read_mux = LANES;
                default:  csr_read_mux = 32'h0000_0000;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            engine_start             <= 1'b0;
            engine_precision_i4      <= 1'b0;
            engine_m                 <= 16'd0;
            engine_k                 <= 16'd0;
            engine_x_base            <= {LOG_ADDR_W{1'b0}};
            engine_w_base            <= {LOG_ADDR_W{1'b0}};
            engine_y_base            <= {RESULT_AW{1'b0}};
            engine_w_stride          <= 16'd0;
            done_valid               <= 1'b0;
            done_tag                 <= 16'd0;
            done_status              <= STATUS_OK;
            last_error_q             <= STATUS_OK;
            last_opcode_q            <= 8'd0;
            total_cycles_q           <= 64'd0;
            busy_cycles_q            <= 64'd0;
            command_count_q          <= 64'd0;
            mac_count_q              <= 64'd0;
            activation_read_bytes_q  <= 64'd0;
            weight_read_bytes_q      <= 64'd0;
            result_write_bytes_q     <= 64'd0;
            read_kind_q              <= READ_NONE;
            csr_read_latch_q         <= 32'd0;
            host_rdata               <= 32'd0;
            host_rvalid              <= 1'b0;
            clear_counters_pulse     <= 1'b0;
        end else begin
            engine_start         <= 1'b0;
            host_rvalid          <= 1'b0;
            clear_counters_pulse <= 1'b0;

            if (done_valid && done_ready)
                done_valid <= 1'b0;

            if ((read_kind_q == READ_RESULT) && result_host_rd_valid) begin
                host_rdata  <= result_host_rd_data;
                host_rvalid <= 1'b1;
                read_kind_q <= READ_NONE;
            end else if (read_kind_q == READ_CSR) begin
                host_rdata  <= csr_read_latch_q;
                host_rvalid <= 1'b1;
                read_kind_q <= READ_NONE;
            end

            if (host_fire && !host_write) begin
                if (host_space == SPACE_RESULT) begin
                    read_kind_q <= READ_RESULT;
                end else begin
                    csr_read_latch_q <= (host_space == SPACE_CSR)
                                      ? csr_read_mux(host_addr)
                                      : 32'h0000_0000;
                    read_kind_q <= READ_CSR;
                end
            end

            if (host_fire && host_write && (host_space == SPACE_CSR) &&
                (host_addr == 16'h0000) && host_wstrb[0] && host_wdata[0]) begin
                clear_counters_pulse <= 1'b1;
                last_error_q <= STATUS_OK;
            end

            if (cmd_fire) begin
                command_count_q <= command_count_q + 64'd1;
                done_tag        <= cmd_tag;
                done_status     <= command_error;
                last_error_q    <= command_error;
                last_opcode_q   <= cmd_opcode;

                if (command_error != STATUS_OK) begin
                    done_valid <= 1'b1;
                end else begin
                    engine_precision_i4 <= opcode_is_i4;
                    engine_m            <= cmd_m;
                    engine_k            <= cmd_k;
                    engine_x_base       <= cmd_x_base;
                    engine_w_base       <= cmd_w_base;
                    engine_y_base       <= cmd_y_base[RESULT_AW-1:0];
                    engine_w_stride     <= cmd_w_stride;
                    engine_start        <= 1'b1;
                end
            end

            if (engine_done) begin
                done_valid   <= 1'b1;
                done_status  <= STATUS_OK;
                last_error_q <= STATUS_OK;
            end

            if (clear_counters_pulse) begin
                total_cycles_q          <= 64'd0;
                busy_cycles_q           <= 64'd0;
                command_count_q         <= 64'd0;
                mac_count_q             <= 64'd0;
                activation_read_bytes_q <= 64'd0;
                weight_read_bytes_q     <= 64'd0;
                result_write_bytes_q    <= 64'd0;
            end else begin
                total_cycles_q <= total_cycles_q + 64'd1;
                if (busy)
                    busy_cycles_q <= busy_cycles_q + 64'd1;
                if (engine_mac_pulse)
                    mac_count_q <= mac_count_q + engine_macs_this_cycle;
                if (engine_issue_pulse) begin
                    activation_read_bytes_q <= activation_read_bytes_q + LANES;
                    weight_read_bytes_q <= weight_read_bytes_q
                                         + (engine_active_precision_i4 ? W4_BANKS : LANES);
                end
                if (engine_result_pulse)
                    result_write_bytes_q <= result_write_bytes_q + 64'd4;
            end
        end
    end
endmodule

`default_nettype wire
