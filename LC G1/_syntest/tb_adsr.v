// ============================================================================
// tb_adsr.v - TDM 版 adsr_32ch 与"原并行版黄金参考"逐帧对比
// ----------------------------------------------------------------------------
// 黄金参考 = 直接照抄改造前 ADSR.v 的 32 路并行状态机（每拍 note_on 优先）。
// 对齐约定：note_on 与 sample_en 同拍给出时，两者应在同一帧内完成同样的更新，
//   故每帧固定时刻 CHECK_AT 比较 env_shadow[n]（串行写口影子）与 g_amp[n]，全部相等即一致。
// 覆盖：拨弦(attack 1440/release/gate)、拉弦(attack 2048/sustain/松键 release)、
//       重复触发(re-pluck)、乱序触发，以及"帧中 note_on 单拍脉冲不丢"。
// ============================================================================
`timescale 1ns/1ps
module tb_adsr;

  reg  clk = 0;
  reg  rst_n = 0;
  reg  mode = 0;
  reg  [31:0] ch_note_on = 0;
  reg  [31:0] ch_key_level = 0;
  wire [15:0] env_wdata;
  wire [4:0]  env_waddr;
  wire        env_we;

  // 包络改为串行写口：把 {env_waddr, env_wdata, env_we} 抓进影子阵列再比较
  reg  [15:0] env_shadow [0:31];
  always @(posedge clk) if(env_we) env_shadow[env_waddr] <= env_wdata;

  adsr_32ch u_dut (.clk(clk), .rst_n(rst_n), .sample_en(sample_en),
                   .mode(mode), .ch_note_on(ch_note_on),
                   .ch_key_level(ch_key_level),
                   .env_wdata(env_wdata), .env_waddr(env_waddr), .env_we(env_we));

  // ---------------- 黄金参考（原并行实现） ----------------
  localparam ST_IDLE=3'b000, ST_ATTACK=3'b001,
             ST_SUSTAIN=3'b011, ST_RELEASE=3'b100;
  localparam [31:0] REL_FULL = 32'h7FFF0000;
  localparam [15:0] GATE_AMP = 16'd64;
  localparam [17:0] A_CNT     = 18'd1440;
  localparam [17:0] A_CNT_BOW = 18'd2048;

  reg [2:0]  g_state [0:31];
  reg [17:0] g_cnt   [0:31];
  reg [15:0] g_amp   [0:31];
  reg [31:0] g_prod  [0:31];

  integer n;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      for(n=0;n<32;n=n+1) begin
        g_state[n]<=ST_IDLE; g_cnt[n]<=18'd0; g_amp[n]<=16'd0; g_prod[n]<=32'd0;
      end
    end else begin
      if(sample_en) begin
        for(n=0;n<32;n=n+1) begin
          case(g_state[n])
          ST_IDLE: g_amp[n] <= 16'd0;
          ST_ATTACK: begin
            if(g_cnt[n] >= (mode ? A_CNT_BOW : A_CNT)) begin
              g_amp[n]<=16'd32767; g_cnt[n]<=18'd0; g_prod[n]<=REL_FULL;
              g_state[n] <= mode ? ST_SUSTAIN : ST_RELEASE;
            end else begin
              // 增量累加：amp += 23(拨弦)/16(拉弦)，饱和到 32767（与 RTL att_inc 同式）
              g_amp[n] <= ((g_amp[n] + (mode ? 18'd16 : 18'd23)) > 18'd32767)
                          ? 16'd32767 : (g_amp[n] + (mode ? 16'd16 : 16'd23));
              g_cnt[n] <= g_cnt[n] + 18'd1;
            end
          end
          ST_SUSTAIN: begin
            g_amp[n] <= 16'd32767;
            if(ch_key_level[n] == 1'b0) begin g_prod[n]<=REL_FULL; g_state[n]<=ST_RELEASE; end
          end
          ST_RELEASE: begin
            if(g_amp[n] <= GATE_AMP) begin
              g_amp[n]<=16'd0; g_state[n]<=ST_IDLE; g_cnt[n]<=18'd0;
            end else begin
              g_prod[n] <= g_prod[n] - (mode ? (g_prod[n]>>12) : (g_prod[n]>>17));
              g_amp[n]  <= g_prod[n][31:16];
            end
          end
          default: begin g_amp[n]<=16'd0; g_state[n]<=ST_IDLE; end
          endcase
        end
      end
      for(n=0;n<32;n=n+1) begin
        if(ch_note_on[n]) begin
          g_state[n]<=ST_ATTACK; g_cnt[n]<=18'd0; g_amp[n]<=16'd0; g_prod[n]<=REL_FULL;
        end
      end
    end
  end

  // ---------------- 时钟与帧节拍 ----------------
  // 【120MHz 4 拍/路后更新】DUT 扫描改为 4 拍/路（RD/C1/C2/WR），
  //   全程约 8 + 32*4 = 136 拍，故帧长放到 170 拍、检查点放到 155 拍。
  localparam PERIOD   = 170;   // 每帧 170 拍（>> DUT 扫描约 136 拍）
  localparam CHECK_AT = 155;   // 每帧在此拍比较（扫描已完成，下一次 sample_en 之前）

  always #5 clk = ~clk;

  reg [15:0] frame_cnt;
  reg        sample_en;
  reg [15:0] frame_no;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      frame_cnt <= 16'd0; sample_en <= 1'b0; frame_no <= 16'd0;
    end else begin
      sample_en <= (frame_cnt == PERIOD-1);
      if(frame_cnt == PERIOD-1) begin frame_cnt <= 16'd0; frame_no <= frame_no + 16'd1; end
      else                        frame_cnt <= frame_cnt + 16'd1;
    end
  end

  // ---------------- 激励 ----------------
  always @(*) begin
    ch_note_on   = 32'd0;
    ch_key_level = 32'd0;
    if(frame_cnt == 16'd0) begin
      if(frame_no == 16'd1)    ch_note_on = (32'd1<<0)|(32'd1<<5)|(32'd1<<31);
      if(frame_no == 16'd100)  ch_note_on = (32'd1<<0);          // 重复拨弦
      if(frame_no == 16'd250)  ch_note_on = (32'd1<<10);
      if(frame_no == 16'd800)  ch_note_on = (32'd1<<0);
      if(frame_no == 16'd3000) ch_note_on = (32'd1<<1)|(32'd1<<7); // 拉弦触发
      if(frame_no == 16'd6100) ch_note_on = (32'd1<<20);          // 供帧中脉冲测试
    end
    if(frame_no >= 16'd3000 && frame_no < 16'd4500) ch_key_level = (32'd1<<1);
    if(frame_no >= 16'd3000)                        ch_key_level = ch_key_level | (32'd1<<7);
    // 帧中单拍脉冲（与 sample_en 不同拍），仅最后一帧用
    if(frame_no == 16'd6104 && frame_cnt == 16'd40) ch_note_on = ch_note_on | (32'd1<<20);
  end

  // 0..2999 拨弦，3000 起拉弦
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) mode <= 1'b0;
    else if(frame_cnt == 16'd0 && frame_no == 16'd2999) mode <= 1'b1;
  end

  // ---------------- 比较 ----------------
  integer ch;
  integer err_cnt;
  integer ch_err [0:31];
  integer showed;
  reg [15:0] amp_before_mid, dut20_after;
  reg inited_dummy;

  initial begin
    err_cnt = 0; showed = 0;
    dut20_after = 0; amp_before_mid = 0;
    for(ch=0; ch<32; ch=ch+1) ch_err[ch] = 0;
  end

  always @(posedge clk) begin
    if(rst_n && inited_dummy && frame_cnt == CHECK_AT) begin
      if(frame_no == 16'd6103) amp_before_mid = env_shadow[20];
      if(frame_no == 16'd6105) dut20_after     = env_shadow[20];
      if(frame_no >= 16'd2 && frame_no <= 16'd6100) begin
        for(ch=0; ch<32; ch=ch+1) begin
          if(env_shadow[ch] !== g_amp[ch]) begin
            if(showed < 10) begin
              $display("first mismatch @frame=%0d ch=%0d dut=%0d gold=%0d",
                       frame_no, ch, env_shadow[ch], g_amp[ch]);
              showed = showed + 1;
            end
            ch_err[ch] = ch_err[ch] + 1;
            err_cnt = err_cnt + 1;
          end
        end
      end
      if(frame_no == 16'd6107) begin
        for(ch=0; ch<32; ch=ch+1)
          if(ch_err[ch] != 0) $display("  ch=%0d mismatch_frames=%0d", ch, ch_err[ch]);
        $display("mid-pulse: ch20 before=%0d after=%0d (expect before>0, after==16 重起第1步)",
                 amp_before_mid, dut20_after);
        if(!(amp_before_mid > 0)) begin $display("  FAIL: before not >0"); err_cnt=err_cnt+1; end
        // 新语义 amp = inc×cnt（与用户选定试听模型一致）：帧中 note_on 被消费后起音重起，
        // 拉弦模式下一帧即 +16；只要远小于 before 即证明脉冲未丢、包络已重启。
        if(!(dut20_after == 16'd16)) begin $display("  FAIL: after not 16 (restart)"); err_cnt=err_cnt+1; end
        if(err_cnt == 0) $display("RESULT: ALL PASS");
        else             $display("RESULT: FAIL (%0d mismatches)", err_cnt);
        $finish;
      end
    end
  end

  initial begin
    inited_dummy = 0;
    rst_n = 0;
    repeat(10) @(posedge clk);
    rst_n = 1;
    repeat(400) @(posedge clk);   // > 73 拍，确保 DUT 上电 init 扫描已完成
    inited_dummy = 1;
  end

  initial begin
    #80000000;
    $display("RESULT: FAIL (timeout)");
    $finish;
  end

endmodule