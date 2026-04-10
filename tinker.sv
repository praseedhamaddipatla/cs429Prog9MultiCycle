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

  // -----------------------------------------------------------------------
  // State transitions
  // call  : needs S3 (write to Mem[r31-8]) then S4 (redirect PC — no reg wb)
  // return: needs S3 (read  from Mem[r31-8]) then S4 (redirect PC — no reg wb)
  // Neither modifies a register so needS4 only fires for them to allow the
  // fetch redirect at S4.
  // -----------------------------------------------------------------------
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

  // live SP wire — read-only, never written by call/return
  wire [63:0] r31_val = reg_file.registers[31];

  // PC latch — capture at S1 for call's return-address: Mem[r31-8] = pc+4
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
  // Memory address / write-data — combinatorial, matching friend's design.
  //
  // ISA:
  //   call:   Mem[r31-8] = pc+4  (write)   pc <- rd   (no SP change)
  //   return: pc <- Mem[r31-8]   (read)              (no SP change)
  //   load:   rd = Mem[rs + L]   (read)
  //   store:  Mem[rd + L] = rs   (write)
  // -----------------------------------------------------------------------
  wire [63:0] mem_data_addr =
      (is_call_r || is_return_r) ? (r31_val - 64'd8) :
                                   (data1 + immediate);

  wire [63:0] mem_write_val =
      is_call_r ? (pc_latch + 64'd4) :
                  data2;

  // write fires at S3 for call and store
  wire mem_we = (is_store_r || is_call_r) && (state == S3) && !hlt;

  mem_module #(
      .MEM_SIZE(`MEM_SIZE)
  ) memory (
      .clk       (clk),
      .fetch_addr(pc),
      .instr_out (instr),
      .data_addr (mem_data_addr),
      .write_data(mem_write_val),
      .we        (mem_we),
      .read_data (mem_rdata)
  );

  // Latch mem_rdata at end of S3 so S4 has a stable return address
  reg [63:0] mem_out_reg;
  always @(posedge clk) begin
    if (state == S3) mem_out_reg <= mem_rdata;
  end

  // -----------------------------------------------------------------------
  // Writeback
  //   call    → NO register write (SP unchanged per ISA)
  //   return  → NO register write (SP unchanged per ISA)
  //   load    → rd = mem_out_reg
  //   mov_reg → rd = data1
  //   mov_imm → rd = (data1 & ~0xFFF) | immediate
  //   default → rd = alu_result
  // -----------------------------------------------------------------------
  wire [63:0] wb_data =
      is_load_r    ? mem_out_reg                       :
      is_mov_reg_r ? data1                             :
      is_mov_imm_r ? ((data1 & ~64'hFFF) | immediate)  :
                     alu_result;

  // call and return do NOT write any register
  wire [4:0] final_waddr     = waddr;
  wire       final_reg_write = write_r && !is_call_r && !is_return_r &&
                               (state == S4) && !hlt;

  // advance PC only when not doing a redirect this cycle
  wire advance = (state == S2) && !hlt &&
                 !is_branch_r && !is_jump_r && !is_call_r && !is_return_r;

  // -----------------------------------------------------------------------
  // Fetch — redirect timing
  //   call:   fires at S2, target = data1 (rd register value)
  //   return: fires at S4, target = mem_out_reg (latched from S3 read)
  // -----------------------------------------------------------------------
  fetch fetch_inst (
      .clk        (clk),
      .reset      (reset),
      .halt       (hlt),
      .advance    (advance),
      .is_jump    (is_jump_r    && (state == S2)),
      .is_branch  (is_branch_r  && (state == S2)),
      .is_brgt    (is_brgt_r),
      .is_brr_reg (is_brr_reg_r),
      .is_brr_imm (is_brr_imm_r),
      .is_return  (is_return_r  && (state == S4)),  // use stable mem_out_reg
      .is_call    (is_call_r    && (state == S2)),
      .branch_cond(alu_result[0]),
      .data1      (data1),
      .data2      (data2),
      .immediate  (immediate),
      .mem_rdata  (mem_out_reg),   // latched, stable at S4
      .pc         (pc)
  );

  decoder dec_inst (
      .instr      (dec_instr),
      .raddr1     (raddr1),
      .raddr2     (raddr2),
      .waddr      (waddr),
      .immediate  (immediate),
      .op         (op),
      .use_imm    (use_imm),
      .write      (write),
      .is_load    (is_load),
      .is_store   (is_store),
      .is_branch  (is_branch),
      .is_brgt    (is_brgt),
      .is_jump    (is_jump),
      .is_brr_reg (is_brr_reg),
      .is_brr_imm (is_brr_imm),
      .is_return  (is_return),
      .is_call    (is_call),
      .is_halt    (is_halt),
      .is_mov_reg (is_mov_reg),
      .is_mov_imm (is_mov_imm),
      .rt_addr    (rt_addr)
  );

  reg_file reg_file (
      .clk    (clk),
      .reset  (reset),
      .raddr1 (raddr1),
      .raddr2 (raddr2),
      .raddr3 (rt_addr),
      .waddr  (final_waddr),
      .data   (wb_data),
      .write  (final_reg_write),
      .r1     (data1),
      .r2     (data2),
      .r3     (data3)
  );

endmodule