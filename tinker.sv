`define MEM_SIZE (512 * 1024)
`define PC_START 64'h2000

`include "hdl/alu.sv"
`include "hdl/regfile.sv"
`include "hdl/decoder.sv"
`include "hdl/fetch.sv"
`include "hdl/mem_module.sv"

// multicycle core
// S0 -> S1 -> S2 -> (S3)? -> (S4)?
module tinker_core (
    input clk,
    input reset,
    output logic hlt
);
  localparam MEM_SIZE = 512 * 1024;

  typedef enum logic [2:0] {
    S0  = 3'd0,
    S1  = 3'd1,
    S2  = 3'd2,
    S3 = 3'd3,
    S4  = 3'd4
  } state_t;

  state_t state;

  wire halted = hlt;

  // latch decoded signals at end of S1
  reg [31:0] IR;  // latched in S0

  // latched decoder outputs
  reg [ 4:0] latch_op;
  reg [ 4:0] latch_waddr;
  reg [63:0] latch_imm;
  reg latch_use_imm;
  reg latch_write;
  reg latch_is_load, latch_is_store;
  reg latch_is_branch, latch_is_brgt, latch_is_jump;
  reg latch_is_brr_reg, latch_is_brr_imm;
  reg latch_is_return, latch_is_call;
  reg latch_is_halt;
  reg latch_is_mov_reg, latch_is_mov_imm;

  // latched reg read values
  reg [63:0] latch_data1, latch_data2, latch_data3;

  // decoder wires
  wire [4:0] raddr1_w, raddr2_w, waddr_w, op_w, rt_addr_w;
  wire [63:0] immediate_w;
  wire use_imm_w, write_w;
  wire is_load_w, is_store_w;
  wire is_branch_w, is_brgt_w, is_jump_w;
  wire is_brr_reg_w, is_brr_imm_w;
  wire is_return_w, is_call_w;
  wire is_halt_w, is_mov_reg_w, is_mov_imm_w;

  // decode the latched IR
  decoder dec_inst (
      .instr     (IR),
      .raddr1    (raddr1_w),
      .raddr2    (raddr2_w),
      .waddr     (waddr_w),
      .immediate (immediate_w),
      .op        (op_w),
      .use_imm   (use_imm_w),
      .write     (write_w),
      .is_load   (is_load_w),
      .is_store  (is_store_w),
      .is_branch (is_branch_w),
      .is_brgt   (is_brgt_w),
      .is_jump   (is_jump_w),
      .is_brr_reg(is_brr_reg_w),
      .is_brr_imm(is_brr_imm_w),
      .is_return (is_return_w),
      .is_call   (is_call_w),
      .is_halt   (is_halt_w),
      .is_mov_reg(is_mov_reg_w),
      .is_mov_imm(is_mov_imm_w),
      .rt_addr   (rt_addr_w)
  );

  // regfile wires
  wire [63:0] data1_w, data2_w, data3_w;

  reg_file reg_file (
      .clk   (clk),
      .reset (reset),
      .raddr1(raddr1_w),
      .raddr2(raddr2_w),
      .raddr3(rt_addr_w),
      .waddr (latch_waddr),
      .data  (wb_data),
      .write (latch_write && (state == S4) && !halted),
      .r1    (data1_w),
      .r2    (data2_w),
      .r3    (data3_w)
  );

  // ALU w latched vals
  wire [63:0] alu_a = latch_is_brgt ? latch_data2 : latch_data1;
  wire [63:0] alu_b = latch_is_brgt ? latch_data3 : latch_use_imm ? latch_imm : latch_data2;
  wire [63:0] alu_result;

  alu alu_inst (
      .a     (alu_a),
      .b     (alu_b),
      .op    (latch_op),
      .result(alu_result)
  );

  // memory wires
  wire [63:0] pc;
  wire [31:0] instr_w; 
  wire [63:0] mem_rdata;

  wire [63:0] r31_val = reg_file.registers[31];
  wire [63:0] stack_top = r31_val - 64'd8;

  wire [63:0] mem_data_addr = (latch_is_return || latch_is_call)
                              ? stack_top
                              : (latch_data1 + latch_imm);

  wire [63:0] mem_write_val = latch_is_call ? pc : latch_data2;
  wire mem_we = (latch_is_store || latch_is_call) && (state == S3) && !halted;

  mem_module #(
      .MEM_SIZE(MEM_SIZE)
  ) memory (
      .clk       (clk),
      .fetch_addr(pc),
      .instr_out (instr_w),
      .data_addr (mem_data_addr),
      .write_data(mem_write_val),
      .we        (mem_we),
      .read_data (mem_rdata)
  );

  // writeback mux
  wire [63:0] wb_data =
      latch_is_load    ? mem_rdata :
      latch_is_mov_reg ? latch_data1 :
      latch_is_mov_imm ? ((latch_data1 & ~64'hFFF) | latch_imm) :
                         alu_result;

  // fetch / PC
  wire advance = (state == S0);  // advance PC only in S0

  fetch fetch_inst (
      .clk        (clk),
      .reset      (reset),
      .halt       (halted),
      .advance    (advance),
      .is_jump    (latch_is_jump && !halted && state == S2),
      .is_branch  (latch_is_branch && !halted && state == S2),
      .is_brgt    (latch_is_brgt),
      .is_brr_reg (latch_is_brr_reg),
      .is_brr_imm (latch_is_brr_imm),
      .is_return  (latch_is_return),
      .is_call    (latch_is_call),
      .branch_cond(alu_result[0]),
      .data1      (latch_data1),
      .data2      (latch_data2),
      .immediate  (latch_imm),
      .mem_rdata  (mem_rdata),
      .pc         (pc)
  );

  // FSM — w latched signlas
  wire needS3 = latch_is_load || latch_is_store || latch_is_call || latch_is_return;
  wire needS4  = latch_write && !latch_is_store && !latch_is_branch
                   && !latch_is_jump && !latch_is_halt;

  always @(posedge clk) begin
    if (reset) begin
      state <= S0;
    end else if (!halted) begin
      case (state)
        S0: state <= S1;
        S1: state <= S2;
        S2: state <= needS3 ? S3 : needS4 ? S4 : S0;
        S3: state <= needS4 ? S4 : S0;
        S4: state <= S0;
        default: state <= S0;
      endcase
    end
  end

  // latching
  // S0: latch fetched instr
  always @(posedge clk) begin
    if (state == S0 && !halted) IR <= instr_w;
  end

  // S1: latch decoded ctrl signals & reg read values
  always @(posedge clk) begin
    if (state == S1 && !halted) begin
      latch_op         <= op_w;
      latch_waddr      <= waddr_w;
      latch_imm        <= immediate_w;
      latch_use_imm    <= use_imm_w;
      latch_write      <= write_w;
      latch_is_load    <= is_load_w;
      latch_is_store   <= is_store_w;
      latch_is_branch  <= is_branch_w;
      latch_is_brgt    <= is_brgt_w;
      latch_is_jump    <= is_jump_w;
      latch_is_brr_reg <= is_brr_reg_w;
      latch_is_brr_imm <= is_brr_imm_w;
      latch_is_return  <= is_return_w;
      latch_is_call    <= is_call_w;
      latch_is_halt    <= is_halt_w;
      latch_is_mov_reg <= is_mov_reg_w;
      latch_is_mov_imm <= is_mov_imm_w;
      latch_data1      <= data1_w;
      latch_data2      <= data2_w;
      latch_data3      <= data3_w;
    end
  end

  // halt latch
  always @(posedge clk) begin
    if (reset) hlt <= 0;
    else if (latch_is_halt && state == S2) hlt <= 1;
  end

  // r31 stack ptr init
  always @(posedge clk) begin
    if (reset) reg_file.registers[31] <= MEM_SIZE;
  end

endmodule