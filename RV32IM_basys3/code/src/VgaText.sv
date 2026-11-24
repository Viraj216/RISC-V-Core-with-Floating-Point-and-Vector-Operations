// Memory-mapped VGA text console: 80 x 30 cells, 8x16 glyphs, 16-colour
// foreground/background per cell, 640x480 @ 60 Hz (25 MHz pixel clock).
//
// CPU side (clk_cpu domain) - one 8 KiB window, decoded by the caller:
//   offset 0x0000 .. 0x12BF : cell RAM, one 16-bit cell per 2 bytes,
//                             cell = {bg[3:0], fg[3:0], char[7:0]};
//                             cell index = row * 80 + col; sb/sh/sw all work
//   offset 0x1F00 (RO)      : status  {frame_count[15:0], 14'b0, vblank, vsync}
//   offset 0x1F04 (RW)      : cursor  {16'b0, enable, 2'b0, row[4:0], col[7:0]}
//                             (hardware cursor = blinking inverse of that cell)
// Reads have one cycle of latency and return 0 when not addressed, like the
// data RAM, so the caller can OR the read buses together.
//
// Pixel side (clk_vga domain): clk_vga may be a true 25.175 MHz clock
// (vga_en = 1) or a faster clock with vga_en pulsing once per pixel (the
// Arty top uses 100 MHz with a /4 enable). The cell RAM is a true dual-port
// BRAM, which is the only clock-domain crossing for picture data; status
// bits are synchronised with two flops.
//
// Timing (industry-standard 640x480@60, both syncs active low):
//   H: 640 visible, 16 front porch, 96 sync, 48 back porch  = 800 clocks
//   V: 480 visible, 10 front porch,  2 sync, 33 back porch  = 525 lines
module VgaText (
  // CPU port
  input  logic        clk_cpu,
  input  logic        rst_cpu,
  input  logic        io_sel,          // address is inside the 8 KiB window
  input  logic [12:0] io_offset,       // byte offset inside the window
  input  logic [31:0] io_wrData,
  input  logic        io_memRead,
  input  logic        io_memWrite,
  input  logic [3:0]  io_mask,
  output logic [31:0] io_rdData,
  // VGA port
  input  logic        clk_vga,
  input  logic        rst_vga,
  input  logic        vga_en,
  output logic        vga_hs,
  output logic        vga_vs,
  output logic [3:0]  vga_r,
  output logic [3:0]  vga_g,
  output logic [3:0]  vga_b
);

  localparam int H_VIS = 640, H_FP = 16, H_SYNC = 96, H_TOT = 800;
  localparam int V_VIS = 480, V_FP = 10, V_SYNC = 2,  V_TOT = 525;

  // ---------------------------------------------------------------------------
  // Cell RAM: 2048 x 32 (two cells per word) so that every CPU access is a
  // single word address with byte enables, and the scan-out is a single word
  // read: port A = CPU, port B = scan-out -> one true dual-port BRAM.
  // ---------------------------------------------------------------------------
  logic [31:0] cells [0:2047];

  logic        is_cell, is_status, is_cursor;
  logic [10:0] word_idx;
  assign is_cell   = io_sel & (io_offset < 13'h12C0);
  assign is_status = io_sel & (io_offset[12:2] == 11'h7C0);   // 0x1F00
  assign is_cursor = io_sel & (io_offset[12:2] == 11'h7C1);   // 0x1F04
  assign word_idx  = io_offset[12:2];

  logic [31:0] cell_rd_q;
  logic        rd_cell_q, rd_status_q, rd_cursor_q;
  logic [15:0] cursor_q;        // {enable, 2'b0, row[4:0], col[7:0]}
  logic [15:0] frame_cnt_q;
  logic        vsync_sync0, vsync_sync1, vblank_sync0, vblank_sync1;

  // Port A: byte-masked write, registered read (MemoryStage already shifted
  // sb/sh data into the right lanes and built io_mask).
  always_ff @(posedge clk_cpu) begin
    if (is_cell & io_memWrite) begin
      if (io_mask[0]) cells[word_idx][7:0]   <= io_wrData[7:0];
      if (io_mask[1]) cells[word_idx][15:8]  <= io_wrData[15:8];
      if (io_mask[2]) cells[word_idx][23:16] <= io_wrData[23:16];
      if (io_mask[3]) cells[word_idx][31:24] <= io_wrData[31:24];
    end
    cell_rd_q <= cells[word_idx];
  end

  always_ff @(posedge clk_cpu) begin
    if (rst_cpu) begin
      rd_cell_q   <= 1'b0;
      rd_status_q <= 1'b0;
      rd_cursor_q <= 1'b0;
      cursor_q    <= 16'h0;
      frame_cnt_q <= 16'h0;
      vsync_sync0 <= 1'b1; vsync_sync1 <= 1'b1;
      vblank_sync0 <= 1'b0; vblank_sync1 <= 1'b0;
    end else begin
      rd_cell_q   <= is_cell   & io_memRead;
      rd_status_q <= is_status & io_memRead;
      rd_cursor_q <= is_cursor & io_memRead;
      if (is_cursor & io_memWrite) begin
        if (io_mask[0]) cursor_q[7:0]  <= io_wrData[7:0];
        if (io_mask[1]) cursor_q[15:8] <= io_wrData[15:8];
      end
      // Synchronise the two status bits into the CPU domain; count frames on
      // the synchronised vsync's falling (active) edge.
      vsync_sync0  <= vga_vs;      vsync_sync1  <= vsync_sync0;
      vblank_sync0 <= vblank_vga;  vblank_sync1 <= vblank_sync0;
      if (vsync_sync1 & ~vsync_sync0) frame_cnt_q <= frame_cnt_q + 16'h1;
    end
  end

  always_comb begin
    io_rdData = 32'h0;
    if (rd_cell_q)        io_rdData = cell_rd_q;
    else if (rd_status_q) io_rdData = {frame_cnt_q, 14'h0, vblank_sync1, ~vsync_sync1};
    else if (rd_cursor_q) io_rdData = {16'h0, cursor_q};
  end

  // ---------------------------------------------------------------------------
  // Scan-out (clk_vga domain)
  // ---------------------------------------------------------------------------
  logic [9:0] hcnt, vcnt;          // 0..799, 0..524
  logic       vblank_vga;
  assign vblank_vga = (vcnt >= 10'(V_VIS));

  always_ff @(posedge clk_vga) begin
    if (rst_vga) begin
      hcnt <= 10'h0;
      vcnt <= 10'h0;
    end else if (vga_en) begin
      if (hcnt == 10'(H_TOT - 1)) begin
        hcnt <= 10'h0;
        vcnt <= (vcnt == 10'(V_TOT - 1)) ? 10'h0 : vcnt + 10'h1;
      end else begin
        hcnt <= hcnt + 10'h1;
      end
    end
  end

  // Stage 0: timing flags for the pixel at (hcnt, vcnt)
  logic visible0, hs0, vs0;
  assign visible0 = (hcnt < 10'(H_VIS)) & (vcnt < 10'(V_VIS));
  assign hs0      = ~((hcnt >= 10'(H_VIS + H_FP)) & (hcnt < 10'(H_VIS + H_FP + H_SYNC)));
  assign vs0      = ~((vcnt >= 10'(V_VIS + V_FP)) & (vcnt < 10'(V_VIS + V_FP + V_SYNC)));

  // Stage 0 -> 1: cell RAM read. index = row*80 + col = (row<<6) + (row<<4) + col
  logic [4:0]  row;      // 0..29
  logic [6:0]  col;      // 0..79
  logic [11:0] row80, cell_addr_x;
  assign row       = vcnt[8:4];
  assign col       = hcnt[9:3];
  // row*80 = row*64 + row*16
  assign row80       = {1'b0, row, 6'b0} + {3'b0, row, 4'b0};
  assign cell_addr_x = row80 + {5'b0, col};

  logic [31:0] word1;
  logic        half1;
  logic [15:0] cell1;
  logic [3:0]  prow1;    // glyph row
  logic [2:0]  pcol1;    // pixel within glyph
  logic        visible1, hs1, vs1;
  logic [11:0] cell_addr1;

  always_ff @(posedge clk_vga) begin
    if (vga_en) begin
      word1      <= cells[cell_addr_x[11:1]];
      half1      <= cell_addr_x[0];
      prow1      <= vcnt[3:0];
      pcol1      <= hcnt[2:0];
      visible1   <= visible0;
      hs1        <= hs0;
      vs1        <= vs0;
      cell_addr1 <= cell_addr_x;
    end
  end

  assign cell1 = half1 ? word1[31:16] : word1[15:0];

  // Stage 1 -> 2: font ROM read
  logic [7:0] glyph2;
  logic [3:0] fg2, bg2;
  logic [2:0] pcol2;
  logic       visible2, hs2, vs2, cursor2;

  FontRom font (
    .clock (clk_vga),
    .en    (vga_en),
    .addr  ({cell1[7:0], prow1}),
    .data  (glyph2)
  );

  // Cursor compare uses the CPU-written register; it crosses domains as a
  // quasi-static value (software moves it rarely), so no synchroniser.
  logic [11:0] cursor_idx;
  logic [11:0] cursor_row80;
  assign cursor_row80 = {1'b0, cursor_q[12:8], 6'b0} + {3'b0, cursor_q[12:8], 4'b0};
  assign cursor_idx   = cursor_row80 + {4'b0, cursor_q[7:0]};

  logic [5:0] blink_cnt;   // toggles every 32 frames
  always_ff @(posedge clk_vga) begin
    if (rst_vga) blink_cnt <= 6'h0;
    else if (vga_en & (hcnt == 10'h0) & (vcnt == 10'h0)) blink_cnt <= blink_cnt + 6'h1;
  end

  always_ff @(posedge clk_vga) begin
    if (vga_en) begin
      fg2      <= cell1[11:8];
      bg2      <= cell1[15:12];
      pcol2    <= pcol1;
      visible2 <= visible1;
      hs2      <= hs1;
      vs2      <= vs1;
      cursor2  <= cursor_q[15] & (cell_addr1 == cursor_idx) & blink_cnt[5];
    end
  end

  // Stage 2 -> 3: pixel select, palette, output registers
  logic       pix_on;
  logic [3:0] colour_idx;
  assign pix_on     = glyph2[3'd7 - pcol2] ^ cursor2;
  assign colour_idx = pix_on ? fg2 : bg2;

  // Standard 16-colour text palette, 4 bits per channel
  logic [11:0] rgb;
  always_comb begin
    unique case (colour_idx)
      4'h0: rgb = 12'h000;  // black
      4'h1: rgb = 12'h00A;  // blue
      4'h2: rgb = 12'h0A0;  // green
      4'h3: rgb = 12'h0AA;  // cyan
      4'h4: rgb = 12'hA00;  // red
      4'h5: rgb = 12'hA0A;  // magenta
      4'h6: rgb = 12'hA50;  // brown
      4'h7: rgb = 12'hAAA;  // light grey
      4'h8: rgb = 12'h555;  // dark grey
      4'h9: rgb = 12'h55F;  // light blue
      4'hA: rgb = 12'h5F5;  // light green
      4'hB: rgb = 12'h5FF;  // light cyan
      4'hC: rgb = 12'hF55;  // light red
      4'hD: rgb = 12'hF5F;  // light magenta
      4'hE: rgb = 12'hFF5;  // yellow
      default: rgb = 12'hFFF;  // white
    endcase
  end

  always_ff @(posedge clk_vga) begin
    if (rst_vga) begin
      vga_hs <= 1'b1;
      vga_vs <= 1'b1;
      {vga_r, vga_g, vga_b} <= 12'h0;
    end else if (vga_en) begin
      vga_hs <= hs2;
      vga_vs <= vs2;
      {vga_r, vga_g, vga_b} <= visible2 ? rgb : 12'h0;   // black during blanking
    end
  end

endmodule
