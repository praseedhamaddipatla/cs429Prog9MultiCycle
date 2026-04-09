module tb_tinker;

  reg clk, reset;
  wire hlt;

  tinker_core cpu (
      .clk  (clk),
      .reset(reset),
      .hlt  (hlt)
  );

  always #5 clk = ~clk;

  // Instruction encoders
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
    input [63:0] addr;
    input [31:0] word;
    begin
      cpu.memory.bytes[addr]   = word[7:0];
      cpu.memory.bytes[addr+1] = word[15:8];
      cpu.memory.bytes[addr+2] = word[23:16];
      cpu.memory.bytes[addr+3] = word[31:24];
    end
  endtask

  // Task to write a 64-bit value to memory (for the stack)
  task write_mem64;
    input [63:0] addr;
    input [63:0] val;
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

  initial begin
    $dumpfile("sim/debug_call_ret.vcd");
    $dumpvars(0, tb_tinker);

    clk = 0;
    reset = 1;

    // --- PROGRAM LAYOUT ---
    
    // 1. Starting Point (PC=0x2000): Immediately RETURN
    // This mimics returning from a subroutine we "started" in.
    write_instr(64'h2000, make_return());

    // 2. Return Destination (PC=0x2008): Do some work then halt
    // This is where the return should land.
    write_instr(64'h2008, make_addi(5'd2, 12'd1)); // addi r2, 1
    write_instr(64'h200c, make_halt());            // halt

    // --- STACK SETUP ---
    // We assume R31 (SP) starts at 0x3000. 
    // We place the return address (0x2008) at the current SP.
    write_mem64(64'h3000, 64'h2008); 

    #15 reset = 0;

    // --- REGISTER INITIALIZATION ---
    // Mimic the Gradescope .state file loader
    @(negedge clk);
    cpu.reg_file.registers[31] = 64'h3000; // Initialize Stack Pointer
    cpu.reg_file.registers[2]  = 64'h0;    // Clear R2

    $display("\n[TIME]    | PC               | R2  | SP (R31)         | STACK[SP]");
    $display("------------------------------------------------------------------------");
  end

  always @(posedge clk) begin
    #1;
    if (!reset) begin
      $display("%t | %h | %3d | %h | %h",
               $time,
               cpu.pc,
               cpu.reg_file.registers[2],
               cpu.reg_file.registers[31],
               {cpu.memory.bytes[cpu.reg_file.registers[31]+7],
                cpu.memory.bytes[cpu.reg_file.registers[31]+6],
                cpu.memory.bytes[cpu.reg_file.registers[31]+5],
                cpu.memory.bytes[cpu.reg_file.registers[31]+4],
                cpu.memory.bytes[cpu.reg_file.registers[31]+3],
                cpu.memory.bytes[cpu.reg_file.registers[31]+2],
                cpu.memory.bytes[cpu.reg_file.registers[31]+1],
                cpu.memory.bytes[cpu.reg_file.registers[31]]});
    end
    
    if (hlt) begin
      $display("\n[HALT] Stopped. r2=%0d (Expect r2=1)", cpu.reg_file.registers[2]);
      if (cpu.reg_file.registers[2] == 1) 
        $display("SUCCESS: Return landed correctly and executed addi.");
      else
        $display("FAILURE: Logic error in return sequence.");
      $finish;
    end
  end

  initial begin
    #1000;
    $display("[TIMEOUT] r2=%0d pc=%h", cpu.reg_file.registers[2], cpu.pc);
    $finish;
  end

endmodule