// Block RAM with two ports, both "address now, data next clock":
//   instruction port: read only, with an enable so the word holds while the
//                     pipeline is stalled
//   data port:        read + byte-masked write (the scaffold's Memory port)
// The scaffold had one port shared by fetch and data, which a pipeline cannot
// use because it fetches and accesses data in the same cycle. Code and data
// still live in the same memory, so the firmware flow (one firmware.hex,
// everything linked at address 0) is unchanged.
//
// INIT_FILE: $readmemh image, one 32-bit word per line ("" = all zero).
module Memory #(
    parameter WORDS     = 16384,           // 64 kB
    parameter INIT_FILE = "firmware.hex",
    parameter WRITABLE  = 1
) (
    input             clk,
    // instruction port
    input      [31:0] imem_addr,
    input             imem_en,
    output reg [31:0] imem_rdata,
    // data port
    input      [31:0] mem_addr,
    output reg [31:0] mem_rdata,
    input             mem_read_signal,
    input      [31:0] mem_wdata,
    input      [3:0]  mem_wmask
);

   localparam AW = $clog2(WORDS);

   reg [31:0] MEM [0:WORDS-1];

   integer i;
   initial begin
      for (i = 0; i < WORDS; i = i + 1) MEM[i] = 32'b0;
      if (INIT_FILE != "") $readmemh(INIT_FILE, MEM);
   end

   wire [AW-1:0] i_word = imem_addr[AW+1:2];
   wire [AW-1:0] d_word = mem_addr[AW+1:2];

   always @(posedge clk) begin
      if (imem_en) imem_rdata <= MEM[i_word];
   end

   always @(posedge clk) begin
      if (mem_read_signal) mem_rdata <= MEM[d_word];
      if (WRITABLE != 0) begin
         if (mem_wmask[0]) MEM[d_word][ 7: 0] <= mem_wdata[ 7: 0];
         if (mem_wmask[1]) MEM[d_word][15: 8] <= mem_wdata[15: 8];
         if (mem_wmask[2]) MEM[d_word][23:16] <= mem_wdata[23:16];
         if (mem_wmask[3]) MEM[d_word][31:24] <= mem_wdata[31:24];
      end
   end

endmodule
