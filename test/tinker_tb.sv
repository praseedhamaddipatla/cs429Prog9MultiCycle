// tb_return_debug.sv
// Tests: return -> addi r2, 1 -> halt
// ISA spec: return does pc <- Mem[r31 - 8], SP is NEVER modified
// call  does Mem[r31 - 8] = pc + 4, pc <- rd, SP is NEVER modified

module tb_tinker;

  reg clk, reset;
  wire hlt;

  tinker_core cpu (
      .clk  (clk),
      .reset(reset),
      .hlt  (hlt)
  );

  always #5 clk = ~clk;

  // ---------- instruction encoders ----------
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

  // ---------- memory helpers ----------
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

  // helper: read 64-bit value from memory (for display)
  function [63:0] read_mem64;
    input [63:0] addr;
    read_mem64 = {
      cpu.memory.bytes[addr+7],
      cpu.memory.bytes[addr+6],
      cpu.memory.bytes[addr+5],
      cpu.memory.bytes[addr+4],
      cpu.memory.bytes[addr+3],
      cpu.memory.bytes[addr+2],
      cpu.memory.bytes[addr+1],
      cpu.memory.bytes[addr]
    };
  endfunction

  // ---------- state tracking ----------
  reg [2:0] prev_state;
  always @(posedge clk) prev_state <= cpu.state;

  initial begin
    $dumpfile("sim/debug_call_ret.vcd");
    $dumpvars(0, tb_tinker);

    clk   = 0;
    reset = 1;

    // ----------------------------------------------------------------
    // PROGRAM LAYOUT
    //
    // 0x2000: return          -- pc <- Mem[r31-8]; SP unchanged
    // 0x2004: (never reached)
    // 0x2008: addi r2, 1      -- proves we landed correctly
    // 0x200c: halt
    //
    // STACK SETUP (ISA: return reads Mem[r31-8])
    //   We set r31 = 0x3008  so  r31-8 = 0x3000
    //   We write 0x2008 to address 0x3000  (the return target)
    // ----------------------------------------------------------------
    write_instr(64'h2000, make_return());
    write_instr(64'h2008, make_addi(5'd2, 12'd1));
    write_instr(64'h200c, make_halt());

    // Return address sits at r31-8 = 0x3000
    write_mem64(64'h3000, 64'h0000_0000_0000_2008);

    #15 reset = 0;

    // Set registers AFTER reset deasserts
    @(negedge clk);
    cpu.reg_file.registers[31] = 64'h3008;  // SP = 0x3008, so SP-8 = 0x3000
    cpu.reg_file.registers[2]  = 64'h0;

    $display("=== Return Test ===");
    $display("r31 (SP)  = 0x%h", cpu.reg_file.registers[31]);
    $display("r31-8     = 0x%h  (where return reads from)", cpu.reg_file.registers[31] - 64'd8);
    $display("Mem[r31-8]= 0x%h  (expected return target 0x2008)", read_mem64(64'h3000));
    $display("");
    $display("[TIME] | STATE | PC               | r2  | r31(SP)          | Mem[SP-8]        | mem_rdata / mem_out");
    $display("-------+-------+------------------+-----+------------------+------------------+--------------------");
  end

  // ---------- per-cycle monitor ----------
  always @(posedge clk) begin
    #1;
    if (!reset) begin
      $display("%6t |  S%0d   | %h | %3d | %h | %h | rdata=%h out=%h",
        $time,
        cpu.state,
        cpu.pc,
        cpu.reg_file.registers[2],
        cpu.reg_file.registers[31],
        read_mem64(cpu.reg_file.registers[31] - 64'd8),
        cpu.mem_rdata,
        cpu.mem_out_reg
      );

      // Extra detail when we're in the return instruction states
      if (cpu.is_return_r) begin
        $display("         >>> RETURN active: mem_addr_latch=%h mem_data_addr=%h",
          cpu.mem_addr_latch,
          // show the live combinatorial address going to memory
          cpu.reg_file.registers[31] - 64'd8
        );
      end
    end

    if (hlt) begin
      $display("");
      $display("=== HALT ===");
      $display("r2  = %0d  (expected 1)", cpu.reg_file.registers[2]);
      $display("r31 = 0x%h  (SP, should be unchanged = 0x3008)",
               cpu.reg_file.registers[31]);
      if (cpu.reg_file.registers[2] == 1)
        $display("PASS: return landed at 0x2008, addi executed.");
      else
        $display("FAIL: r2=%0d, return did not land at 0x2008.",
                 cpu.reg_file.registers[2]);
      $finish;
    end
  end

  // ---------- watchdog ----------
  initial begin
    #2000;
    $display("[TIMEOUT] after 2000ns — r2=%0d pc=%h state=S%0d",
             cpu.reg_file.registers[2], cpu.pc, cpu.state);
    $display("Mem[0x3000] = %h", read_mem64(64'h3000));
    $display("mem_out_reg = %h", cpu.mem_out_reg);
    $finish;
  end

endmodule