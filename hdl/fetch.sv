// instr fetch & pc control
module fetch (
    input clk,
    input reset,
    input halt,
    input advance,

    // decoded instr type
    input is_jump,
    input is_branch,
    input is_brgt,
    input is_brr_reg,
    input is_brr_imm,
    input is_return,
    input is_call,

    // branch condition from ALU (1 = taken)
    input branch_cond,

    // register values for target computation from regfile
    input [63:0] data1,  // raddr1 value
    input [63:0] data2,  // raddr2 value

    // immediate from decoder
    input [63:0] immediate,

    // return address popped from stack
    input [63:0] mem_rdata,

    output [63:0] pc
);
  reg [63:0] pc_reg;
  assign pc = pc_reg;

  // branch is taken if ALU says so (brnz/brgt) or if unconditional jump
  wire taken = (is_branch && branch_cond) || is_jump || is_call || is_return;

  //mux
  wire [63:0] next_pc =
      is_return              ? mem_rdata            :  // return: target from stack
      is_brr_imm             ? (pc_reg + immediate) :  // brr L: pc-relative imm
      is_brr_reg             ? (pc_reg + data1)     :  // brr rd: pc-relative reg
      (is_branch && is_brgt) ? data1                :  // brgt: target in rd
      is_branch              ? data2                :  // brnz: target in rd (raddr2)
                               data1;                  // br/call: target in rd

  always @(posedge clk) begin
    if (reset) begin
      pc_reg <= `PC_START;
    end else if (!halt) begin
      if (taken) begin
        if (next_pc >= `MEM_SIZE) pc_reg <= `PC_START;
        else pc_reg <= next_pc;
      end else if (advance) begin
        if (pc_reg + 64'd4 >= `MEM_SIZE) pc_reg <= `PC_START;
        else pc_reg <= pc_reg + 64'd4;
      end
    end
  end
endmodule