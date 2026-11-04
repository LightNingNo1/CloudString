`timescale 1ns/1ps
// ============================================================================
// tb_dump.v - 导出"当前设计"的 D11 测试音整链数字输出为文本，供 dump2wav.py 转 WAV
// ----------------------------------------------------------------------------
// 链路与 tone_gen_top 完全一致：
//   adsr_32ch(拨/拉弦) --串行写口--> additive_engine(#SHV=7) -> mix(24bit)
// 参数（与 tone_gen_top 当前一致）：
//   SHV=7、master_vol=16'h7FFF、W_TBL=1~8 次泛音(∝1/n^1.5)、拨弦释放 tau=2^15(0.68s)
// D11 语义（顶层）已改为"按模式选弦、不改音高"，故步长由 +INC= 显式给出：
//   拨弦 C5 所在弦 (v14) -> INC = 23409860 (0x016534c4，C5 ≈523.25Hz)
//   拉弦 第 5 根弦 v4   -> INC = 39370534 (0x0258bf26，A4 =440Hz)
// 激励：前 4 帧数字静音 → 目标声部单拍 note_on → 按住（拉弦保持 SUSTAIN）
// 用法: vvp dump.vvp +NSAMP=24000 +MODE=0 +VOICE=14 +INC=23409860 +OUT=plk_c5.txt
//   MODE : 0=拨弦(ADR) 1=拉弦(ASR)
//   VOICE: 触发声部号（拨弦 14 / 拉弦 4，与顶层 TEST_V_* 一致）
//   INC  : 该声部相位步长（音高表自然值，十进制）
// 输出: 每行 "mix vw"（有符号十进制，逐帧 48kHz）
// ============================================================================
module tb_dump;
    reg clk = 1'b0;
    always #4 clk = ~clk;                 // 功能性时钟，帧长 2500 拍决定 48kHz 节拍

    localparam FRAME = 2500;
    integer NSAMP = 24000;                // 0.5s @48kHz

    reg           rst_n      = 1'b0;
    reg           sample_en  = 1'b0;
    reg  [31:0]   note_on    = 32'd0;
    reg  [31:0]   key_level  = 32'd0;
    reg  [1023:0] inc_all    = 1024'd0;
    reg           mode       = 1'b0;

    wire [15:0] env_wdata;
    wire [4:0]  env_waddr;
    wire        env_we;
    wire signed [23:0] mix;

    adsr_32ch u_adsr (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en),
        .mode(mode), .ch_note_on(note_on), .ch_key_level(key_level),
        .env_wdata(env_wdata), .env_waddr(env_waddr), .env_we(env_we));

    additive_engine #(.SHV(5'd7)) u_eng (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en),
        .mode(mode), .inc_all(inc_all), .note_on(note_on),
        .env_wdata(env_wdata), .env_waddr(env_waddr), .env_we(env_we),
        // 调试写口：本 TB 不用，必须显式拉 0（悬空会让 wgt_pend/pend 变 X，污染包络）
        .wgt_wa(9'd0), .wgt_wd(16'd0), .wgt_we(1'b0),
        .lvl_wa(5'd0), .lvl_wd(8'd0), .lvl_we(1'b0),
        .master_vol(16'h7FFF), .mix(mix));

    integer       f, vsel, msel;
    integer       inccode = 23409860;     // 默认 C5（v14）；由 +INC= 覆盖
    integer       smp = 0;
    reg   [12:0]  fc  = 13'd0;
    reg  [8*64:1] outname;
    reg           ok;

    // ---- 帧节拍 + 每帧导出 ----
    always @(posedge clk) begin
        sample_en <= 1'b0;
        if (fc == FRAME - 1) begin
            fc <= 13'd0;
            sample_en <= 1'b1;
            if (rst_n) begin
                $fwrite(f, "%0d %0d\n", $signed(mix), $signed(u_eng.vw_arr[vsel[4:0]]));
                smp <= smp + 1;
                if (smp + 1 >= NSAMP) begin
                    $fclose(f);
                    $display("DUMP DONE: %0d samples -> %0s (mode=%0d voice=%0d)",
                             NSAMP, outname, mode, vsel);
                    $finish;
                end
            end
        end else fc <= fc + 13'd1;
    end

    // ---- 激励 ----
    initial begin
        outname = "mix_dump.txt";
        ok = $value$plusargs("NSAMP=%d", NSAMP);
        ok = $value$plusargs("MODE=%d",  msel);
        ok = $value$plusargs("VOICE=%d", vsel);
        ok = $value$plusargs("INC=%d",   inccode);
        ok = $value$plusargs("OUT=%s",   outname);
        mode = msel[0];
        f = $fopen(outname, "w");
        if (f == 0) begin
            $display("ERROR: cannot open %0s", outname);
            $finish;
        end
        inc_all[32*vsel +: 32] = inccode[31:0];    // 该声部相位步长（音高表自然值）
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        repeat(4) @(posedge sample_en);           // 先收 4 帧数字静音
        @(posedge clk); note_on = 32'd1 << vsel;  // 按下：单拍脉冲
        @(posedge clk); note_on = 32'd0;
        key_level = 32'd1 << vsel;                // 按住不放（拉弦保持 SUSTAIN）
    end
endmodule