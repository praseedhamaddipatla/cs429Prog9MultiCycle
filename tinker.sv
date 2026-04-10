`include "hdl/alu.sv"
`include "hdl/regfile.sv"
`include "hdl/decoder.sv"
`include "hdl/instructfetch.sv"

module tinker_core (
    input  wire clk,
    input  wire reset,
    output reg  hlt
);

  parameter S0_FETCH = 3'd0;
  parameter S1_DECODE = 3'd1;
  parameter S2_COMPUTE = 3'd2;
  parameter S3_MEM = 3'd3;
  parameter S4_WB = 3'd4;

  reg  [ 2:0] curr_state;
  reg  [ 2:0] next_state;

  // Wires from Fetch/Decoder
  wire [63:0] currpc;
  wire [31:0] currinstruct;
  wire [4:0] op, rd, rs, rt, alu_op;
  wire [11:0] lit;
  wire write_reg, read_mem, write_mem, has_rs, has_rt, has_lit;
  wire branch_instruct, call_instruct, return_instruct;
  wire rd_is_val, rd_is_adr, write_from_mem, rd_is_branch_target;
  wire branch_reg, branch_lit, branch_nz, branch_gt;

  // Registers for multi-cycle
  reg [31:0] instruct_reg;
  reg [63:0] a_reg, b_reg, c_reg, l_reg, mem_out_reg, pc_reg;
  reg [4:0] rd_reg, op_reg;

  // Regfile signals
  reg [4:0] read_addr1, read_addr2;
  wire [63:0] read_data1, read_data2;

  // ALU signals
  reg [63:0] alu_a, alu_b;
  wire [63:0] alu_c;

  // Data memory signals
  reg [63:0] data_addr, write_data;
  wire [63:0] read_data;

  // Branch/PC Control
  reg branch;
  reg [63:0] next_pc_target;
  reg pc_enable;

  // State Transition Logic
  always @(posedge clk or posedge reset) begin
    if (reset) curr_state <= S0_FETCH;
    else if (!hlt) curr_state <= next_state;
  end

  always @(*) begin
    next_state = curr_state;
    case (curr_state)
      S0_FETCH: next_state = S1_DECODE;
      S1_DECODE: next_state = S2_COMPUTE;
      S2_COMPUTE: begin
        if (write_mem || read_mem || call_instruct || return_instruct) next_state = S3_MEM;
        else if (write_reg && !branch_instruct) next_state = S4_WB;
        else next_state = S0_FETCH;
      end
      S3_MEM: begin
        if (read_mem || return_instruct) next_state = S4_WB;
        else next_state = S0_FETCH;
      end
      S4_WB: next_state = S0_FETCH;
      default: next_state = S0_FETCH;
    endcase
  end

  // Data Latching
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      instruct_reg <= 32'd0;
      a_reg <= 64'd0;
      b_reg <= 64'd0;
      c_reg <= 64'd0;
      l_reg <= 64'd0;
      mem_out_reg <= 64'd0;
      rd_reg <= 5'd0;
      op_reg <= 5'd0;
      hlt <= 1'b0;
      pc_reg <= 64'd0;
    end else begin
      case (curr_state)
        S0_FETCH: begin
          instruct_reg <= currinstruct;
          pc_reg <= currpc;
        end
        S1_DECODE: begin
          if (op == 5'h0F && lit == 12'h000) hlt <= 1'b1;
          a_reg <= read_data1;
          b_reg <= read_data2;
          rd_reg <= rd;
          op_reg <= alu_op;
          l_reg <= (alu_op == 5'h05 || alu_op == 5'h07 || alu_op == 5'h12 || alu_op == 5'h19 || alu_op == 5'h1B) ? {52'd0, lit} : {{52{lit[11]}}, lit};
        end
        S2_COMPUTE: c_reg <= alu_c;
        S3_MEM:     mem_out_reg <= read_data;
      endcase
    end
  end

  // PC Advance Logic
  always @(*) begin
    pc_enable = (next_state == S0_FETCH && curr_state != S0_FETCH);
  end

  // Memory Address/Data Logic (Stack Pointer handling)
  wire [63:0] sp_val = reg_file.registers[31];
  always @(*) begin
    if (call_instruct || return_instruct) begin
      data_addr  = sp_val - 64'd8;  // Pre-decrement SP logic
      write_data = pc_reg + 64'd4;  // Save return address
    end else begin
      data_addr  = (rd_is_adr) ? (a_reg + l_reg) : c_reg;
      write_data = b_reg;
    end
  end

  // Branch and Jump Logic
  always @(*) begin
    branch = 1'b0;
    next_pc_target = 64'd0;

    if (curr_state == S2_COMPUTE) begin
      if (call_instruct) begin
        branch = 1'b1;
        next_pc_target = a_reg;
      end else if (branch_instruct) begin
        if (branch_reg) begin
          branch = 1'b1;
          next_pc_target = pc_reg + a_reg;
        end else if (branch_lit) begin
          branch = 1'b1;
          next_pc_target = pc_reg + l_reg;
        end else if (branch_nz && a_reg != 64'd0) begin
          branch = 1'b1;
          next_pc_target = b_reg;
        end else if (branch_gt && $signed(a_reg) > $signed(b_reg)) begin
          branch = 1'b1;
          next_pc_target = read_data2;
        end else if (rd_is_branch_target) begin
          branch = 1'b1;
          next_pc_target = a_reg;
        end
      end
    end else if (curr_state == S4_WB && return_instruct) begin
      branch = 1'b1;
      next_pc_target = mem_out_reg;
    end
  end

  // Register Read Address Mux
  always @(*) begin
    if (branch_nz || branch_gt) begin
      read_addr1 = rs;
      read_addr2 = rd;
    end else if (call_instruct) begin
      read_addr1 = rd;
      read_addr2 = rt;
    end else if (rd_is_adr) begin
      read_addr1 = rd;
      read_addr2 = rs;
    end else begin
      read_addr1 = rs;
      read_addr2 = rt;
    end
  end

  // ALU Mux
  always @(*) begin
    alu_a = a_reg;
    alu_b = (has_lit) ? l_reg : b_reg;
  end

  // Writeback Mux
  wire [63:0] writeback_data = (write_from_mem || return_instruct) ? mem_out_reg : c_reg;

  // Instantiations
  instructfetch fetch_i (
      .clk(clk),
      .reset(reset),
      .ooosignal(branch),
      .oooadr(next_pc_target),
      .pc(currpc),
      .pc_enable(pc_enable)
  );

  decoder decode_i (
      .instruct(instruct_reg),
      .op(op),
      .rd(rd),
      .rs(rs),
      .rt(rt),
      .lit(lit),
      .write_reg(write_reg),
      .read_mem(read_mem),
      .write_mem(write_mem),
      .has_rs(has_rs),
      .has_rt(has_rt),
      .has_lit(has_lit),
      .alu_op(alu_op),
      .branch_instruct(branch_instruct),
      .call_instruct(call_instruct),
      .return_instruct(return_instruct),
      .rd_is_val(rd_is_val),
      .rd_is_adr(rd_is_adr),
      .write_from_mem(write_from_mem),
      .rd_is_branch_target(rd_is_branch_target),
      .branch_reg(branch_reg),
      .branch_lit(branch_lit),
      .branch_nz(branch_nz),
      .branch_gt(branch_gt)
  );

  regfile reg_file (
      .clk(clk),
      .reset(reset),
      .write_enable((curr_state == S4_WB) && write_reg),
      .read_addr1(read_addr1),
      .read_addr2(read_addr2),
      .write_addr(rd_reg),
      .write_data(writeback_data),
      .read_data1(read_data1),
      .read_data2(read_data2)
  );

  memory mem_i (
      .clk(clk),
      .pc(currpc),
      .instruction(currinstruct),
      .mem_read((curr_state == S3_MEM) && (read_mem || return_instruct)),
      .mem_write((curr_state == S3_MEM) && (write_mem || call_instruct)),
      .data_addr(data_addr),
      .write_data(write_data),
      .read_data(read_data)
  );

  alu alu_i (
      .a(alu_a),
      .b(alu_b),
      .alu_op(op_reg),
      .c(alu_c)
  );

endmodule
