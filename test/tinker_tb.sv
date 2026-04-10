// tb_return_debug.sv
// ISA: return does pc <- Mem[r31-8], SP (r31) is NEVER modified
// Setup: r31=0x3008, so r31-8=0x3000, write return target 0x2008 there

module tb_tinker;

  reg clk, reset;
  wire hlt;

  tinker_core cpu (
      .clk  (clk),
      .reset(reset),
      .hlt  (hlt)
  );

  always #5 clk = ~clk;

  function [31:0] make_addi;
    input [4:0] rd; input [11:0] im;
    make_addi = (5'h19 << 27) | (rd << 22) | im;
  endfunction
  function [31:0] make_return;
    make_return = (5'h0D << 27);
  endfunction
  function [31:0] make_halt;
    make_halt = (5'h0F << 27);
  endfunction

  task write_instr;
    input [63:0] addr; input [31:0] word;
    begin
      cpu.memory.bytes[addr]   = word[7:0];
      cpu.memory.bytes[addr+1] = word[15:8];
      cpu.memory.bytes[addr+2] = word[23:16];
      cpu.memory.bytes[addr+3] = word[31:24];
    end
  endtask

  task write_mem64;
    input [63:0] addr; input [63:0] val;
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

  function [63:0] read_mem64;
    input [63:0] addr;
    read_mem64 = {cpu.memory.bytes[addr+7], cpu.memory.bytes[addr+6],
                  cpu.memory.bytes[addr+5], cpu.memory.bytes[addr+4],
                  cpu.memory.bytes[addr+3], cpu.memory.bytes[addr+2],
                  cpu.memory.bytes[addr+1], cpu.memory.bytes[addr]};
  endfunction

  initial begin
    $dumpfile("sim/debug_call_ret.vcd");
    $dumpvars(0, tb_tinker);
    clk = 0; reset = 1;

    // Program:
    //   0x2000: return          -> pc = Mem[r31-8] = Mem[0x3000] = 0x2008
    //   0x2008: addi r2, r2, 1 -> r2 becomes 1
    //   0x200c: halt
    write_instr(64'h2000, make_return());
    write_instr(64'h2008, make_addi(5'd2, 12'd1));
    write_instr(64'h200c, make_halt());

    // Stack: r31=0x3008, so r31-8=0x3000. Put return address 0x2008 there.
    write_mem64(64'h3000, 64'h0000_0000_0000_2008);

    #15 reset = 0;
    @(negedge clk);
    cpu.reg_file.registers[31] = 64'h3008;  // SP: r31-8 = 0x3000
    cpu.reg_file.registers[2]  = 64'h0;

    $display("INIT: r31=%h  r31-8=%h  Mem[r31-8]=%h",
             cpu.reg_file.registers[31],
             cpu.reg_file.registers[31] - 64'd8,
             read_mem64(64'h3000));
    $display("");
    $display("  time | S | pc               | r2 | mem_data_addr    | mem_rdata        | mem_out_reg      | is_ret_r");
    $display("-------+---+------------------+----+------------------+------------------+------------------+---------");
  end

  always @(posedge clk) begin
    #1;
    if (!reset) begin
      $display("%6t  | %0d | %h |  %0d | %h | %h | %h | %b",
        $time,
        cpu.state,
        cpu.pc,
        cpu.reg_file.registers[2],
        cpu.mem_data_addr,
        cpu.mem_rdata,
        cpu.mem_out_reg,
        cpu.is_return_r
      );
    end
    if (hlt) begin
      $display("");
      $display("HALT: r2=%0d (expect 1)  r31=%h (expect 3008)",
               cpu.reg_file.registers[2],
               cpu.reg_file.registers[31]);
      if (cpu.reg_file.registers[2] == 1)
        $display("PASS");
      else
        $display("FAIL");
      $finish;
    end
  end

  initial begin
    #2000;
    $display("TIMEOUT: r2=%0d pc=%h state=%0d mem_out_reg=%h",
             cpu.reg_file.registers[2], cpu.pc, cpu.state, cpu.mem_out_reg);
    $finish;
  end

endmodule