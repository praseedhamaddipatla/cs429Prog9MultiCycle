`include "hdl/alu.sv"
`include "hdl/regfile.sv"
`include "hdl/decoder.sv"
`include "hdl/instructfetch.sv"

module tinker_core(
    input wire clk,
    input wire reset,
    output reg hlt
);

parameter S0_FETCH   = 3'd0;
parameter S1_DECODE  = 3'd1;
parameter S2_COMPUTE = 3'd2;
parameter S3_MEM     = 3'd3;
parameter S4_WB      = 3'd4;

reg [2:0] curr_state;
reg [2:0] next_state;

// fetch/instruct wires
wire [63:0] currpc;
wire [31:0] currinstruct;

// decoder output wires
wire [4:0]  op;
wire [4:0]  rd;
wire [4:0]  rs;
wire [4:0]  rt;
wire [11:0] lit;
wire write_reg;
wire read_mem;
wire write_mem;
wire has_rs, has_rt, has_lit;
wire [4:0] alu_op;
wire branch_instruct;
wire call_instruct;
wire return_instruct;
wire rd_is_val, rd_is_adr, write_from_mem;
wire rd_is_branch_target;
wire branch_reg, branch_lit, branch_nz, branch_gt;

// pipeline regs
reg [31:0] instruct_reg;
reg [63:0] a_reg, b_reg, c_reg, l_reg, mem_out_reg;
reg [4:0]  rd_reg;
reg [4:0]  op_reg;
reg [63:0] pc_reg;

// regfile signals
reg  [4:0]  read_addr1, read_addr2;
wire [63:0] read_data1, read_data2;

// immediate signals
wire [63:0] imm_unsigned = {52'd0, lit};
wire [63:0] imm_signed   = {{52{lit[11]}}, lit};

// alu signals
reg  [63:0] alu_a, alu_b;
wire [63:0] alu_c;

// mem signals
reg  [63:0] data_addr, write_data;
wire [63:0] read_data;

// writeback/branch signals
reg [63:0] writeback_data;
reg        branch;
reg [63:0] next_pc_target;

// control signals
reg  pc_enable;
wire go_write_mem = write_mem;
wire go_read_mem  = read_mem;
wire go_writeback = write_reg && !branch_instruct && !call_instruct && !return_instruct;
wire go_return    = return_instruct;
wire go_call      = call_instruct;

// -----------------------------------------------------------------------
// State machine
// call and return both need S3 (memory) and S4 (SP writeback / redirect)
// -----------------------------------------------------------------------
always @(posedge clk or posedge reset) begin
    if (reset) curr_state <= S0_FETCH;
    else if (!hlt) curr_state <= next_state;
end

always @(*) begin
    next_state = curr_state;
    case (curr_state)
        S0_FETCH:  next_state = S1_DECODE;
        S1_DECODE: next_state = S2_COMPUTE;
        S2_COMPUTE: begin
            if (go_call || go_return || go_write_mem || go_read_mem)
                next_state = S3_MEM;
            else if (go_writeback)
                next_state = S4_WB;
            else
                next_state = S0_FETCH;
        end
        S3_MEM: begin
            // call/return always proceed to S4 for SP update and PC redirect
            if (go_writeback || go_call || go_return)
                next_state = S4_WB;
            else
                next_state = S0_FETCH;
        end
        S4_WB:   next_state = S0_FETCH;
        default: next_state = S0_FETCH;
    endcase
end

// -----------------------------------------------------------------------
// Pipeline register updates
// -----------------------------------------------------------------------
always @(posedge clk or posedge reset) begin
    if (reset) begin
        instruct_reg <= 32'd0;
        a_reg        <= 64'd0;
        b_reg        <= 64'd0;
        c_reg        <= 64'd0;
        l_reg        <= 64'd0;
        mem_out_reg  <= 64'd0;
        rd_reg       <= 5'd0;
        op_reg       <= 5'd0;
        hlt          <= 1'b0;
        pc_reg       <= 64'd0;
    end else begin
        case (curr_state)
            S0_FETCH: begin
                instruct_reg <= currinstruct;
                pc_reg       <= currpc;
            end
            S1_DECODE: begin
                if (op == 5'h0F && lit == 12'h000) begin
                    hlt <= 1'b1;
                end else begin
                    a_reg  <= read_data1;
                    b_reg  <= read_data2;
                    rd_reg <= rd;
                    op_reg <= alu_op;
                    if (alu_op == 5'h05 || alu_op == 5'h07 || alu_op == 5'h12 ||
                        alu_op == 5'h19 || alu_op == 5'h1B)
                        l_reg <= imm_unsigned;
                    else
                        l_reg <= imm_signed;
                end
            end
            S2_COMPUTE: begin
                c_reg <= alu_c;
            end
            S3_MEM: begin
                // latch read output for load AND return
                if (go_read_mem || go_return)
                    mem_out_reg <= read_data;
            end
            S4_WB: begin
                // nothing to latch
            end
        endcase
    end
end

// -----------------------------------------------------------------------
// Sub-module instantiation
// -----------------------------------------------------------------------
instructfetch fetch(
    .clk      (clk),
    .reset    (reset),
    .ooosignal(branch),
    .oooadr   (next_pc_target),
    .pc       (currpc),
    .pc_enable(pc_enable)
);

decoder decode(
    .instruct           (instruct_reg),
    .op                 (op),
    .rd                 (rd),
    .rs                 (rs),
    .rt                 (rt),
    .lit                (lit),
    .write_reg          (write_reg),
    .read_mem           (read_mem),
    .write_mem          (write_mem),
    .has_rs             (has_rs),
    .has_rt             (has_rt),
    .has_lit            (has_lit),
    .alu_op             (alu_op),
    .branch_instruct    (branch_instruct),
    .call_instruct      (call_instruct),
    .return_instruct    (return_instruct),
    .rd_is_val          (rd_is_val),
    .rd_is_adr          (rd_is_adr),
    .write_from_mem     (write_from_mem),
    .rd_is_branch_target(rd_is_branch_target),
    .branch_reg         (branch_reg),
    .branch_lit         (branch_lit),
    .branch_nz          (branch_nz),
    .branch_gt          (branch_gt)
);

regfile reg_file(
    .clk         (clk),
    .reset       (reset),
    // call and return both write r31 (updated SP) at S4
    .write_enable((curr_state == S4_WB) && (go_writeback || go_call || go_return)),
    .read_addr1  (read_addr1),
    .read_addr2  (read_addr2),
    .write_addr  ((go_call || go_return) ? 5'd31 : rd_reg),
    .write_data  (writeback_data),
    .read_data1  (read_data1),
    .read_data2  (read_data2)
);

memory memory(
    .clk         (clk),
    .pc          (currpc),
    .instruction (currinstruct),
    // return reads from stack at S3; call writes to stack at S3
    .mem_read    ((curr_state == S3_MEM) && (go_read_mem || go_return)),
    .mem_write   ((curr_state == S3_MEM) && (go_write_mem || go_call)),
    .data_addr   (data_addr),
    .write_data  (write_data),
    .read_data   (read_data)
);

alu alu_fpu(
    .a     (alu_a),
    .b     (alu_b),
    .alu_op(op_reg),
    .c     (alu_c)
);

// -----------------------------------------------------------------------
// PC enable
// call redirects at S2_COMPUTE  — suppress pc_enable there
// return redirects at S4_WB     — suppress pc_enable there
// -----------------------------------------------------------------------
always @(*) begin
    pc_enable = 1'b0;
    if (curr_state == S4_WB && !go_return)
        pc_enable = 1'b1;
    else if (curr_state == S3_MEM && !go_writeback && !go_call && !go_return)
        pc_enable = 1'b1;
    else if (curr_state == S2_COMPUTE && !go_read_mem && !go_write_mem &&
             !go_writeback && !go_call && !go_return)
        pc_enable = 1'b1;
end

// -----------------------------------------------------------------------
// Register read address select
// -----------------------------------------------------------------------
always @(*) begin
    if (branch_nz) begin
        read_addr1 = rs;
        read_addr2 = rd;
    end else if (branch_gt) begin
        read_addr1 = rd;
        read_addr2 = rs;
    end else if (call_instruct) begin
        read_addr1 = rd;
        read_addr2 = rt;
    end else if (rd_is_adr) begin
        read_addr1 = rd;
        read_addr2 = rs;
    end else if (rd_is_val || rd_is_branch_target) begin
        read_addr1 = rd;
        read_addr2 = rt;
    end else begin
        read_addr1 = rs;
        read_addr2 = rt;
    end
end

// -----------------------------------------------------------------------
// ALU input select
// -----------------------------------------------------------------------
always @(*) begin
    alu_a = a_reg;
    alu_b = has_lit ? l_reg : b_reg;
end

// -----------------------------------------------------------------------
// Memory address / write-data
//
// call:        write (pc_reg + 4) to (SP - 8)   pre-decrement push
// return:      read  from         (SP - 8)       matching pop address
// load/store:  c_reg (ALU-computed address)
// -----------------------------------------------------------------------
always @(*) begin
    data_addr  = 64'd0;
    write_data = 64'd0;

    if (call_instruct) begin
        data_addr  = reg_file.registers[31] - 64'd8;
        write_data = pc_reg + 64'd4;
    end else if (return_instruct) begin
        data_addr  = reg_file.registers[31] - 64'd8;
    end else if (go_read_mem || go_write_mem) begin
        data_addr = c_reg;
        if (go_write_mem)
            write_data = b_reg;
    end
end

// -----------------------------------------------------------------------
// Writeback data mux
//
// call:   new SP = SP - 8  → r31
// return: new SP = SP + 8  → r31
// load:   mem_out_reg
// else:   ALU result (c_reg)
// -----------------------------------------------------------------------
always @(*) begin
    if (go_call)
        writeback_data = reg_file.registers[31] - 64'd8;
    else if (go_return)
        writeback_data = reg_file.registers[31] + 64'd8;
    else if (write_from_mem)
        writeback_data = mem_out_reg;
    else
        writeback_data = c_reg;
end

// -----------------------------------------------------------------------
// Branch / call / return PC redirect
//
// call:   fires at S2_COMPUTE → jump to target register (a_reg)
// return: fires at S4_WB      → jump to return addr latched in mem_out_reg
// -----------------------------------------------------------------------
always @(*) begin
    branch         = 1'b0;
    next_pc_target = 64'd0;

    if (curr_state == S2_COMPUTE) begin
        if (call_instruct) begin
            branch         = 1'b1;
            next_pc_target = a_reg;
        end else if (branch_instruct) begin
            if (branch_reg) begin
                branch         = 1'b1;
                next_pc_target = currpc + a_reg;
            end else if (branch_lit) begin
                branch         = 1'b1;
                next_pc_target = currpc + l_reg;
            end else if (branch_nz) begin
                if (a_reg != 64'd0) begin
                    branch         = 1'b1;
                    next_pc_target = b_reg;
                end
            end else if (branch_gt) begin
                if ($signed(b_reg) > $signed(reg_file.registers[rt])) begin
                    branch         = 1'b1;
                    next_pc_target = a_reg;
                end
            end else if (rd_is_branch_target) begin
                branch         = 1'b1;
                next_pc_target = a_reg;
            end
        end
    end else if (curr_state == S4_WB && return_instruct) begin
        // return address was latched into mem_out_reg at end of S3_MEM
        branch         = 1'b1;
        next_pc_target = mem_out_reg;
    end
end

endmodule