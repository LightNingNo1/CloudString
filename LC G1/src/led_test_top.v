// ============================================================================
// led_test_top.v - 32 颗曲目指引 LED 全量检查顶层（供硬件组使用）
// ----------------------------------------------------------------------------
// 结构（PCB 实测）：一级译码 led_ad1 选"组"（4 组），二级译码 led_ad2 选
//   组内灯位（8 位）。每组 = 2 物理列 × 4 行 = 8 颗灯：
//     组0 = 列1-2，组1 = 列3-4，组2 = 列5-6，组3 = 列7-8
//   组内灯位 p[2:0]：p[1:0] = 行(1..4)，p[2] = 组内列(左/右)
// 检查方式：灯号 k = 0..31 依次亮，每颗 2s，64s 一轮循环。
//   对照下方编号表逐颗核对：任意时刻应只有当前编号的灯亮，其余全灭。
//   - 某颗从不亮         -> 该 LED 或该灯位译码输出（Yk）问题
//   - 某颗常亮(不该亮时亮) -> 该组组线或译码输出恒有效
//   - 灯光弱/忽明忽暗     -> 虚焊/接触不良
// 已知待确认（此前出现）：组2 (5,1)/(5,4)/(6,1)/(6,2)/(6,3)、组3 (7,1)
//   曾常亮/弱亮，本轮若再现即为一级译码输出侧（led_ad1 的 Y2/Y3）焊接问题。
// 编号表（k -> 物理位置）：
//   组0：k 0..7   = (1,1)(1,2)(1,3)(1,4)(2,1)(2,2)(2,3)(2,4)
//   组1：k 8..15  = (3,1)(3,2)(3,3)(3,4)(4,1)(4,2)(4,3)(4,4)
//   组2：k 16..23 = (5,1)(5,2)(5,3)(5,4)(6,1)(6,2)(6,3)(6,4)
//   组3：k 24..31 = (7,1)(7,2)(7,3)(7,4)(8,1)(8,2)(8,3)(8,4)
// 端口与 tone_gen_top 完全一致（复用同一 cst），除 LED 与时钟外其余全部置为
// 安全电平；key_slide 等输入悬空（IO 内部上拉）。
// 用毕：在 IDE 中把顶层模块切回 tone_gen_top 重新综合，即可恢复主设计。
// ============================================================================
module led_test_top(
    input  wire       clk,
    input  wire       key_mode,
    input  wire       key_slide,
    input  wire       enc_a, enc_b, enc_sw,
    input  wire       key_song,
    input  wire       key_test,
    input  wire       bt_rx,
    output wire       bt_tx,
    output wire       hp_bck, hp_ws, hp_din,
    output wire [2:0] key_s,
    input  wire       key_z,
    output wire       key_inh,
    output wire       mux_a0, mux_a1, mux_a2,
    output wire       ir_a0, ir_a1, ir_a2, ir_e3,
    output wire       adc_cs_n, adc_sclk, adc_din,
    input  wire       adc_dout,
    output wire       lcd_clk, lcd_de,
    output wire [4:0] lcd_b,
    output wire [4:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire       dbg_tx,
    output wire       lcd_en,
    output wire       led_en1,
    output wire [2:0] led_ad1,
    output wire [2:0] led_ad2
);

// 上电复位（复用主工程 por_rst.v）
wire rst_n;
por_rst u_por (.clk(clk), .rst_n(rst_n));

// 2s 步进（50MHz -> 100_000_000 拍），灯号 k 0..31 循环（64s 一轮）
localparam [26:0] TICK_MAX = 27'd100_000_000;
reg  [26:0] tick;
reg  [4:0]  k;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tick <= 27'd0;
        k    <= 5'd0;
    end else if (tick == TICK_MAX - 27'd1) begin
        tick <= 27'd0;
        k    <= k + 5'd1;                 // 31 -> 0 自然回卷
    end else begin
        tick <= tick + 27'd1;
    end
end

// ---- LED 矩阵静态直驱：一级使能常开，地址停在当前灯 ----
// 灯号 k：高 2 位选组（led_ad1），低 3 位选组内灯位（led_ad2）
assign led_en1 = 1'b1;                    // 一级 74HC238 使能（高有效）
assign led_ad1 = {1'b0, k[4:3]};          // 组 0..3（A15=bit0, B11=bit1, C12=bit2）
assign led_ad2 = k[2:0];                  // 组内灯位 0..7（A14=bit0, E14=bit1, D15=bit2）

// ---- 其余输出置安全电平（测试 bit 不关心） ----
assign bt_tx   = 1'b1;                    // UART 空闲高
assign hp_bck  = 1'b0;
assign hp_ws   = 1'b0;
assign hp_din  = 1'b0;
assign key_s   = 3'b000;
assign key_inh = 1'b1;                    // 4051 禁能
assign mux_a0  = 1'b0;
assign mux_a1  = 1'b0;
assign mux_a2  = 1'b0;
assign ir_a0   = 1'b0;
assign ir_a1   = 1'b0;
assign ir_a2   = 1'b0;
assign ir_e3   = 1'b0;                    // 红外译码器禁能
assign adc_cs_n = 1'b1;                   // ADC 不选中
assign adc_sclk = 1'b0;
assign adc_din  = 1'b0;
assign lcd_clk  = 1'b0;
assign lcd_de   = 1'b0;
assign lcd_b    = 5'd0;
assign lcd_r    = 5'd0;
assign lcd_g    = 6'd0;
assign dbg_tx   = 1'b1;
assign lcd_en   = 1'b0;

endmodule
