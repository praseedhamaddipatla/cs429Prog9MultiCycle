// tb_tinker.v — integration tests for the full tinker_core cpu
// covers reset, int arithmetic, logic, shifts, data mov, control flow, fp
module tb_tinker;

  reg clk, reset;

  tinker_core cpu (
      .clk  (clk),
      .reset(reset)
  );

  always #5 clk = ~clk;

  integer pass_count, fail_count, i;

  // instruction encoding: opcode[31:27] rd[26:22] rs[21:17] rt[16:12] imm[11:0]
  function [31:0] make_add;
    input [4:0] rd, rs, rt;
    make_add = (5'h18 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_addi;
    input [4:0] rd;
    input [11:0] im;
    make_addi = (5'h19 << 27) | (rd << 22) | im;
  endfunction
  function [31:0] make_sub;
    input [4:0] rd, rs, rt;
    make_sub = (5'h1A << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_subi;
    input [4:0] rd;
    input [11:0] im;
    make_subi = (5'h1B << 27) | (rd << 22) | im;
  endfunction
  function [31:0] make_mul;
    input [4:0] rd, rs, rt;
    make_mul = (5'h1C << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_div;
    input [4:0] rd, rs, rt;
    make_div = (5'h1D << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_and;
    input [4:0] rd, rs, rt;
    make_and = (5'h00 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_or;
    input [4:0] rd, rs, rt;
    make_or = (5'h01 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_xor;
    input [4:0] rd, rs, rt;
    make_xor = (5'h02 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_not;
    input [4:0] rd, rs;
    make_not = (5'h03 << 27) | (rd << 22) | (rs << 17);
  endfunction
  function [31:0] make_shftr;
    input [4:0] rd, rs, rt;
    make_shftr = (5'h04 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_shftri;
    input [4:0] rd;
    input [11:0] im;
    make_shftri = (5'h05 << 27) | (rd << 22) | im;
  endfunction
  function [31:0] make_shftl;
    input [4:0] rd, rs, rt;
    make_shftl = (5'h06 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_shftli;
    input [4:0] rd;
    input [11:0] im;
    make_shftli = (5'h07 << 27) | (rd << 22) | im;
  endfunction
  function [31:0] make_br;
    input [4:0] rd;
    make_br = (5'h08 << 27) | (rd << 22);
  endfunction
  function [31:0] make_brr_imm;
    input [11:0] im;
    make_brr_imm = (5'h0A << 27) | im;
  endfunction
  function [31:0] make_brnz;
    input [4:0] rd, rs;
    make_brnz = (5'h0B << 27) | (rd << 22) | (rs << 17);
  endfunction
  function [31:0] make_call;
    input [4:0] rd;
    make_call = (5'h0C << 27) | (rd << 22);
  endfunction
  function [31:0] make_return;
    make_return = (5'h0D << 27);
  endfunction
  function [31:0] make_brgt;
    input [4:0] rd, rs, rt;
    make_brgt = (5'h0E << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_halt;
    make_halt = (5'h0F << 27);
  endfunction
  function [31:0] make_load;
    input [4:0] rd, rs;
    input [11:0] im;
    make_load = (5'h10 << 27) | (rd << 22) | (rs << 17) | im;
  endfunction
  function [31:0] make_mov_reg;
    input [4:0] rd, rs;
    make_mov_reg = (5'h11 << 27) | (rd << 22) | (rs << 17);
  endfunction
  function [31:0] make_mov_imm;
    input [4:0] rd;
    input [11:0] im;
    make_mov_imm = (5'h12 << 27) | (rd << 22) | im;
  endfunction
  function [31:0] make_store;
    input [4:0] rd, rs;
    input [11:0] im;
    make_store = (5'h13 << 27) | (rd << 22) | (rs << 17) | im;
  endfunction
  function [31:0] make_addf;
    input [4:0] rd, rs, rt;
    make_addf = (5'h14 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_subf;
    input [4:0] rd, rs, rt;
    make_subf = (5'h15 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_mulf;
    input [4:0] rd, rs, rt;
    make_mulf = (5'h16 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction
  function [31:0] make_divf;
    input [4:0] rd, rs, rt;
    make_divf = (5'h17 << 27) | (rd << 22) | (rs << 17) | (rt << 12);
  endfunction

  task write_instr;
    input [63:0] addr;
    input [31:0] word;
    begin
      cpu.memory.bytes[addr]   = word[7:0];
      cpu.memory.bytes[addr+1] = word[15:8];
      cpu.memory.bytes[addr+2] = word[23:16];
      cpu.memory.bytes[addr+3] = word[31:24];
    end
  endtask

  task write_mem64;
    input [63:0] addr, val;
    begin
      cpu.memory.bytes[addr]   = val[7:0];
      cpu.memory.bytes[addr+1] = val[15:8];
      cpu.memory.bytes[addr+2] = val[23:16];
      cpu.memory.bytes[addr+3] = val[31:24];
      cpu.memory.bytes[addr+4] = val[39:32];
      cpu.memory.bytes[addr+5] = val[47:40];
      cpu.memory.bytes[addr+6] = val[55:48];
      cpu.memory.bytes[addr+7] = val[63:56];
    end
  endtask

  task check_reg;
    input [63:0] expected, got;
    input integer tid;
    begin
      if (got === expected) begin
        $display("  pass [%0d]: got 0x%016h", tid, got);
        pass_count = pass_count + 1;
      end else begin
        $display("  FAIL [%0d]: got 0x%016h  expected 0x%016h", tid, got, expected);
        fail_count = fail_count + 1;
      end
    end
  endtask

  task do_reset;
    integer j;
    begin
      reset = 1;
      for (j = 0; j < 512; j = j + 1) cpu.memory.bytes[64'h2000+j] = 8'h00;
      @(posedge clk);
      @(posedge clk);
      reset = 0;
    end
  endtask

  task run_cycles;
    input integer n;
    integer j;
    begin
      for (j = 0; j < n; j = j + 1) @(posedge clk);
    end
  endtask

  // load two fp values into r2/r3 from data mem at 0x1000/0x1008
  task fp_load_pair;
    input [63:0] va, vb;
    begin
      write_mem64(64'h1000, va);
      write_mem64(64'h1008, vb);
      write_instr(64'h2000, make_addi(5'd1, 12'h1));
      write_instr(64'h2004, make_shftli(5'd1, 12'd12));  // r1=0x1000
      write_instr(64'h2008, make_load(5'd2, 5'd1, 12'd0));  // r2=va
      write_instr(64'h200C, make_load(5'd3, 5'd1, 12'd8));  // r3=vb
    end
  endtask

  initial begin
    $dumpfile("sim/tb_tinker.vcd");
    $dumpvars(0, tb_tinker);
    clk = 0;
    reset = 1;
    pass_count = 0;
    fail_count = 0;
    @(posedge clk);
    @(posedge clk);
    reset = 0;

    // reset state
    $display("\n--- reset state ---");
    begin
      integer all_zero;
      all_zero = 1;
      for (i = 0; i < 31; i = i + 1) if (cpu.reg_file.registers[i] !== 64'd0) all_zero = 0;
      if (all_zero) begin
        $display("  pass [r0-r30_zero]");
        pass_count = pass_count + 1;
      end else begin
        $display("  FAIL [r0-r30_zero]");
        fail_count = fail_count + 1;
      end
    end
    check_reg(64'd524288, cpu.reg_file.registers[31], 0);  // r31=stack ptr

    // int arithmetic
    $display("\n--- int arithmetic ---");

    do_reset();  // add: 20+30=50
    write_instr(64'h2000, make_addi(5'd1, 12'd20));
    write_instr(64'h2004, make_addi(5'd2, 12'd30));
    write_instr(64'h2008, make_add(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'd50, cpu.reg_file.registers[3], 1);

    do_reset();  // addi neg: 10+(-3)=7
    write_instr(64'h2000, make_addi(5'd1, 12'd10));
    write_instr(64'h2004, make_addi(5'd1, 12'hFFD));
    write_instr(64'h2008, make_halt());
    run_cycles(6);
    check_reg(64'd7, cpu.reg_file.registers[1], 2);

    do_reset();  // sub: 100-40=60
    write_instr(64'h2000, make_addi(5'd1, 12'd100));
    write_instr(64'h2004, make_addi(5'd2, 12'd40));
    write_instr(64'h2008, make_sub(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'd60, cpu.reg_file.registers[3], 3);

    do_reset();  // subi: 50-7=43
    write_instr(64'h2000, make_addi(5'd1, 12'd50));
    write_instr(64'h2004, make_subi(5'd1, 12'd7));
    write_instr(64'h2008, make_halt());
    run_cycles(6);
    check_reg(64'd43, cpu.reg_file.registers[1], 4);

    do_reset();  // mul: 6*7=42
    write_instr(64'h2000, make_addi(5'd1, 12'd6));
    write_instr(64'h2004, make_addi(5'd2, 12'd7));
    write_instr(64'h2008, make_mul(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'd42, cpu.reg_file.registers[3], 5);

    do_reset();  // mul by zero
    write_instr(64'h2000, make_addi(5'd1, 12'd99));
    write_instr(64'h2004, make_addi(5'd2, 12'd0));
    write_instr(64'h2008, make_mul(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'd0, cpu.reg_file.registers[3], 6);

    do_reset();  // div: 100/4=25
    write_instr(64'h2000, make_addi(5'd1, 12'd100));
    write_instr(64'h2004, make_addi(5'd2, 12'd4));
    write_instr(64'h2008, make_div(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'd25, cpu.reg_file.registers[3], 7);

    do_reset();  // sub wraps: 5-10=0xFFFFFFFFFFFFFFFB
    write_instr(64'h2000, make_addi(5'd1, 12'd5));
    write_instr(64'h2004, make_addi(5'd2, 12'd10));
    write_instr(64'h2008, make_sub(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'hFFFFFFFFFFFFFFFB, cpu.reg_file.registers[3], 8);

    // logic
    $display("\n--- logic ---");

    do_reset();  // and: 0xF0 & 0xFF = 0xF0
    write_instr(64'h2000, make_addi(5'd1, 12'hF0));
    write_instr(64'h2004, make_addi(5'd2, 12'hFF));
    write_instr(64'h2008, make_and(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'hF0, cpu.reg_file.registers[3], 9);

    do_reset();  // or: 0xF0 | 0x0F = 0xFF
    write_instr(64'h2000, make_addi(5'd1, 12'hF0));
    write_instr(64'h2004, make_addi(5'd2, 12'h0F));
    write_instr(64'h2008, make_or(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'hFF, cpu.reg_file.registers[3], 10);

    do_reset();  // xor: 0xFF ^ 0x0F = 0xF0
    write_instr(64'h2000, make_addi(5'd1, 12'hFF));
    write_instr(64'h2004, make_addi(5'd2, 12'h0F));
    write_instr(64'h2008, make_xor(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'hF0, cpu.reg_file.registers[3], 11);

    do_reset();  // not: ~0 = 0xFFFF...
    write_instr(64'h2000, make_addi(5'd1, 12'd0));
    write_instr(64'h2004, make_not(5'd2, 5'd1));
    write_instr(64'h2008, make_halt());
    run_cycles(6);
    check_reg(64'hFFFFFFFFFFFFFFFF, cpu.reg_file.registers[2], 12);

    // shifts
    $display("\n--- shifts ---");

    do_reset();  // shftri: 0x80>>3=0x10
    write_instr(64'h2000, make_addi(5'd1, 12'h80));
    write_instr(64'h2004, make_shftri(5'd1, 12'd3));
    write_instr(64'h2008, make_halt());
    run_cycles(6);
    check_reg(64'h10, cpu.reg_file.registers[1], 13);

    do_reset();  // shftli: 1<<8=256
    write_instr(64'h2000, make_addi(5'd1, 12'd1));
    write_instr(64'h2004, make_shftli(5'd1, 12'd8));
    write_instr(64'h2008, make_halt());
    run_cycles(6);
    check_reg(64'd256, cpu.reg_file.registers[1], 14);

    do_reset();  // shftr reg: 0x40>>2=0x10
    write_instr(64'h2000, make_addi(5'd1, 12'h40));
    write_instr(64'h2004, make_addi(5'd2, 12'd2));
    write_instr(64'h2008, make_shftr(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'h10, cpu.reg_file.registers[3], 15);

    do_reset();  // shftl reg: 1<<4=16
    write_instr(64'h2000, make_addi(5'd1, 12'd1));
    write_instr(64'h2004, make_addi(5'd2, 12'd4));
    write_instr(64'h2008, make_shftl(5'd3, 5'd1, 5'd2));
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'd16, cpu.reg_file.registers[3], 16);

    // data movement
    $display("\n--- data mov ---");

    do_reset();  // mov reg: r2=r1=99
    write_instr(64'h2000, make_addi(5'd1, 12'd99));
    write_instr(64'h2004, make_mov_reg(5'd2, 5'd1));
    write_instr(64'h2008, make_halt());
    run_cycles(6);
    check_reg(64'd99, cpu.reg_file.registers[2], 17);

    do_reset();  // mov imm: lower 12 bits only
    write_instr(64'h2000, make_mov_imm(5'd1, 12'hABC));
    write_instr(64'h2004, make_halt());
    run_cycles(5);
    check_reg(64'hABC, cpu.reg_file.registers[1], 18);

    do_reset();  // mov imm preserves upper bits
    write_instr(64'h2000, make_addi(5'd1, 12'hFFF));
    write_instr(64'h2004, make_mov_imm(5'd1, 12'h123));
    write_instr(64'h2008, make_halt());
    run_cycles(6);
    check_reg(64'hFFFFFFFFFFFFF123, cpu.reg_file.registers[1], 19);

    do_reset();  // store/load offset 0
    write_instr(64'h2000, make_addi(5'd1, 12'h100));
    write_instr(64'h2004, make_addi(5'd2, 12'd55));
    write_instr(64'h2008, make_store(5'd1, 5'd2, 12'd0));
    write_instr(64'h200C, make_load(5'd3, 5'd1, 12'd0));
    write_instr(64'h2010, make_halt());
    run_cycles(10);
    check_reg(64'd55, cpu.reg_file.registers[3], 20);

    do_reset();  // store/load nonzero offset
    write_instr(64'h2000, make_addi(5'd1, 12'h100));
    write_instr(64'h2004, make_addi(5'd2, 12'd42));
    write_instr(64'h2008, make_store(5'd1, 5'd2, 12'd8));
    write_instr(64'h200C, make_load(5'd3, 5'd1, 12'd8));
    write_instr(64'h2010, make_halt());
    run_cycles(10);
    check_reg(64'd42, cpu.reg_file.registers[3], 21);

    do_reset();  // store overwrite: write 11 then 99, load=99
    write_instr(64'h2000, make_addi(5'd1, 12'h100));
    write_instr(64'h2004, make_addi(5'd2, 12'd11));
    write_instr(64'h2008, make_store(5'd1, 5'd2, 12'd0));
    write_instr(64'h200C, make_addi(5'd2, 12'd88));  // r2=11+88=99
    write_instr(64'h2010, make_store(5'd1, 5'd2, 12'd0));
    write_instr(64'h2014, make_load(5'd3, 5'd1, 12'd0));
    write_instr(64'h2018, make_halt());
    run_cycles(14);
    check_reg(64'd99, cpu.reg_file.registers[3], 22);

    // control flow
    $display("\n--- control flow ---");

    do_reset();  // br: skip addi, r1 stays 0
    write_instr(64'h2000, make_addi(5'd1, 12'd0));
    write_instr(64'h2004, make_addi(5'd4, 12'h1C));
    write_instr(64'h2008, make_addi(5'd5, 12'd1));
    write_instr(64'h200C, make_shftli(5'd5, 12'd13));  // r5=0x2000
    write_instr(64'h2010, make_add(5'd4, 5'd4, 5'd5));  // r4=0x201C
    write_instr(64'h2014, make_br(5'd4));
    write_instr(64'h2018, make_addi(5'd1, 12'd99));  // skipped
    write_instr(64'h201C, make_halt());
    run_cycles(16);
    check_reg(64'd0, cpu.reg_file.registers[1], 23);

    do_reset();  // brnz taken: r2 stays 0
    write_instr(64'h2000, make_addi(5'd1, 12'd1));
    write_instr(64'h2004, make_addi(5'd2, 12'd0));
    write_instr(64'h2008, make_addi(5'd5, 12'd1));
    write_instr(64'h200C, make_shftli(5'd5, 12'd13));
    write_instr(64'h2010, make_addi(5'd4, 12'h20));
    write_instr(64'h2014, make_add(5'd4, 5'd4, 5'd5));  // r4=0x2020
    write_instr(64'h2018, make_brnz(5'd4, 5'd1));
    write_instr(64'h201C, make_addi(5'd2, 12'd99));  // skipped
    write_instr(64'h2020, make_halt());
    run_cycles(18);
    check_reg(64'd0, cpu.reg_file.registers[2], 24);

    do_reset();  // brnz not taken: r2=55
    write_instr(64'h2000, make_addi(5'd1, 12'd0));
    write_instr(64'h2004, make_addi(5'd2, 12'd0));
    write_instr(64'h2008, make_addi(5'd5, 12'd1));
    write_instr(64'h200C, make_shftli(5'd5, 12'd13));
    write_instr(64'h2010, make_addi(5'd4, 12'h1C));
    write_instr(64'h2014, make_add(5'd4, 5'd4, 5'd5));
    write_instr(64'h2018, make_brnz(5'd4, 5'd1));  // r1=0, not taken
    write_instr(64'h201C, make_addi(5'd2, 12'd55));
    write_instr(64'h2020, make_halt());
    run_cycles(18);
    check_reg(64'd55, cpu.reg_file.registers[2], 25);

    do_reset();  // brgt taken: r1=10>r2=3, r6 stays 0
    write_instr(64'h2000, make_addi(5'd1, 12'd10));
    write_instr(64'h2004, make_addi(5'd2, 12'd3));
    write_instr(64'h2008, make_addi(5'd6, 12'd0));
    write_instr(64'h200C, make_addi(5'd5, 12'd1));
    write_instr(64'h2010, make_shftli(5'd5, 12'd13));
    write_instr(64'h2014, make_addi(5'd4, 12'h24));
    write_instr(64'h2018, make_add(5'd4, 5'd4, 5'd5));
    write_instr(64'h201C, make_brgt(5'd4, 5'd1, 5'd2));
    write_instr(64'h2020, make_addi(5'd6, 12'd99));  // skipped
    write_instr(64'h2024, make_halt());
    run_cycles(18);
    check_reg(64'd0, cpu.reg_file.registers[6], 26);

    do_reset();  // brgt not taken: r1=3 not > r2=10, r6=77
    write_instr(64'h2000, make_addi(5'd1, 12'd3));
    write_instr(64'h2004, make_addi(5'd2, 12'd10));
    write_instr(64'h2008, make_addi(5'd6, 12'd0));
    write_instr(64'h200C, make_addi(5'd5, 12'd1));
    write_instr(64'h2010, make_shftli(5'd5, 12'd13));
    write_instr(64'h2014, make_addi(5'd4, 12'h24));
    write_instr(64'h2018, make_add(5'd4, 5'd4, 5'd5));
    write_instr(64'h201C, make_brgt(5'd4, 5'd1, 5'd2));
    write_instr(64'h2020, make_addi(5'd6, 12'd77));
    write_instr(64'h2024, make_halt());
    run_cycles(18);
    check_reg(64'd77, cpu.reg_file.registers[6], 27);

    do_reset();  // brr imm: skip one instr, r1 stays 0
    write_instr(64'h2000, make_addi(5'd1, 12'd0));
    write_instr(64'h2004, make_brr_imm(12'd8));  // pc=0x2004+8=0x200C
    write_instr(64'h2008, make_addi(5'd1, 12'd99));  // skipped
    write_instr(64'h200C, make_halt());
    run_cycles(8);
    check_reg(64'd0, cpu.reg_file.registers[1], 28);

    do_reset();  // call/return: subroutine sets r1=42
    write_instr(64'h2000, make_addi(5'd5, 12'd1));
    write_instr(64'h2004, make_shftli(5'd5, 12'd13));  // r5=0x2000
    write_instr(64'h2008, make_addi(5'd4, 12'h18));
    write_instr(64'h200C, make_add(5'd4, 5'd4, 5'd5));  // r4=0x2018
    write_instr(64'h2010, make_call(5'd4));
    write_instr(64'h2014, make_halt());  // return lands here
    write_instr(64'h2018, make_addi(5'd1, 12'd42));
    write_instr(64'h201C, make_return());
    run_cycles(20);
    check_reg(64'd42, cpu.reg_file.registers[1], 29);

    // floating point
    $display("\n--- floating point ---");

    do_reset();  // addf: 1.0+2.0=3.0
    fp_load_pair(64'h3FF0000000000000, 64'h4000000000000000);
    write_instr(64'h2010, make_addf(5'd4, 5'd2, 5'd3));
    write_instr(64'h2014, make_halt());
    run_cycles(14);
    check_reg(64'h4008000000000000, cpu.reg_file.registers[4], 30);

    do_reset();  // subf: 3.0-1.0=2.0
    fp_load_pair(64'h4008000000000000, 64'h3FF0000000000000);
    write_instr(64'h2010, make_subf(5'd4, 5'd2, 5'd3));
    write_instr(64'h2014, make_halt());
    run_cycles(14);
    check_reg(64'h4000000000000000, cpu.reg_file.registers[4], 31);

    do_reset();  // mulf: 2.0*3.0=6.0
    fp_load_pair(64'h4000000000000000, 64'h4008000000000000);
    write_instr(64'h2010, make_mulf(5'd4, 5'd2, 5'd3));
    write_instr(64'h2014, make_halt());
    run_cycles(14);
    check_reg(64'h4018000000000000, cpu.reg_file.registers[4], 32);

    do_reset();  // divf: 1.0/2.0=0.5
    fp_load_pair(64'h3FF0000000000000, 64'h4000000000000000);
    write_instr(64'h2010, make_divf(5'd4, 5'd2, 5'd3));
    write_instr(64'h2014, make_halt());
    run_cycles(14);
    check_reg(64'h3FE0000000000000, cpu.reg_file.registers[4], 33);

    do_reset();  // addf neg: 1.0+(-1.0)=0.0
    fp_load_pair(64'h3FF0000000000000, 64'hBFF0000000000000);
    write_instr(64'h2010, make_addf(5'd4, 5'd2, 5'd3));
    write_instr(64'h2014, make_halt());
    run_cycles(14);
    check_reg(64'h0000000000000000, cpu.reg_file.registers[4], 34);

    do_reset();  // subf neg: 1.0-2.0=-1.0
    fp_load_pair(64'h3FF0000000000000, 64'h4000000000000000);
    write_instr(64'h2010, make_subf(5'd4, 5'd2, 5'd3));
    write_instr(64'h2014, make_halt());
    run_cycles(14);
    check_reg(64'hBFF0000000000000, cpu.reg_file.registers[4], 35);

    do_reset();  // mulf neg: (-1.0)*2.0=-2.0
    fp_load_pair(64'hBFF0000000000000, 64'h4000000000000000);
    write_instr(64'h2010, make_mulf(5'd4, 5'd2, 5'd3));
    write_instr(64'h2014, make_halt());
    run_cycles(14);
    check_reg(64'hC000000000000000, cpu.reg_file.registers[4], 36);

    do_reset();  // divf neg: (-1.0)/2.0=-0.5
    fp_load_pair(64'hBFF0000000000000, 64'h4000000000000000);
    write_instr(64'h2010, make_divf(5'd4, 5'd2, 5'd3));
    write_instr(64'h2014, make_halt());
    run_cycles(14);
    check_reg(64'hBFE0000000000000, cpu.reg_file.registers[4], 37);

    $display("\n--- results: %0d passed, %0d failed ---", pass_count, fail_count);
    $finish;
  end
endmodule
