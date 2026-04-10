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

  parameter S0 = 3'd0;
  parameter S1 = 3'd1;
  parameter S2 = 3'd2;
  parameter S3 = 3'd3;
  parameter S4 = 3'd4;

  reg [2:0] state;

  // ctrl signal latches
  reg is_load_r, is_store_r, is_call_r;
  reg is_branch_r, is_jump_r, is_halt_r;
  reg write_r, is_return_r;
  reg is_mov_reg_r, is_mov_imm_r;
  reg is_brgt_r, is_brr_reg_r, is_brr_imm_r;

  // state trans
  wire needS3 = is_load_r || is_store_r || is_call_r || is_return_r;
  wire needS4 = (write_r || is_call_r || is_return_r) &&
                !is_store_r && !is_branch_r && !is_jump_r && !is_halt_r;

  always @(posedge clk) begin
    if (reset) state <= S0;
    else if (!hlt) begin
      case (state)
        S0: state <= S1;
        S1: state <= S2;
        S2: state <= needS3 ? S3 : needS4 ? S4 : S0;
        S3: state <= needS4 ? S4 : S0;
        S4: state <= S0;
      endcase
    end
  end

  // IR latch
  reg [31:0] IR;
  always @(posedge clk) begin
    if (state == S0) IR <= instr;
  end
  wire [31:0] dec_instr = (state == S0) ? instr : IR;

  // wires
  wire [63:0] pc;
  wire [31:0] instr;
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

  wire [63:0] data1, data2, data3;
  wire [63:0] alu_result;
  wire [63:0] mem_rdata;

  // latch ctrl at S1
  always @(posedge clk) begin
    if (state == S1) begin
      is_load_r    <= is_load;
      is_store_r   <= is_store;
      is_call_r    <= is_call;
      is_branch_r  <= is_branch;
      is_jump_r    <= is_jump;
      is_halt_r    <= is_halt;
      write_r      <= write;
      is_return_r  <= is_return;
      is_mov_reg_r <= is_mov_reg;
      is_mov_imm_r <= is_mov_imm;
      is_brgt_r    <= is_brgt;
      is_brr_reg_r <= is_brr_reg;
      is_brr_imm_r <= is_brr_imm;
    end
  end

  // halt
  always @(posedge clk) begin
    if (reset) hlt <= 0;
    else if (is_halt_r) hlt <= 1;
  end

  // stack ptr (live wire into regfile)
  wire [63:0] r31_val = reg_file.registers[31];

  // -----------------------------------------------------------------------
  // PC latch — capture the PC at S1 so call can compute the correct
  // return address (call_pc + 4) even after the fetch has redirected.
  // -----------------------------------------------------------------------
  reg [63:0] pc_latch;
  always @(posedge clk) begin
    if (state == S1) pc_latch <= pc;
  end

  // alu
  wire [63:0] alu_a = is_brgt_r ? data2 : data1;
  wire [63:0] alu_b = is_brgt_r ? data3 : (use_imm ? immediate : data2);

  alu alu_inst (
      .a(alu_a),
      .b(alu_b),
      .op(op),
      .result(alu_result)
  );

  // -----------------------------------------------------------------------
  // Memory address / write-data latches
  //
  // We latch at S2 so that the address/data presented to the memory module
  // is stable throughout S3 (when the actual read or write happens).
  // Without this, r31_val could shift under us as soon as the S4 writeback
  // updates r31 on the next cycle.
  //
  // Address map:
  //   call   → write (pc_latch+4) to (SP-8);  SP-8 because call pre-decrements
  //   return → read from (SP-8);               SP was decremented by the matching call
  //   load/store → data1 + immediate
  // -----------------------------------------------------------------------
  reg [63:0] mem_addr_latch;
  reg [63:0] mem_wdata_latch;

  always @(posedge clk) begin
    if (state == S2) begin
      if (is_call_r) begin
        mem_addr_latch  <= r31_val - 64'd8;   // pre-decrement: write to new top-of-stack
        mem_wdata_latch <= pc_latch + 64'd4;  // return address = instruction after call
      end else if (is_return_r) begin
        mem_addr_latch  <= r31_val - 64'd8;   // read from top-of-stack (SP was decremented by call)
        mem_wdata_latch <= 64'd0;
      end else begin
        // normal load / store
        mem_addr_latch  <= data1 + immediate;
        mem_wdata_latch <= data2;
      end
    end
  end

  // mem_we: only fires during S3 for store and call
  wire mem_we = (is_store_r || is_call_r) && (state == S3) && !hlt;

  mem_module #(
      .MEM_SIZE(`MEM_SIZE)
  ) memory (
      .clk       (clk),
      .fetch_addr(pc),
      .instr_out (instr),
      .data_addr (mem_addr_latch),   // stable latched address
      .write_data(mem_wdata_latch),  // stable latched write-data
      .we        (mem_we),
      .read_data (mem_rdata)
  );

  // Latch mem_rdata at the end of S3 so that S4 and the fetch unit
  // see a stable value (mem_rdata is combinatorial off mem_addr_latch).
  reg [63:0] mem_out_reg;
  always @(posedge clk) begin
    if (state == S3) mem_out_reg <= mem_rdata;
  end

  // -----------------------------------------------------------------------
  // Writeback data / address / enable
  //
  //   load    → value read from memory
  //   call    → new SP = SP - 8   (write to r31)
  //   return  → new SP = SP + 8   (write to r31)
  //   mov_reg → pass-through data1
  //   mov_imm → upper bits of data1 OR'd with immediate
  //   default → ALU result
  // -----------------------------------------------------------------------
  wire [63:0] wb_data =
      is_load_r    ? mem_out_reg                      :
      is_call_r    ? (r31_val - 64'd8)                :
      is_return_r  ? (r31_val + 64'd8)                :
      is_mov_reg_r ? data1                            :
      is_mov_imm_r ? ((data1 & ~64'hFFF) | immediate) :
                     alu_result;

  wire [4:0] final_waddr     = (is_call_r || is_return_r) ? 5'd31 : waddr;
  wire       final_reg_write = (write_r || is_call_r || is_return_r) &&
                               (state == S4) && !hlt;

  // advance only when not doing a redirect this cycle
  wire advance = (state == S2) && !hlt &&
                 !is_branch_r && !is_jump_r && !is_call_r && !is_return_r;

  // -----------------------------------------------------------------------
  // Fetch — PC redirect timing
  //
  //   call   : redirect at S2 (target = data1, the register operand)
  //   return : redirect at S3, using mem_rdata which is combinatorially
  //            valid because mem_addr_latch was set at end-of-S2 and the
  //            memory read port is asynchronous.
  //            We pass mem_rdata (not mem_out_reg) so the redirect happens
  //            one cycle earlier, before the latch closes at end-of-S3.
  // -----------------------------------------------------------------------
  fetch fetch_inst (
      .clk       (clk),
      .reset     (reset),
      .halt      (hlt),
      .advance   (advance),
      .is_jump   (is_jump_r    && (state == S2)),
      .is_branch (is_branch_r  && (state == S2)),
      .is_brgt   (is_brgt_r),
      .is_brr_reg(is_brr_reg_r),
      .is_brr_imm(is_brr_imm_r),
      .is_return (is_return_r  && (state == S3)),  // combinatorial mem_rdata valid here
      .is_call   (is_call_r    && (state == S2)),
      .branch_cond(alu_result[0]),
      .data1     (data1),
      .data2     (data2),
      .immediate (immediate),
      .mem_rdata (mem_rdata),   // combinatorial — valid during S3
      .pc        (pc)
  );

  decoder dec_inst (
      .instr    (dec_instr),
      .raddr1   (raddr1),
      .raddr2   (raddr2),
      .waddr    (waddr),
      .immediate(immediate),
      .op       (op),
      .use_imm  (use_imm),
      .write    (write),
      .is_load  (is_load),
      .is_store (is_store),
      .is_branch(is_branch),
      .is_brgt  (is_brgt),
      .is_jump  (is_jump),
      .is_brr_reg(is_brr_reg),
      .is_brr_imm(is_brr_imm),
      .is_return(is_return),
      .is_call  (is_call),
      .is_halt  (is_halt),
      .is_mov_reg(is_mov_reg),
      .is_mov_imm(is_mov_imm),
      .rt_addr  (rt_addr)
  );

  reg_file reg_file (
      .clk   (clk),
      .reset (reset),
      .raddr1(raddr1),
      .raddr2(raddr2),
      .raddr3(rt_addr),
      .waddr (final_waddr),
      .data  (wb_data),
      .write (final_reg_write),
      .r1    (data1),
      .r2    (data2),
      .r3    (data3)
  );

endmodule