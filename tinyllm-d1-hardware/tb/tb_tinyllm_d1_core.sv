`timescale 1ns/1ps
`default_nettype none

module tb_tinyllm_d1_core;
    localparam integer LANES = 4;

    reg clk;
    reg rst_n;
    reg host_valid;
    reg host_write;
    reg [2:0] host_space;
    reg [15:0] host_addr;
    reg [31:0] host_wdata;
    reg [3:0] host_wstrb;
    wire host_ready;
    wire [31:0] host_rdata;
    wire host_rvalid;
    reg cmd_valid;
    reg [127:0] cmd_data;
    wire cmd_ready;
    wire done_valid;
    reg done_ready;
    wire [15:0] done_tag;
    wire [7:0] done_status;
    wire busy;
    wire irq_done;

    integer i;
    integer signed x [0:7];
    integer signed w8 [0:23];
    reg [31:0] read_value;

    tinyllm_d1_core #(
        .LANES(LANES),
        .ACT_DEPTH_PER_BANK(16),
        .W8_DEPTH_PER_BANK(32),
        .W4_DEPTH_PER_BANK(32),
        .RESULT_DEPTH(64)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .host_valid(host_valid), .host_write(host_write),
        .host_space(host_space), .host_addr(host_addr),
        .host_wdata(host_wdata), .host_wstrb(host_wstrb),
        .host_ready(host_ready), .host_rdata(host_rdata),
        .host_rvalid(host_rvalid),
        .cmd_valid(cmd_valid), .cmd_data(cmd_data), .cmd_ready(cmd_ready),
        .done_valid(done_valid), .done_ready(done_ready),
        .done_tag(done_tag), .done_status(done_status),
        .busy(busy), .irq_done(irq_done)
    );

    always #5 clk = ~clk;

    function [7:0] pack_i4;
        input integer signed low_value;
        input integer signed high_value;
        begin
            pack_i4 = {high_value[3:0], low_value[3:0]};
        end
    endfunction

    task host_write_byte;
        input [2:0] space;
        input [15:0] address;
        input [7:0] value;
        begin
            @(negedge clk);
            host_valid = 1'b1;
            host_write = 1'b1;
            host_space = space;
            host_addr = address;
            host_wdata = {24'd0, value};
            host_wstrb = 4'b0001;
            while (!host_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            host_valid = 1'b0;
            host_write = 1'b0;
            host_wstrb = 4'b0000;
        end
    endtask

    task host_read_word;
        input [2:0] space;
        input [15:0] address;
        output [31:0] value;
        begin
            @(negedge clk);
            host_valid = 1'b1;
            host_write = 1'b0;
            host_space = space;
            host_addr = address;
            host_wdata = 32'd0;
            host_wstrb = 4'b0000;
            while (!host_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            host_valid = 1'b0;
            while (!host_rvalid) @(negedge clk);
            value = host_rdata;
        end
    endtask

    task issue_command;
        input [7:0] opcode;
        input [15:0] m;
        input [15:0] k;
        input [15:0] x_base;
        input [15:0] w_base;
        input [15:0] y_base;
        input [15:0] w_stride;
        input [15:0] tag;
        input [7:0] expected_status;
        reg [127:0] command_word;
        begin
            command_word = 128'd0;
            command_word[127:120] = opcode;
            command_word[111:96]  = m;
            command_word[95:80]   = k;
            command_word[79:64]   = x_base;
            command_word[63:48]   = w_base;
            command_word[47:32]   = y_base;
            command_word[31:16]   = w_stride;
            command_word[15:0]    = tag;

            @(negedge clk);
            cmd_valid = 1'b1;
            cmd_data = command_word;
            while (!cmd_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
            while (!done_valid) @(negedge clk);

            if (done_status !== expected_status) begin
                $display("FAIL: tag=%0d status expected=%0d got=%0d",
                         tag, expected_status, done_status);
                $fatal(1);
            end
            if (done_tag !== tag) begin
                $display("FAIL: completion tag expected=%0d got=%0d", tag, done_tag);
                $fatal(1);
            end
            if (!irq_done) begin
                $display("FAIL: irq_done must mirror held completion");
                $fatal(1);
            end

            done_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            done_ready = 1'b0;
        end
    endtask

    task expect_result;
        input [15:0] address;
        input integer signed expected;
        begin
            host_read_word(3'd3, address, read_value);
            if ($signed(read_value) !== expected) begin
                $display("FAIL: result[%0d] expected=%0d got=%0d (0x%08x)",
                         address, expected, $signed(read_value), read_value);
                $fatal(1);
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        host_valid = 1'b0;
        host_write = 1'b0;
        host_space = 3'd0;
        host_addr = 16'd0;
        host_wdata = 32'd0;
        host_wstrb = 4'd0;
        cmd_valid = 1'b0;
        cmd_data = 128'd0;
        done_ready = 1'b0;

        x[0] =  3; x[1] = -2; x[2] =  5; x[3] =  1;
        x[4] = -4; x[5] =  7; x[6] =  0; x[7] =  0;

        w8[ 0] =  1; w8[ 1] =  2; w8[ 2] = -1; w8[ 3] =  0;
        w8[ 4] =  3; w8[ 5] = -2; w8[ 6] =  0; w8[ 7] =  0;
        w8[ 8] = -4; w8[ 9] =  0; w8[10] =  2; w8[11] =  3;
        w8[12] = -1; w8[13] =  1; w8[14] =  0; w8[15] =  0;
        w8[16] =  7; w8[17] = -3; w8[18] =  0; w8[19] = -2;
        w8[20] =  2; w8[21] = -1; w8[22] =  0; w8[23] =  0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (i = 0; i < 8; i = i + 1)
            host_write_byte(3'd0, i[15:0], x[i][7:0]);
        for (i = 0; i < 24; i = i + 1)
            host_write_byte(3'd1, i[15:0], w8[i][7:0]);

        issue_command(8'h01, 16'd3, 16'd6, 16'd0, 16'd0,
                      16'd0, 16'd8, 16'h1001, 8'h00);
        expect_result(16'd0, -32);
        expect_result(16'd1,  12);
        expect_result(16'd2,  10);

        host_write_byte(3'd2, 16'd0, pack_i4( 7, -8));
        host_write_byte(3'd2, 16'd1, pack_i4( 3, -1));
        host_write_byte(3'd2, 16'd2, pack_i4( 2,  0));
        host_write_byte(3'd2, 16'd3, 8'h00);
        host_write_byte(3'd2, 16'd4, pack_i4(-2,  4));
        host_write_byte(3'd2, 16'd5, pack_i4(-5,  6));
        host_write_byte(3'd2, 16'd6, pack_i4(-7,  1));
        host_write_byte(3'd2, 16'd7, 8'h00);
        host_write_byte(3'd2, 16'd8,  pack_i4( 0,  1));
        host_write_byte(3'd2, 16'd9,  pack_i4( 2,  3));
        host_write_byte(3'd2, 16'd10, pack_i4( 4,  5));
        host_write_byte(3'd2, 16'd11, 8'h00);

        issue_command(8'h02, 16'd3, 16'd6, 16'd0, 16'd0,
                      16'd16, 16'd4, 16'h1002, 8'h00);
        expect_result(16'd16, 43);
        expect_result(16'd17,  2);
        expect_result(16'd18, 30);

        issue_command(8'h02, 16'd1, 16'd4, 16'd1, 16'd0,
                      16'd20, 16'd2, 16'h10EE, 8'h03);

        host_read_word(3'd4, 16'h0008, read_value);
        if (read_value !== 32'd36) begin
            $display("FAIL: MAC counter expected=36 got=%0d", read_value);
            $fatal(1);
        end

        host_read_word(3'd4, 16'h0006, read_value);
        if (read_value !== 32'd3) begin
            $display("FAIL: command counter expected=3 got=%0d", read_value);
            $fatal(1);
        end

        $display("PASS: TinyLLM-D1 integrated INT8/packed-INT4 hardware test");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: simulation timeout");
        $fatal(1);
    end
endmodule

`default_nettype wire
