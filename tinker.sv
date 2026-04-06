`define MEM_SIZE (512 * 1024)
`define PC_START 64'h2000

`include "hdl/alu.sv"
`include "hdl/regfile.sv"
`include "hdl/decoder.sv"
`include "hdl/fetch.sv"
`include "hdl/mem_module.sv"

// top-level core - wires fetch, memory, decoder, register file, and alu together
module tinker_core (
    input clk,
    input reset
);
  localparam MEM_SIZE = 512 * 1024;

  // wires to connect modules

  // IF => decoder
  wire [63:0] pc;
  wire [31:0] instr;

  // decoder outputs
  wire [4:0]  raddr1, raddr2, waddr;
  wire [63:0] immediate;
  wire [4:0]  op;
  wire        use_imm, write;
  wire        is_load, is_store;
  wire        is_branch, is_brgt, is_jump;
  wire        is_brr_reg, is_brr_imm;
  wire        is_return, is_call;
  wire        is_halt;
  wire        is_mov_reg, is_mov_imm;
  wire [4:0]  rt_addr;

  // regfile => ALU/IF/mem
  // data1 = raddr1, data2 = raddr2, data3 = raddr3 (rt for brgt)
  wire [63:0] data1, data2, data3;

  // ALU => regfile/IF
  wire [63:0] alu_result;

  // mem => regfile/IF
  wire [63:0] mem_rdata;

  // regfile writeback data
  wire [63:0] wb_data;

  // mem ctrl
  wire [63:0] mem_data_addr;
  wire [63:0] mem_write_val;
  wire        mem_we;

  // halt latch
  reg         halted;
  always @(posedge clk) begin
    if (reset) halted <= 0;
    else if (is_halt) halted <= 1;
  end

  // call/return use r31 as stack pointer
  wire [63:0] r31_val   = reg_file.registers[31];
  wire [63:0] stack_top = r31_val - 64'd8;

  // ALU input mux
  // brgt:   a=data2(rs),  b=data3(rt)
  // brnz:   a=data1(rs),  b=unused
  // others: a=data1,      b=imm or data2
  wire [63:0] alu_a = is_brgt ? data2 : data1;
  wire [63:0] alu_b = is_brgt ? data3 : (use_imm ? immediate : data2);

  // mem ctrl
  assign mem_data_addr = (is_return || is_call) ? stack_top : (data1 + immediate);
  assign mem_write_val = is_call ? (pc + 64'd4) : data2;
  assign mem_we        = (is_store || is_call) && !halted;

  // writeback mux
  assign wb_data =
      is_load    ? mem_rdata :
      is_mov_reg ? data1     :
      is_mov_imm ? ((data1 & ~64'hFFF) | immediate) :
                   alu_result;

  // module instantiation

  // pc logic - IF owns the PC, computes next PC from regfile + ALU feedback
  fetch fetch_inst (
      .clk        (clk),
      .reset      (reset),
      .halt       (halted),
      .is_jump    (is_jump && !halted),
      .is_branch  (is_branch && !halted),
      .is_brgt    (is_brgt),
      .is_brr_reg (is_brr_reg),
      .is_brr_imm (is_brr_imm),
      .is_return  (is_return),
      .is_call    (is_call),
      .branch_cond(alu_result[0]),  // ALU => IF
      .data1      (data1),          // regfile => IF
      .data2      (data2),          // regfile => IF
      .immediate  (immediate),
      .mem_rdata  (mem_rdata),      // memory => IF (return address)
      .pc         (pc)
  );

  // memory: IF port + data port
  mem_module #(
      .MEM_SIZE(MEM_SIZE)
  ) memory (
      .clk       (clk),
      .fetch_addr(pc),
      .instr_out (instr),
      .data_addr (mem_data_addr),
      .write_data(mem_write_val),
      .we        (mem_we),
      .read_data (mem_rdata)
  );

  // IF => decoder
  decoder dec_inst (
      .instr     (instr),
      .raddr1    (raddr1),
      .raddr2    (raddr2),
      .waddr     (waddr),
      .immediate (immediate),
      .op        (op),
      .use_imm   (use_imm),
      .write     (write),
      .is_load   (is_load),
      .is_store  (is_store),
      .is_branch (is_branch),
      .is_brgt   (is_brgt),
      .is_jump   (is_jump),
      .is_brr_reg(is_brr_reg),
      .is_brr_imm(is_brr_imm),
      .is_return (is_return),
      .is_call   (is_call),
      .is_halt   (is_halt),
      .is_mov_reg(is_mov_reg),
      .is_mov_imm(is_mov_imm),
      .rt_addr   (rt_addr)
  );

  // decoder => regfile => ALU/IF
  // third read port (raddr3) carries rt for brgt comparison
  reg_file reg_file (
      .clk   (clk),
      .reset (reset),
      .raddr1(raddr1),
      .raddr2(raddr2),
      .raddr3(rt_addr),  // rt for brgt, 0 otherwise
      .waddr (waddr),
      .data  (wb_data),
      .write (write && !halted),
      .r1    (data1),
      .r2    (data2),
      .r3    (data3)
  );

  // regfile => ALU => IF/regfile/mem
  alu alu_inst (
      .a     (alu_a),
      .b     (alu_b),
      .op    (op),
      .result(alu_result)
  );

  // r31 initialized to top of memory on reset
  always @(posedge clk) begin
    if (reset) reg_file.registers[31] <= MEM_SIZE;
  end

endmodule