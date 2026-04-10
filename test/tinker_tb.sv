module tb_call_debug;
  reg clk, reset;
  wire hlt;

  tinker_core cpu(.clk(clk), .reset(reset), .hlt(hlt));
  always #5 clk = ~clk;

  task write_instr;
    input [63:0] addr; input [31:0] word;
    begin
      cpu.memory.bytes[addr]   = word[7:0];
      cpu.memory.bytes[addr+1] = word[15:8];
      cpu.memory.bytes[addr+2] = word[23:16];
      cpu.memory.bytes[addr+3] = word[31:24];
    end
  endtask

  initial begin
    clk = 0; reset = 1;

    // call r1  (opcode 0x0C, rd=r1)
    // encoding: {5'h0C, 5'd1, 22'd0} = 32'h1820_0000
    write_instr(64'h2000, 32'h6040_0000);
    // halt
    write_instr(64'h2004, 32'h7800_0000);

    // r1 = 0x2010 (call target)
    cpu.reg_file.registers[1]  = 64'h2010;
    // r31 = 524288 (stack pointer)
    cpu.reg_file.registers[31] = 64'd524288;

    #15 reset = 0;

    $display("time | state | pc               | is_call_r | is_jump_r | is_return_r | advance | mem_we | mem_data_addr    | mem_wdata");
    $display("-----|-------|------------------|-----------|-----------|-------------|---------|--------|------------------|----------");
  end

  always @(posedge clk) begin
    #1;
    if (!reset) begin
      $display("%4t | %0d     | %h | %b         | %b         | %b           | %b       | %b      | %h | %h",
        $time, cpu.state, cpu.pc,
        cpu.is_call_r, cpu.is_jump_r, cpu.is_return_r,
        cpu.advance, cpu.mem_we,
        cpu.mem_data_addr, cpu.mem_wdata);
    end
    if (hlt || $time > 200) begin
      $display("mem[524280]=%h", cpu.memory.bytes[524280]);
      $display("mem[524281]=%h", cpu.memory.bytes[524281]);
      $finish;
    end
  end
endmodule