module reg_file(
    input clk,
    input reset,
    input [63:0] data,
    input [4:0] raddr1,
    input [4:0] raddr2,
    input [4:0] raddr3,
    input [4:0] waddr,
    input write,
    output [63:0] r1,
    output [63:0] r2,
    output [63:0] r3
);

  reg [63:0] registers [0:31];

  assign r1 = (raddr1 == 5'd0) ? 64'd0 : registers[raddr1];
  assign r2 = (raddr2 == 5'd0) ? 64'd0 : registers[raddr2];
  assign r3 = (raddr3 == 5'd0) ? 64'd0 : registers[raddr3];

  integer i;
  always @(posedge clk) begin
    if (reset) begin
      for (i = 0; i < 32; i = i + 1) begin
        if (i == 31) 
          registers[i] <= 64'h80000;
        else 
          registers[i] <= 64'd0;
      end
    end else if (write && waddr != 5'd0) begin
      registers[waddr] <= data;
    end
  end
endmodule