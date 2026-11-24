// RV32IM processor, 5-stage pipeline (IF, ID, EX, MEM, WB).
//
// The decoder, immediates, ALU, branch comparator and the
// load / store alignment are the scaffold's own expressions, moved into the
// stage where they are needed; what is new is the pipeline around them:
//
//   IF   F_pc addresses the instruction memory (synchronous read)
//   ID   FD_*: instruction word on imem_rdata, register read, hazard check
//   EX   DE_*: ALU, branch/jump decision, multiply/divide, CSR read
//   MEM  EM_*: data memory / IO request (synchronous read)
//   WB   MW_*: load alignment, register write
//
// Hazards
//   - data: results are forwarded to EX from MEM (EM_result) and from WB
//     (W_data); the register file is bypassed in ID for the value being
//     written in the same cycle.
//   - load-use: load data only exists in WB, so an instruction that needs the
//     result of the load directly ahead of it waits one cycle in ID.
//   - control: branches and jumps are decided in EX (predict not-taken). A
//     taken one redirects the fetch in the same cycle and kills the one
//     wrong-path instruction in ID: 1 cycle penalty.
//   - multiply (3 cycles in EX) and divide (35 cycles in EX) hold IF/ID/EX
//     until the result is ready.
//
// Memory interface: two ports with the scaffold's signal names. Both are
// "address now, data next clock" (block RAM); there are no wait states.
//   instruction port: imem_addr / imem_en / imem_rdata
//                     (imem_rdata must hold its value while imem_en = 0)
//   data port:        mem_addr / mem_read_signal / mem_rdata,
//                     mem_wdata / mem_wmask (byte lanes already aligned)
//
// SYSTEM instructions: ECALL / EBREAK stop the processor (as in the scaffold;
// `halted` goes high). CSR instructions read the cycle and instret counters
// (rdcycle[h], rdinstret[h], used by EXAMPLES/perf.S); other CSRs read 0 and
// CSR writes are ignored. FENCE is a no-op. There are no traps or interrupts.
module Processor #(
    parameter [31:0] RESET_ADDR = 32'h0
) (
    input         clk,
    input         reset,            // active high, synchronous
    // instruction port
    output [31:0] imem_addr,
    output        imem_en,
    input  [31:0] imem_rdata,
    // data port
    output [31:0] mem_addr,
    input  [31:0] mem_rdata,
    output        mem_read_signal,
    output [31:0] mem_wdata,
    output [3:0]  mem_wmask,
    output        halted
);

   localparam [31:0] NOP = 32'h00000013;   // addi x0,x0,0

//---------------------------- pipeline control -------------------------------
   wire E_stall;        // EX is waiting for the multiplier / divider
   wire D_stall;        // ID is waiting for a load (load-use hazard)
   wire E_takeJump;     // EX redirects the fetch
   wire [31:0] E_jumpTarget;
   reg  halt_q;
   assign halted = halt_q;

   wire E_halt;         // ECALL / EBREAK in EX
   wire F_hold = E_stall | D_stall | halt_q;   // IF and ID keep their contents

//------------------------------- IF ------------------------------------------
   reg [31:0] F_pc;                 // address of the next sequential fetch
   reg [31:0] FD_pc;                // address of the instruction now in ID
   reg        FD_valid;

   assign imem_addr = E_takeJump ? E_jumpTarget : F_pc;
   assign imem_en   = !F_hold;

   always @(posedge clk) begin
      if (reset) begin
         F_pc     <= RESET_ADDR;
         FD_valid <= 1'b0;
      end else if (!F_hold) begin
         F_pc     <= imem_addr + 4;
         FD_pc    <= imem_addr;
         FD_valid <= 1'b1;
      end
   end

//------------------------------- ID ------------------------------------------
   wire [31:0] FD_instr = imem_rdata;

   wire [4:0] D_rs1Id = FD_instr[19:15];
   wire [4:0] D_rs2Id = FD_instr[24:20];

   // which source registers does this instruction really read?
   wire D_isReg    = (FD_instr[6:2] == 5'b01100);
   wire D_isBranch = (FD_instr[6:2] == 5'b11000);
   wire D_isStore  = (FD_instr[6:2] == 5'b01000);
   wire D_isJAL    = (FD_instr[6:2] == 5'b11011);
   wire D_isAUIPC  = (FD_instr[6:2] == 5'b00101);
   wire D_isLUI    = (FD_instr[6:2] == 5'b01101);
   wire D_readsRs1 = !(D_isJAL | D_isAUIPC | D_isLUI);
   wire D_readsRs2 = D_isReg | D_isBranch | D_isStore;

   // register bank (32 x 32, asynchronous read -> distributed RAM)
   reg [31:0] RegisterBank [0:31];
   integer i;
   initial begin
      for (i = 0; i < 32; i = i + 1) RegisterBank[i] = 0;
   end

   wire        W_wen;
   wire [4:0]  W_rdId;
   wire [31:0] W_data;

   // read, with bypass of the value WB writes in this same cycle
   wire [31:0] D_rs1 = (D_rs1Id == 0) ? 32'b0 :
                       (W_wen && W_rdId == D_rs1Id) ? W_data : RegisterBank[D_rs1Id];
   wire [31:0] D_rs2 = (D_rs2Id == 0) ? 32'b0 :
                       (W_wen && W_rdId == D_rs2Id) ? W_data : RegisterBank[D_rs2Id];

   always @(posedge clk) begin
      if (W_wen) RegisterBank[W_rdId] <= W_data;
   end

   reg [31:0] DE_pc;
   reg [31:0] DE_instr;
   reg [31:0] DE_rs1;
   reg [31:0] DE_rs2;
   reg        DE_valid;

   // load-use hazard: the instruction in EX is a load whose result ID needs
   wire DE_isLoadW = DE_valid && (DE_instr[6:2] == 5'b00000) && (DE_instr[11:7] != 0);
   assign D_stall = FD_valid && DE_isLoadW &&
                    ((D_readsRs1 && D_rs1Id == DE_instr[11:7]) ||
                     (D_readsRs2 && D_rs2Id == DE_instr[11:7]));

   always @(posedge clk) begin
      if (reset) begin
         DE_valid <= 1'b0;
         DE_instr <= NOP;
      end else if (!E_stall) begin
         // a bubble enters EX when ID is waiting, when the instruction in ID
         // is on the wrong path, or after the processor has halted
         DE_valid <= FD_valid && !D_stall && !E_takeJump && !halt_q && !E_halt;
         DE_instr <= FD_instr;
         DE_pc    <= FD_pc;
         DE_rs1   <= D_rs1;
         DE_rs2   <= D_rs2;
      end
   end

//------------------------------- EX ------------------------------------------
   wire [31:0] instr = DE_instr;

   //---------------------------DECODER (from the scaffold)---------------------
   wire isReg     =  (instr[6:2] == 5'b01100); // rd <- rs1 OP rs2
   wire isImm     =  (instr[6:2] == 5'b00100); // rd <- rs1 OP Iimm
   wire isBranch  =  (instr[6:2] == 5'b11000); // if(rs1 OP rs2) PC<-PC+Bimm
   wire isJALR    =  (instr[6:2] == 5'b11001); // rd <- PC+4; PC<-rs1+Iimm
   wire isJAL     =  (instr[6:2] == 5'b11011); // rd <- PC+4; PC<-PC+Jimm
   wire isAUIPC   =  (instr[6:2] == 5'b00101); // rd <- PC + Uimm
   wire isLUI     =  (instr[6:2] == 5'b01101); // rd <- Uimm
   wire isLoad    =  (instr[6:2] == 5'b00000); // rd <- mem[rs1+Iimm]
   wire isStore   =  (instr[6:2] == 5'b01000); // mem[rs1+Simm] <- rs2
   wire isSYSTEM  =  (instr[6:2] == 5'b11100); // ecall/ebreak/csr

   wire [31:0] Uimm={instr[31:12], {12{1'b0}}};
   wire [31:0] Iimm={{21{instr[31]}}, instr[30:20]};
   wire [31:0] Simm={{21{instr[31]}}, instr[30:25],instr[11:7]};
   wire [31:0] Bimm={{20{instr[31]}}, instr[7],instr[30:25],instr[11:8],1'b0};
   wire [31:0] Jimm={{12{instr[31]}}, instr[19:12],instr[20],instr[30:21],1'b0};

   wire [4:0] rs1Id = instr[19:15];
   wire [4:0] rs2Id = instr[24:20];
   wire [4:0] rdId  = instr[11:7];
   wire [2:0] funct3 = instr[14:12];
   wire [6:0] funct7 = instr[31:25];

   wire isMulDiv = isReg & (funct7 == 7'b0000001);   // RV32M
   wire isCSR    = isSYSTEM & (funct3 != 3'b000);
   wire isEBREAK = isSYSTEM & (funct3 == 3'b000);    // ecall / ebreak: halt
   assign E_halt = DE_valid & isEBREAK;

   //--------------------------- forwarding -------------------------------------
   reg [31:0] EM_instr;
   reg [31:0] EM_result;
   reg        EM_valid;
   reg        EM_wen;

   wire [4:0] EM_rdId = EM_instr[11:7];
   wire [31:0] rs1 = (EM_wen && EM_rdId == rs1Id) ? EM_result :
                     (W_wen  && W_rdId  == rs1Id) ? W_data    : DE_rs1;
   wire [31:0] rs2 = (EM_wen && EM_rdId == rs2Id) ? EM_result :
                     (W_wen  && W_rdId  == rs2Id) ? W_data    : DE_rs2;

   //-------------------------------ALU------------------------------------------
   wire [31:0] aluIn1 = rs1;
   wire [31:0] aluIn2 = isReg ? rs2 : Iimm;
   reg  [31:0] aluOut;
   wire [4:0]  shamt = isReg ? rs2[4:0] : instr[24:20];
   // one shifter for srl / sra: the 33rd bit is the sign for sra, 0 for srl
   wire [32:0] shiftR = $signed({funct7[5] & aluIn1[31], aluIn1}) >>> shamt;

   always @(*) begin
      case(funct3)
        3'b000: aluOut = (funct7[5] & instr[5]) ? (aluIn1 - aluIn2) : (aluIn1 + aluIn2);
        3'b001: aluOut = aluIn1 << shamt;
        3'b010: aluOut = {31'b0, ($signed(aluIn1) < $signed(aluIn2))};
        3'b011: aluOut = {31'b0, (aluIn1 < aluIn2)};
        3'b100: aluOut = (aluIn1 ^ aluIn2);
        3'b101: aluOut = shiftR[31:0];
        3'b110: aluOut = (aluIn1 | aluIn2);
        3'b111: aluOut = (aluIn1 & aluIn2);
      endcase
   end

   //--------------------------------Branch--------------------------------------
   reg yesBranch;
   always @(*) begin
      case(funct3)
        3'b000: yesBranch = (rs1 == rs2);
        3'b001: yesBranch = (rs1 != rs2);
        3'b100: yesBranch = ($signed(rs1) < $signed(rs2));
        3'b101: yesBranch = ($signed(rs1) >= $signed(rs2));
        3'b110: yesBranch = (rs1 < rs2);
        3'b111: yesBranch = (rs1 >= rs2);
        default: yesBranch = 1'b0;
      endcase
   end

   wire [31:0] jalrTarget = rs1 + Iimm;
   assign E_jumpTarget = isJALR ? {jalrTarget[31:1], 1'b0} :
                                  DE_pc + (isJAL ? Jimm : Bimm);
   assign E_takeJump   = DE_valid & ((isBranch & yesBranch) | isJAL | isJALR);

   //--------------------------- multiply / divide -------------------------------
   // The operands are captured in the first EX cycle of the instruction,
   // because the stages ahead keep moving while EX waits and the forwarded
   // values are only there for that one cycle.
   //   mul*: operands registered, then the 33x33 signed product registered
   //   div*/rem*: restoring division on magnitudes, 1 bit per cycle
   reg         md_busy, md_done;
   reg  [5:0]  md_count;
   reg  [2:0]  md_op;
   reg  [31:0] md_a, md_b;             // operands (magnitudes for division)
   reg         md_negQ, md_negR;
   reg  [31:0] md_quot, md_rem;
   reg  [31:0] md_result;

   wire md_start = DE_valid & isMulDiv & !md_busy & !md_done;
   assign E_stall = DE_valid & isMulDiv & !md_done;

   wire        md_isDiv = md_op[2];
   wire signed [32:0] mul_a = {(md_op[1:0] != 2'b11) & md_a[31], md_a};  // mulhu: unsigned a
   wire signed [32:0] mul_b = {(md_op[1:0] == 2'b01) & md_b[31], md_b};  // mulh: signed b
   wire signed [65:0] product = mul_a * mul_b;

   wire        divSigned = !funct3[0];                    // div, rem
   wire [31:0] rs1Abs = (divSigned & rs1[31]) ? -rs1 : rs1;
   wire [31:0] rs2Abs = (divSigned & rs2[31]) ? -rs2 : rs2;
   // one restoring-division step
   wire [32:0] div_trial = {md_rem[30:0], md_quot[31]} - {1'b0, md_b};
   wire [31:0] div_remNext  = div_trial[32] ? {md_rem[30:0], md_quot[31]} : div_trial[31:0];
   wire [31:0] div_quotNext = {md_quot[30:0], !div_trial[32]};

   always @(posedge clk) begin
      if (reset) begin
         md_busy <= 1'b0;
         md_done <= 1'b0;
      end else begin
         md_done <= 1'b0;
         if (md_start) begin
            md_busy  <= 1'b1;
            md_op    <= funct3;
            md_count <= 6'd0;
            if (funct3[2]) begin                  // division: work on magnitudes
               md_a    <= rs1;
               md_b    <= rs2Abs;
               md_quot <= rs1Abs;                 // dividend shifts out of here
               md_rem  <= 32'b0;
               // x / 0 = all ones (never negated), x % 0 = x
               md_negQ <= divSigned & (rs1[31] ^ rs2[31]) & (rs2 != 0);
               md_negR <= divSigned & rs1[31];
            end else begin
               md_a    <= rs1;
               md_b    <= rs2;
            end
         end else if (md_busy) begin
            if (!md_isDiv) begin
               md_result <= (md_op[1:0] == 2'b00) ? product[31:0] : product[63:32];
               md_busy   <= 1'b0;
               md_done   <= 1'b1;
            end else if (md_count != 6'd32) begin
               md_rem   <= div_remNext;
               md_quot  <= div_quotNext;
               md_count <= md_count + 6'd1;
            end else begin
               md_result <= md_op[1] ? (md_negR ? -md_rem  : md_rem)      // rem, remu
                                     : (md_negQ ? -md_quot : md_quot);    // div, divu
               md_busy   <= 1'b0;
               md_done   <= 1'b1;
            end
         end
      end
   end

   //------------------------------- CSR read ------------------------------------
   reg [63:0] cycle_q, instret_q;
   reg [31:0] csrData;
   always @(*) begin
      case (instr[31:20])
        12'hC00, 12'hB00: csrData = cycle_q[31:0];      // cycle,   mcycle
        12'hC80, 12'hB80: csrData = cycle_q[63:32];     // cycleh,  mcycleh
        12'hC02, 12'hB02: csrData = instret_q[31:0];    // instret, minstret
        12'hC82, 12'hB82: csrData = instret_q[63:32];
        default:          csrData = 32'b0;
      endcase
   end

   //------------------------------ EX result ------------------------------------
   wire [31:0] E_result = (isJAL | isJALR) ? (DE_pc + 4)     :
                          isLUI            ? Uimm            :
                          isAUIPC          ? (DE_pc + Uimm)  :
                          isMulDiv         ? md_result       :
                          isCSR            ? csrData         :
                                             aluOut;
   wire [31:0] E_addr   = rs1 + (isStore ? Simm : Iimm);     // load / store address
   wire        E_wen    = (isReg | isImm | isJAL | isJALR | isLUI | isAUIPC | isLoad | isCSR)
                          & (rdId != 0);

   reg [31:0] EM_addr;
   reg [31:0] EM_rs2;

   always @(posedge clk) begin
      if (reset) begin
         EM_valid <= 1'b0;
         EM_wen   <= 1'b0;
         EM_instr <= NOP;
         halt_q   <= 1'b0;
      end else begin
         EM_valid  <= DE_valid & !E_stall;         // bubble while EX waits
         EM_wen    <= DE_valid & !E_stall & E_wen;
         EM_instr  <= instr;
         EM_result <= E_result;
         EM_addr   <= E_addr;
         EM_rs2    <= rs2;
         if (E_halt) halt_q <= 1'b1;
`ifdef TB
         if (E_halt & !halt_q) $display("EBREAK at pc=%h", DE_pc);
`endif
      end
   end

//------------------------------- MEM -----------------------------------------
   wire EM_isLoad  = (EM_instr[6:2] == 5'b00000);
   wire EM_isStore = (EM_instr[6:2] == 5'b01000);
   wire [2:0] EM_funct3 = EM_instr[14:12];
   wire EM_byteAccess     = EM_funct3[1:0] == 2'b00;
   wire EM_halfwordAccess = EM_funct3[1:0] == 2'b01;

   //----------------------------------Store-----------------
   assign mem_wdata[ 7: 0] = EM_rs2[7:0];
   assign mem_wdata[15: 8] = EM_addr[0] ? EM_rs2[7:0]  : EM_rs2[15: 8];
   assign mem_wdata[23:16] = EM_addr[1] ? EM_rs2[7:0]  : EM_rs2[23:16];
   assign mem_wdata[31:24] = EM_addr[0] ? EM_rs2[7:0]  : EM_addr[1] ? EM_rs2[15:8] : EM_rs2[31:24];

   wire [3:0] STORE_wmask = EM_byteAccess ? (EM_addr[1] ? (EM_addr[0] ? 4'b1000 : 4'b0100)
                                                        : (EM_addr[0] ? 4'b0010 : 4'b0001)) :
                            EM_halfwordAccess ? (EM_addr[1] ? 4'b1100 : 4'b0011) : 4'b1111;

   assign mem_addr        = EM_addr;
   assign mem_read_signal = EM_valid & EM_isLoad;
   assign mem_wmask       = {4{EM_valid & EM_isStore}} & STORE_wmask;

   reg [31:0] MW_instr;
   reg [31:0] MW_result;
   reg [1:0]  MW_addr;
   reg        MW_valid;
   reg        MW_wen;

   always @(posedge clk) begin
      if (reset) begin
         MW_valid <= 1'b0;
         MW_wen   <= 1'b0;
         MW_instr <= NOP;
      end else begin
         MW_valid  <= EM_valid;
         MW_wen    <= EM_wen;
         MW_instr  <= EM_instr;
         MW_result <= EM_result;
         MW_addr   <= EM_addr[1:0];
      end
   end

//------------------------------- WB ------------------------------------------
   //------------------------------Load (from the scaffold)----------------------
   wire MW_isLoad = (MW_instr[6:2] == 5'b00000);
   wire [2:0] MW_funct3 = MW_instr[14:12];
   wire MW_byteAccess     = MW_funct3[1:0] == 2'b00;
   wire MW_halfwordAccess = MW_funct3[1:0] == 2'b01;

   wire [15:0] LOAD_halfword = MW_addr[1] ? mem_rdata[31:16] : mem_rdata[15:0];
   wire  [7:0] LOAD_byte     = MW_addr[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];
   wire LOAD_sign = !MW_funct3[2] & (MW_byteAccess ? LOAD_byte[7] : LOAD_halfword[15]);
   wire [31:0] LOAD_data = MW_byteAccess     ? {{24{LOAD_sign}}, LOAD_byte} :
                           MW_halfwordAccess ? {{16{LOAD_sign}}, LOAD_halfword} : mem_rdata;

   assign W_wen  = MW_wen;
   assign W_rdId = MW_instr[11:7];
   assign W_data = MW_isLoad ? LOAD_data : MW_result;

   always @(posedge clk) begin
      if (reset) begin
         cycle_q   <= 64'b0;
         instret_q <= 64'b0;
      end else begin
         cycle_q <= cycle_q + 64'd1;
         if (MW_valid) instret_q <= instret_q + 64'd1;
      end
   end

endmodule
