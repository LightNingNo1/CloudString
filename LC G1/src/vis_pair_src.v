// ============================================================================
// vis_pair_src.v - 李萨如 X/Y 信号源（音频域 120MHz）
// ----------------------------------------------------------------------------
// 取当前按下的键中【编号最小】和【次小】的两个声部，用它们的基波步长
// （pitch_32v 的 inc_all）各自推进一个 32bit 相位累加器，每拍 sample_en 输出
// 一个正弦样点给 vis_lissajous。这样李萨如图的频率与真实发声完全一致
// （滑音/调试音调改了也会同步变化），且不依赖引擎内部数据。
//
//   osc = 表内线性插值后的正弦，16bit 有符号，满幅 ±127（1 个量化单位 = 屏幕 1 像素）
//   lis_valid = 按下的键 >= 2 个
//   pair_a / pair_b = 两个声部号低 3 位（仅作屏幕标签，原工程 6 弦编号口径）
//
// 【为什么表内插值】64 格表的相邻取值差最大约 127*2π/64 ≈ 12.5，而屏幕 256×256
//   是 1:1 打点：直接取表值时，李萨如轮廓就是 64 边形，肉眼看到的是约 10~12 像素
//   的直线段"锯齿"（之前误判为位图分辨率/打点插值段数，实际是波形源本身的台阶）。
//   这里用相位低 6bit 对相邻两格做线性插值：等效 4096 点正弦，弦高误差 <0.2 像素，
//   折线顶点落在真正的正弦曲线上，锯齿消失。
//
// 资源：两个 32:1 x 32bit 步长选择 + 4 个 64:1 x 16bit 正弦查表（均为常量表，
//       综合成 LUT 选择树）+ 2 个 6x6 小乘法器，相位累加器 2x32 FF。
// ============================================================================
module vis_pair_src (
    input  wire               clk,        // 120MHz 音频域
    input  wire               rst_n,
    input  wire               sample_en,  // 96kHz 帧脉冲
    input  wire [31:0]        key_lvl,    // 1 = 该声部按下
    input  wire [1023:0]      inc_all,    // inc_all[32*v +: 32]
    output reg  signed [15:0] osc_a,
    output reg  signed [15:0] osc_b,
    output reg  [2:0]         pair_a,
    output reg  [2:0]         pair_b,
    output reg                lis_valid
);

    // SIN64[i] = round(127*sin(2*pi*i/64)) * 256（16bit 有符号，i 为最低 16 位）
    localparam [1023:0] SIN64 =
        1024'hFFF4FFE7FFDBFFCFFFC4FFB9FFAFFFA6FF9EFF96FF90FF8BFF86FF83FF82FF81FF82FF83FF86FF8BFF90FF96FF9EFFA6FFAFFFB9FFC4FFCFFFDBFFE7FFF40000000C001900250031003C00470051005A0062006A00700075007A007D007E007F007E007D007A00750070006A0062005A00510047003C003100250019000C0000;

    // ---------------- 最小 / 次小按下声部 ----------------
    // 从 31 向下扫，最后一个写 v0 的即编号最小者。
    reg  [4:0] v0_n, v1_n;
    reg        f0_n, f1_n;
    integer    i;
    always @(*) begin
        v0_n = 5'd0;  v1_n = 5'd0;
        f0_n = 1'b0;  f1_n = 1'b0;
        for (i = 31; i >= 0; i = i - 1) begin
            if (key_lvl[i]) begin
                if (!f0_n) begin
                    v0_n = i[4:0];  f0_n = 1'b1;
                end else if (!f1_n) begin
                    v1_n = i[4:0];  f1_n = 1'b1;
                end
            end
        end
    end

    reg  [4:0] v0, v1;
    reg        lv;
    always @(posedge clk) begin
        v0 <= v0_n;
        v1 <= v1_n;
        lv <= f1_n;                      // 至少两个键按下才画李萨如
    end

    wire [31:0] inc_a = inc_all[32*v0 +: 32];
    wire [31:0] inc_b = inc_all[32*v1 +: 32];

    // ---------------- 相位累加（只在 sample_en 推进，与音频采样同步） ----------------
    reg [31:0] ph_a, ph_b;
    always @(posedge clk) begin
        if (!rst_n) begin
            ph_a <= 32'd0;
            ph_b <= 32'd0;
        end else if (sample_en) begin
            ph_a <= ph_a + inc_a;
            ph_b <= ph_b + inc_b;
        end
    end

    // ---------------- 正弦查表 + 表内线性插值 ----------------
    // 索引 = 相位高 6bit，插值系数 = 相位接下来的 6bit（一格 = 1/64 周期）。
    //   v = S[i] + ((S[i+1]-S[i]) * frac) / 64
    wire [5:0]  ia  = ph_a[31:26];
    wire [5:0]  ib  = ph_b[31:26];
    wire [5:0]  ia1 = ia + 6'd1;               // 回绕到 0 即表循环，天然正确
    wire [5:0]  ib1 = ib + 6'd1;
    wire signed [15:0] sa0 = SIN64[16*ia  +: 16];
    wire signed [15:0] sa1 = SIN64[16*ia1 +: 16];
    wire signed [15:0] sb0 = SIN64[16*ib  +: 16];
    wire signed [15:0] sb1 = SIN64[16*ib1 +: 16];

    // 一级：查表结果与插值系数一起寄存（路径很短，只有选择树）
    reg  signed [15:0] s0a, s1a, s0b, s1b;
    reg  [5:0]         fa, fb;
    always @(posedge clk) begin
        s0a <= sa0;  s1a <= sa1;
        s0b <= sb0;  s1b <= sb1;
        fa  <= ph_a[25:20];
        fb  <= ph_b[25:20];
    end

    // 二级：表内差值（±13，6bit 二补数足够）+ 6x6 乘法 + 舍入右移 6
    //   减法直接取低 6bit：差值落在 ±31 内，模 64 的补码结果依然正确。
    //   乘法的两个操作数都显式补到 12bit —— Verilog 里乘法结果宽度按操作数最大宽度定，
    //   若直接 6bit x 8bit 会截掉高位乘积。
    wire signed [5:0]  da = s1a[5:0] - s0a[5:0];
    wire signed [5:0]  db = s1b[5:0] - s0b[5:0];
    wire signed [11:0] pa = $signed({{6{da[5]}}, da}) * $signed({4'b0000, fa});
    wire signed [11:0] pb = $signed({{6{db[5]}}, db}) * $signed({4'b0000, fb});
    wire signed [15:0] va = s0a + ((pa + 12'sd32) >>> 6);
    wire signed [15:0] vb = s0b + ((pb + 12'sd32) >>> 6);

    always @(posedge clk) begin
        osc_a     <= va;
        osc_b     <= vb;
        pair_a    <= v0[2:0];
        pair_b    <= v1[2:0];
        lis_valid <= lv;
    end

endmodule
