`default_nettype none

// APZN-RV32I-MC1
// ----------------
// A clean-room, non-pipelined RV32I CPU core designed for small FPGA SoCs.
//
// Microarchitecture:
//   * one architectural instruction in flight
//   * four control states: FETCH, EXECUTE, MEMORY, TRAP
//   * unified ready/valid instruction and data memory port
//   * 32 x 32-bit integer register file; x0 is hard-wired to zero
//   * deterministic trap on illegal or misaligned operations
//   * no cache, MMU, privilege modes, interrupts, M extension, or compressed ISA
//
// Implemented ISA:
//   RV32I integer arithmetic, logical operations, shifts, branches, jumps,
//   byte/halfword/word loads and stores, LUI, AUIPC, FENCE and FENCE.I as
//   serialization no-ops. ECALL/EBREAK and unsupported SYSTEM instructions trap.
module apzn_rv32i_core #(
    parameter [31:0] RESET_PC = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        resetn,

    output reg         trap,

    output wire        mem_valid,
    output wire        mem_instr,
    input  wire        mem_ready,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    input  wire [31:0] mem_rdata,

    output reg  [31:0] cycle_count,
    output reg  [31:0] retired_count,
    output reg  [31:0] debug_pc,
    output reg  [31:0] debug_insn
);
    localparam [2:0] ST_FETCH = 3'd0;
    localparam [2:0] ST_EXEC  = 3'd1;
    localparam [2:0] ST_MEM   = 3'd2;
    localparam [2:0] ST_TRAP  = 3'd3;

    reg [2:0] state_q;
    reg [31:0] pc_q;
    reg [31:0] instr_q;
    reg [31:0] register_file [0:31];

    reg [31:0] data_addr_q;
    reg [31:0] store_data_q;
    reg [3:0]  store_strb_q;
    reg        load_pending_q;
    reg [2:0]  load_funct3_q;
    reg [4:0]  load_rd_q;

    wire [6:0] opcode = instr_q[6:0];
    wire [4:0] rd_idx = instr_q[11:7];
    wire [2:0] funct3 = instr_q[14:12];
    wire [4:0] rs1_idx = instr_q[19:15];
    wire [4:0] rs2_idx = instr_q[24:20];
    wire [6:0] funct7 = instr_q[31:25];

    wire [31:0] rs1_data = (rs1_idx == 0) ? 32'd0 : register_file[rs1_idx];
    wire [31:0] rs2_data = (rs2_idx == 0) ? 32'd0 : register_file[rs2_idx];

    wire [31:0] imm_i = {{20{instr_q[31]}}, instr_q[31:20]};
    wire [31:0] imm_s = {{20{instr_q[31]}}, instr_q[31:25], instr_q[11:7]};
    wire [31:0] imm_b = {{19{instr_q[31]}}, instr_q[31], instr_q[7],
                         instr_q[30:25], instr_q[11:8], 1'b0};
    wire [31:0] imm_u = {instr_q[31:12], 12'd0};
    wire [31:0] imm_j = {{11{instr_q[31]}}, instr_q[31], instr_q[19:12],
                         instr_q[20], instr_q[30:21], 1'b0};

    wire [31:0] branch_target = pc_q + imm_b;
    wire [31:0] jal_target = pc_q + imm_j;
    wire [31:0] jalr_sum = rs1_data + imm_i;
    wire [31:0] jalr_target = {jalr_sum[31:1], 1'b0};
    wire [31:0] load_addr = rs1_data + imm_i;
    wire [31:0] store_addr = rs1_data + imm_s;

    reg branch_valid;
    reg branch_taken;
    always @* begin
        branch_valid = 1'b1;
        branch_taken = 1'b0;
        case (funct3)
            3'b000: branch_taken = (rs1_data == rs2_data);
            3'b001: branch_taken = (rs1_data != rs2_data);
            3'b100: branch_taken = ($signed(rs1_data) < $signed(rs2_data));
            3'b101: branch_taken = ($signed(rs1_data) >= $signed(rs2_data));
            3'b110: branch_taken = (rs1_data < rs2_data);
            3'b111: branch_taken = (rs1_data >= rs2_data);
            default: begin
                branch_valid = 1'b0;
                branch_taken = 1'b0;
            end
        endcase
    end

    reg        op_imm_valid;
    reg [31:0] op_imm_result;
    always @* begin
        op_imm_valid = 1'b1;
        op_imm_result = 32'd0;
        case (funct3)
            3'b000: op_imm_result = rs1_data + imm_i;
            3'b010: op_imm_result = ($signed(rs1_data) < $signed(imm_i));
            3'b011: op_imm_result = (rs1_data < imm_i);
            3'b100: op_imm_result = rs1_data ^ imm_i;
            3'b110: op_imm_result = rs1_data | imm_i;
            3'b111: op_imm_result = rs1_data & imm_i;
            3'b001: begin
                if (funct7 == 7'b0000000)
                    op_imm_result = rs1_data << instr_q[24:20];
                else
                    op_imm_valid = 1'b0;
            end
            3'b101: begin
                if (funct7 == 7'b0000000)
                    op_imm_result = rs1_data >> instr_q[24:20];
                else if (funct7 == 7'b0100000)
                    op_imm_result = $signed(rs1_data) >>> instr_q[24:20];
                else
                    op_imm_valid = 1'b0;
            end
            default: op_imm_valid = 1'b0;
        endcase
    end

    reg        op_valid;
    reg [31:0] op_result;
    always @* begin
        op_valid = 1'b1;
        op_result = 32'd0;
        case ({funct7, funct3})
            10'b0000000_000: op_result = rs1_data + rs2_data;
            10'b0100000_000: op_result = rs1_data - rs2_data;
            10'b0000000_001: op_result = rs1_data << rs2_data[4:0];
            10'b0000000_010: op_result = ($signed(rs1_data) < $signed(rs2_data));
            10'b0000000_011: op_result = (rs1_data < rs2_data);
            10'b0000000_100: op_result = rs1_data ^ rs2_data;
            10'b0000000_101: op_result = rs1_data >> rs2_data[4:0];
            10'b0100000_101: op_result = $signed(rs1_data) >>> rs2_data[4:0];
            10'b0000000_110: op_result = rs1_data | rs2_data;
            10'b0000000_111: op_result = rs1_data & rs2_data;
            default: op_valid = 1'b0;
        endcase
    end

    wire [4:0] load_shift_amount = {data_addr_q[1:0], 3'b000};
    wire [31:0] load_shifted = mem_rdata >> load_shift_amount;
    reg [31:0] load_result;
    always @* begin
        case (load_funct3_q)
            3'b000: load_result = {{24{load_shifted[7]}}, load_shifted[7:0]};
            3'b001: load_result = {{16{load_shifted[15]}}, load_shifted[15:0]};
            3'b010: load_result = load_shifted;
            3'b100: load_result = {24'd0, load_shifted[7:0]};
            3'b101: load_result = {16'd0, load_shifted[15:0]};
            default: load_result = 32'd0;
        endcase
    end

    assign mem_valid = resetn && ((state_q == ST_FETCH) || (state_q == ST_MEM));
    assign mem_instr = (state_q == ST_FETCH);
    assign mem_addr = (state_q == ST_FETCH) ? pc_q : data_addr_q;
    assign mem_wdata = (state_q == ST_MEM) ? store_data_q : 32'd0;
    assign mem_wstrb = ((state_q == ST_MEM) && !load_pending_q) ? store_strb_q : 4'b0000;

    integer index;
    always @(posedge clk) begin
        if (!resetn) begin
            state_q        <= ST_FETCH;
            pc_q           <= RESET_PC;
            instr_q        <= 32'h0000_0013;
            data_addr_q    <= 32'd0;
            store_data_q   <= 32'd0;
            store_strb_q   <= 4'd0;
            load_pending_q <= 1'b0;
            load_funct3_q  <= 3'd0;
            load_rd_q      <= 5'd0;
            trap            <= 1'b0;
            cycle_count     <= 32'd0;
            retired_count   <= 32'd0;
            debug_pc        <= RESET_PC;
            debug_insn      <= 32'h0000_0013;
            for (index = 0; index < 32; index = index + 1)
                register_file[index] <= 32'd0;
        end else begin
            cycle_count <= cycle_count + 1'b1;
            register_file[0] <= 32'd0;

            case (state_q)
                ST_FETCH: begin
                    if (mem_ready) begin
                        if (pc_q[1:0] != 2'b00) begin
                            trap    <= 1'b1;
                            state_q <= ST_TRAP;
                        end else begin
                            instr_q    <= mem_rdata;
                            debug_pc   <= pc_q;
                            debug_insn <= mem_rdata;
                            state_q    <= ST_EXEC;
                        end
                    end
                end

                ST_EXEC: begin
                    case (opcode)
                        7'b0110111: begin
                            if (rd_idx != 0)
                                register_file[rd_idx] <= imm_u;
                            pc_q <= pc_q + 32'd4;
                            retired_count <= retired_count + 1'b1;
                            state_q <= ST_FETCH;
                        end

                        7'b0010111: begin
                            if (rd_idx != 0)
                                register_file[rd_idx] <= pc_q + imm_u;
                            pc_q <= pc_q + 32'd4;
                            retired_count <= retired_count + 1'b1;
                            state_q <= ST_FETCH;
                        end

                        7'b1101111: begin
                            if (jal_target[1:0] != 2'b00) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else begin
                                if (rd_idx != 0)
                                    register_file[rd_idx] <= pc_q + 32'd4;
                                pc_q <= jal_target;
                                retired_count <= retired_count + 1'b1;
                                state_q <= ST_FETCH;
                            end
                        end

                        7'b1100111: begin
                            if ((funct3 != 3'b000) || (jalr_target[1:0] != 2'b00)) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else begin
                                if (rd_idx != 0)
                                    register_file[rd_idx] <= pc_q + 32'd4;
                                pc_q <= jalr_target;
                                retired_count <= retired_count + 1'b1;
                                state_q <= ST_FETCH;
                            end
                        end

                        7'b1100011: begin
                            if (!branch_valid) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else if (branch_taken && (branch_target[1:0] != 2'b00)) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else begin
                                pc_q <= branch_taken ? branch_target : (pc_q + 32'd4);
                                retired_count <= retired_count + 1'b1;
                                state_q <= ST_FETCH;
                            end
                        end

                        7'b0000011: begin
                            if (((funct3 == 3'b001) || (funct3 == 3'b101)) && load_addr[0]) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else if ((funct3 == 3'b010) && (load_addr[1:0] != 2'b00)) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else if (!((funct3 == 3'b000) || (funct3 == 3'b001) ||
                                           (funct3 == 3'b010) || (funct3 == 3'b100) ||
                                           (funct3 == 3'b101))) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else begin
                                data_addr_q    <= load_addr;
                                store_data_q   <= 32'd0;
                                store_strb_q   <= 4'b0000;
                                load_pending_q <= 1'b1;
                                load_funct3_q  <= funct3;
                                load_rd_q      <= rd_idx;
                                pc_q           <= pc_q + 32'd4;
                                state_q        <= ST_MEM;
                            end
                        end

                        7'b0100011: begin
                            if ((funct3 == 3'b001) && store_addr[0]) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else if ((funct3 == 3'b010) && (store_addr[1:0] != 2'b00)) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else if (!((funct3 == 3'b000) || (funct3 == 3'b001) ||
                                           (funct3 == 3'b010))) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else begin
                                data_addr_q    <= store_addr;
                                load_pending_q <= 1'b0;
                                load_funct3_q  <= 3'd0;
                                load_rd_q      <= 5'd0;
                                pc_q           <= pc_q + 32'd4;
                                case (funct3)
                                    3'b000: begin
                                        store_data_q <= {4{rs2_data[7:0]}};
                                        store_strb_q <= 4'b0001 << store_addr[1:0];
                                    end
                                    3'b001: begin
                                        store_data_q <= {2{rs2_data[15:0]}};
                                        store_strb_q <= 4'b0011 << store_addr[1:0];
                                    end
                                    default: begin
                                        store_data_q <= rs2_data;
                                        store_strb_q <= 4'b1111;
                                    end
                                endcase
                                state_q <= ST_MEM;
                            end
                        end

                        7'b0010011: begin
                            if (!op_imm_valid) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else begin
                                if (rd_idx != 0)
                                    register_file[rd_idx] <= op_imm_result;
                                pc_q <= pc_q + 32'd4;
                                retired_count <= retired_count + 1'b1;
                                state_q <= ST_FETCH;
                            end
                        end

                        7'b0110011: begin
                            if (!op_valid) begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end else begin
                                if (rd_idx != 0)
                                    register_file[rd_idx] <= op_result;
                                pc_q <= pc_q + 32'd4;
                                retired_count <= retired_count + 1'b1;
                                state_q <= ST_FETCH;
                            end
                        end

                        7'b0001111: begin
                            if ((funct3 == 3'b000) || (funct3 == 3'b001)) begin
                                pc_q <= pc_q + 32'd4;
                                retired_count <= retired_count + 1'b1;
                                state_q <= ST_FETCH;
                            end else begin
                                trap <= 1'b1;
                                state_q <= ST_TRAP;
                            end
                        end

                        default: begin
                            trap <= 1'b1;
                            state_q <= ST_TRAP;
                        end
                    endcase
                end

                ST_MEM: begin
                    if (mem_ready) begin
                        if (load_pending_q && (load_rd_q != 0))
                            register_file[load_rd_q] <= load_result;
                        retired_count <= retired_count + 1'b1;
                        state_q <= ST_FETCH;
                    end
                end

                default: begin
                    trap <= 1'b1;
                    state_q <= ST_TRAP;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
