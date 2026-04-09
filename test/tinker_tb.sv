// tb_tinker_debug.v — Fixed Call/Return Debugger
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

  function [31:0] make_call;
    input [4:0] rd;
    make_call = (5'h0C << 27) | (rd << 22);
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

  integer i;

  initial begin
    $dumpfile("sim/debug_call_ret.vcd");
    $dumpvars(0, tb_tinker);

    clk = 0;
    reset = 1;

    // Zero out memory region we care about
    for (i = 0; i < 16; i = i + 1)
      cpu.memory.bytes[i] = 8'h0;

    // Write instructions BEFORE releasing reset so memory is ready
    //
    // Layout:
    //   0x2000: addi r1, 42      -- r1 = 42 (just to check something executes)
    //   0x2004: call r4           -- call subroutine; r4 pre-loaded to 0x2010
    //   0x2008: halt              -- return lands here
    //
    // Subroutine at 0x2010:
    //   0x2010: addi r2, 1        -- r2 = 1 (proves subroutine ran)
    //   0x2014: return
    //
    // Expected final state: r1=42, r2=1, PC stopped at halt

    write_instr(64'h2000, make_addi(5'd1, 12'd42));  // r1 = 42
    write_instr(64'h2004, make_call(5'd4));           // call r4 (r4=0x2010)
    write_instr(64'h2008, make_halt());               // halt

    write_instr(64'h2010, make_addi(5'd2, 12'd1));   // r2 = 1
    write_instr(64'h2014, make_return());             // return

    #15 reset = 0;

    // CRITICAL FIX: directly pre-load r4 with the subroutine address 0x2010.
    // addi can only encode a 12-bit immediate (max 4095), so we can't build
    // 0x2010 = 8208 from a single instruction starting from r4=0.
    // The official test loader sets registers via a .state file; we do it here.
    // Must be done AFTER reset deasserts so the reset zeroing doesn't overwrite it.
    @(negedge clk);  // wait for one half-cycle after reset falls
    cpu.reg_file.registers[4] = 64'h2010;

    $display("\n[TIME]    | PC               | R1  | R2  | R4 (target)      | STACK[SP-8]");
    $display("------------------------------------------------------------------------");
  end

  // Monitor
  always @(posedge clk) begin
    #1;
    $display("%t | %h | %3d | %3d | %h | %h",
             $time,
             cpu.pc,
             cpu.reg_file.registers[1],
             cpu.reg_file.registers[2],
             cpu.reg_file.registers[4],
             {cpu.memory.bytes[cpu.reg_file.registers[31]-1],
              cpu.memory.bytes[cpu.reg_file.registers[31]-2],
              cpu.memory.bytes[cpu.reg_file.registers[31]-3],
              cpu.memory.bytes[cpu.reg_file.registers[31]-4],
              cpu.memory.bytes[cpu.reg_file.registers[31]-5],
              cpu.memory.bytes[cpu.reg_file.registers[31]-6],
              cpu.memory.bytes[cpu.reg_file.registers[31]-7],
              cpu.memory.bytes[cpu.reg_file.registers[31]-8]});
    if (hlt) begin
      $display("\n[HALT] Stopped. r1=%0d r2=%0d (expect r1=42, r2=1)",
               cpu.reg_file.registers[1], cpu.reg_file.registers[2]);
      $display("Stack at SP-8 should contain return addr 0x2008");
      $finish;
    end
  end

  // Watchdog
  initial begin
    #1000;
    $display("[TIMEOUT] r1=%0d r2=%0d pc=%h",
             cpu.reg_file.registers[1],
             cpu.reg_file.registers[2],
             cpu.pc);
    $finish;
  end

endmodule