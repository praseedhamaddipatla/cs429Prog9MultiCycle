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
    input reset,
    output logic hlt
);
  localparam MEM_SIZE = 512 * 1024;

  // fsm for multi cycle
  typedef enum logic [2:0] {
    S_IF  = 3'd0,
    S_ID  = 3'd1,
    S_EX  = 3'd2,
    S_MEM = 3'd3,
    S_WB  = 3'd4
  } state_t;

  state_t state;

  // halted is the gating signal derived from the hlt output register
  wire halted = hlt;

  // needs_mem and needs_wb computed locally from decoder outputs
  // is_call included in needs_mem because call must write the return address to memory
  wire needs_mem = is_load || is_store || is_call;
  wire needs_wb  = !is_store && !is_branch && !is_jump && !is_halt;

  // next state logic
  always @(posedge clk) begin
    if (reset) begin
      state <= S_IF;
    end else begin
      case (state)
        S_IF:  state <= S_ID;
        S_ID:  state <= S_EX;
        S_EX:  state <= needs_mem ? S_MEM : needs_wb ? S_WB : S_IF;
        S_MEM: state <= needs_wb ? S_WB : S_IF;
        S_WB:  state <= S_IF;
      endcase
    end
  end

  // inter state regs (latches)
  reg [31:0] IR;  // instruction register (from IF)
  reg [63:0] PC_next;  // PC+8, computed in IF, used for branches

  // decoded fields (from ID)
  reg [ 4:0] dec_opcode;
  reg [4:0] dec_rd, dec_rs, dec_rt;
  reg [11:0] dec_L;
  reg [63:0] dec_A, dec_B;  // register values read in ID

  // execution result (from EX)
  reg  [63:0] ALU_OUT;
  reg  [63:0] MEM_DATA;  // data read from memory in MEM

  // latch the instruction in S_IF so it stays stable through all stages
  always @(posedge clk) begin
    if (state == S_IF)
      IR <= instr;
  end

  // wires to connect modules

  // IF => decoder: feed IR during ID/EX/MEM/WB, live instr only during IF
  wire [31:0] dec_instr = (state == S_IF) ? instr : IR;

  // IF => decoder
  wire [63:0] pc;
  wire [31:0] instr;

  // decoder outputs
  wire [4:0] raddr1, raddr2, waddr;
  wire [63:0] immediate;
  wire [ 4:0] op;
  wire use_imm, write;
  wire is_load, is_store;
  wire is_branch, is_brgt, is_jump;
  wire is_brr_reg, is_brr_imm;
  wire is_return, is_call;
  wire is_halt;
  wire is_mov_reg, is_mov_imm;
  wire [4:0] rt_addr;

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

  // halt latch - only latch halt in S_EX so it fires exactly once per instruction
  always @(posedge clk) begin
    if (reset) hlt <= 0;
    else if (is_halt && state == S_EX) hlt <= 1;
  end

  // call/return use r31 as stack pointer
  wire [63:0] r31_val = reg_file.registers[31];
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
  // memory write only fires in S_MEM
  assign mem_we = (is_store || is_call) && (state == S_MEM) && !halted;

  // writeback mux
  assign wb_data =
      is_load    ? mem_rdata :
      is_mov_reg ? data1     :
      is_mov_imm ? ((data1 & ~64'hFFF) | immediate) :
                   alu_result;

  // module instantiation

  // pc logic - IF owns the PC, computes next PC from regfile + ALU feedback
  // fetch only advances PC when we are in S_EX so it moves exactly once per instruction
  fetch fetch_inst (
      .clk        (clk),
      .reset      (reset),
      .halt       (halted),
      .is_jump    (is_jump    && !halted && state == S_EX),
      .is_branch  (is_branch  && !halted && state == S_EX),
      .is_brgt    (is_brgt),
      .is_brr_reg (is_brr_reg),
      .is_brr_imm (is_brr_imm),
      .is_return  (is_return),
      .is_call    (is_call),
      .branch_cond(alu_result[0]),         // ALU => IF
      .data1      (data1),                 // regfile => IF
      .data2      (data2),                 // regfile => IF
      .immediate  (immediate),
      .mem_rdata  (mem_rdata),             // memory => IF (return address)
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

  // IF => decoder: use the latched IR after S_IF so decoded signals stay
  // stable while PC has already moved to the next instruction
  decoder dec_inst (
      .instr     (dec_instr),
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
      .raddr3(rt_addr),           // rt for brgt, 0 otherwise
      .waddr (waddr),
      .data  (wb_data),
      // register write only fires in S_WB
      .write (write && (state == S_WB) && !halted),
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