`define MEM_SIZE (512 * 1024)
`define PC_START 64'h2000

`include "hdl/alu.sv"
`include "hdl/regfile.sv"
`include "hdl/decoder.sv"
`include "hdl/fetch.sv"
`include "hdl/mem_module.sv"

module tinker_core (
    input clk,
    input reset,
    output logic hlt
);

  typedef enum logic [2:0] {
    S0, S1, S2, S3, S4
  } state_t;

  state_t state;

  wire halted = hlt;

  // =========================
  // LATCHED CONTROL SIGNALS
  // =========================
  reg is_load_r, is_store_r, is_call_r;
  reg is_branch_r, is_jump_r, is_halt_r;
  reg write_r;
  reg is_return_r;
  reg is_mov_reg_r, is_mov_imm_r;

  // =========================
  // STATE TRANSITION CONTROL
  // =========================
  wire needS3 = is_load_r || is_store_r || is_call_r || is_return_r;
  wire needS4 = write_r && !is_store_r && !is_branch_r && !is_jump_r && !is_halt_r;

  always @(posedge clk) begin
    if (reset) state <= S0;
    else begin
      case (state)
        S0: state <= S1;
        S1: state <= S2;
        S2: state <= needS3 ? S3 : needS4 ? S4 : S0;
        S3: state <= needS4 ? S4 : S0;
        S4: state <= S0;
      endcase
    end
  end

  // =========================
  // IR LATCH
  // =========================
  reg [31:0] IR;

  always @(posedge clk) begin
    if (state == S0) IR <= instr;
  end

  wire [31:0] dec_instr = (state == S0) ? instr : IR;

  // =========================
  // WIRES
  // =========================
  wire [63:0] pc;
  wire [31:0] instr;

  wire [4:0] raddr1, raddr2, waddr;
  wire [63:0] immediate;
  wire [4:0] op;
  wire use_imm, write;
  wire is_load, is_store;
  wire is_branch, is_brgt, is_jump;
  wire is_brr_reg, is_brr_imm;
  wire is_return, is_call;
  wire is_halt;
  wire is_mov_reg, is_mov_imm;
  wire [4:0] rt_addr;

  wire [63:0] data1, data2, data3;
  wire [63:0] alu_result;
  wire [63:0] mem_rdata;

  // =========================
  // LATCH CONTROL SIGNALS (S1)
  // =========================
  always @(posedge clk) begin
    if (state == S1) begin
      is_load_r   <= is_load;
      is_store_r  <= is_store;
      is_call_r   <= is_call;
      is_branch_r <= is_branch;
      is_jump_r   <= is_jump;
      is_halt_r   <= is_halt;
      write_r     <= write;
      is_return_r <= is_return;
      is_mov_reg_r <= is_mov_reg;
      is_mov_imm_r <= is_mov_imm;
    end
  end

  // =========================
  // HALT
  // =========================
  always @(posedge clk) begin
    if (reset) hlt <= 0;
    else if (is_halt_r && state == S2) hlt <= 1;
  end

  // =========================
  // STACK POINTER
  // =========================
  wire [63:0] r31_val = reg_file.registers[31];
  wire [63:0] stack_top = r31_val - 64'd8;

  // =========================
  // ALU
  // =========================
  wire [63:0] alu_a = is_brgt ? data2 : data1;
  wire [63:0] alu_b = is_brgt ? data3 : (use_imm ? immediate : data2);

  alu alu_inst (
      .a(alu_a),
      .b(alu_b),
      .op(op),
      .result(alu_result)
  );

  // =========================
  // MEMORY
  // =========================
  wire [63:0] mem_data_addr =
      (is_return_r || is_call_r) ? stack_top : (data1 + immediate);

  wire [63:0] mem_write_val =
      is_call_r ? (pc + 64'd4) : data2;

  wire mem_we =
      (is_store_r || is_call_r) && (state == S3) && !halted;

  mem_module #(.MEM_SIZE(`MEM_SIZE)) memory (
      .clk(clk),
      .fetch_addr(pc),
      .instr_out(instr),
      .data_addr(mem_data_addr),
      .write_data(mem_write_val),
      .we(mem_we),
      .read_data(mem_rdata)
  );

  // =========================
  // WRITEBACK
  // =========================
  wire [63:0] wb_data =
      is_load_r    ? mem_rdata :
      is_mov_reg_r ? data1 :
      is_mov_imm_r ? ((data1 & ~64'hFFF) | immediate) :
                     alu_result;

  // =========================
  // FETCH
  // =========================
  fetch fetch_inst (
      .clk(clk),
      .reset(reset),
      .halt(halted),
      .is_jump(is_jump_r && state == S2),
      .is_branch(is_branch_r && state == S2),
      .is_brgt(is_brgt),
      .is_brr_reg(is_brr_reg),
      .is_brr_imm(is_brr_imm),
      .is_return(is_return_r),
      .is_call(is_call_r),
      .branch_cond(alu_result[0]),
      .data1(data1),
      .data2(data2),
      .immediate(immediate),
      .mem_rdata(mem_rdata),
      .pc(pc)
  );

  // =========================
  // DECODER
  // =========================
  decoder dec_inst (
      .instr(dec_instr),
      .raddr1(raddr1),
      .raddr2(raddr2),
      .waddr(waddr),
      .immediate(immediate),
      .op(op),
      .use_imm(use_imm),
      .write(write),
      .is_load(is_load),
      .is_store(is_store),
      .is_branch(is_branch),
      .is_brgt(is_brgt),
      .is_jump(is_jump),
      .is_brr_reg(is_brr_reg),
      .is_brr_imm(is_brr_imm),
      .is_return(is_return),
      .is_call(is_call),
      .is_halt(is_halt),
      .is_mov_reg(is_mov_reg),
      .is_mov_imm(is_mov_imm),
      .rt_addr(rt_addr)
  );

  // =========================
  // REGFILE
  // =========================
  reg_file reg_file (
      .clk(clk),
      .reset(reset),
      .raddr1(raddr1),
      .raddr2(raddr2),
      .raddr3(rt_addr),
      .waddr(waddr),
      .data(wb_data),
      .write(write_r && (state == S4) && !halted),
      .r1(data1),
      .r2(data2),
      .r3(data3)
  );

  // =========================
  // INIT STACK POINTER
  // =========================
  always @(posedge clk) begin
    if (reset) reg_file.registers[31] <= `MEM_SIZE;
  end

endmodule