// ============================================================================
// dbg_tune_ctl.v - 调试模式人机控制（50MHz 外设域）
// ----------------------------------------------------------------------------
// D11（消抖后电平 test_db，按下=0）：
//   长按 >= 1s : 进入/退出调试模式（dbg_en 翻转）；一次按下只翻转一次
//   （短按的"试听"仍由顶层原有的 D11 触发通路完成，见 tone_gen_top 第 4b 节）
//
// 32 路音键（key_level，1=按下/遮挡）：
//   仅在调试模式下生效：某个键持续按住 >= 800ms -> sel_v = 该键声部号
//   中途松开则作废（避免误选）；同时按住多键时取编号最小者。
//   注：调试模式下只有选中声部的按键会发声（顶层按 sel_v 门控触发/电平），
//   故"短按当前选中键"= 试音；长按其他键选音的过程是安静的。
//
// 输出：
//   dbg_en  : 调试模式（电平，跨到 120MHz 域用 2FF）
//   sel_v   : 当前调音声部（电平，跨域用 2FF）
//   blink   : 1Hz 方波（50% 占空），调试模式下让选中声部的 LED 闪烁
// ============================================================================
module dbg_tune_ctl #(
    parameter D11_MS = 1000,     // D11 长按进入/退出调试的判定（ms）
    parameter SEL_MS = 800       // 音键长按选音的判定（ms）
)(
    input  wire        clk,        // 50MHz
    input  wire        rst_n,
    input  wire        test_db,    // D11 消抖后电平：1=松开, 0=按下
    input  wire [31:0] key_level,  // 32 路按键电平（1=按下）
    input  wire        dbg_force,  // 界面强制调试（LCD 调试页，=1 时选音逻辑同调试模式）
    output reg         dbg_en,
    output reg  [4:0]  sel_v,
    output wire        blink
);

// 调试使能（D11 长按切换 或 界面进入调试页）
wire dbg_on = dbg_en | dbg_force;

// ---------------- 1ms 节拍 ----------------
reg [15:0] ms_cnt;
wire       ms_tick = (ms_cnt == 16'd49_999);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)        ms_cnt <= 16'd0;
    else if(ms_tick)  ms_cnt <= 16'd0;
    else              ms_cnt <= ms_cnt + 16'd1;
end

// ---------------- D11 长按：1s 切换调试模式 ----------------
wire       d11_press = ~test_db;             // 1=按下
reg [10:0] d11_cnt;
reg        d11_done;                         // 本次按下已触发过，等松开再复位
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        d11_cnt  <= 11'd0;
        d11_done <= 1'b0;
        dbg_en   <= 1'b0;
    end else if(!d11_press) begin
        d11_cnt  <= 11'd0;
        d11_done <= 1'b0;
    end else if(ms_tick && !d11_done) begin
        if(d11_cnt >= (D11_MS-1)) begin
            d11_cnt  <= 11'd0;
            d11_done <= 1'b1;
            dbg_en   <= ~dbg_en;
        end else begin
            d11_cnt <= d11_cnt + 11'd1;
        end
    end
end

// ---------------- 音键长按选音 ----------------
reg  [31:0] kl_d;
reg  [31:0] cand;                            // 候选键（上升沿锁存）
reg  [9:0]  sel_cnt;
always @(posedge clk) kl_d <= key_level;
wire [31:0] kl_rise   = key_level & ~kl_d;
wire [31:0] cand_held = key_level & cand;

// 候选键号（同时多键取编号最小者）
integer pi;
reg [4:0] pv;
always @(*) begin
    pv = 5'd0;
    for(pi=31; pi>=0; pi=pi-1)
        if(cand[pi]) pv = pi;
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cand    <= 32'd0;
        sel_cnt <= 10'd0;
        sel_v   <= 5'd0;
    end else if(!dbg_on) begin
        cand    <= 32'd0;                    // 退出调试：清候选
        sel_cnt <= 10'd0;
    end else if(cand == 32'd0) begin
        if(kl_rise != 32'd0) begin           // 新按下：开始计时
            cand    <= kl_rise;
            sel_cnt <= 10'd0;
        end
    end else if(cand_held != cand) begin      // 中途松开：作废
        cand    <= 32'd0;
        sel_cnt <= 10'd0;
    end else if(ms_tick) begin
        if(sel_cnt >= (SEL_MS-1)) begin      // 长按达标：选定
            sel_v   <= pv;
            cand    <= 32'd0;
            sel_cnt <= 10'd0;
        end else begin
            sel_cnt <= sel_cnt + 10'd1;
        end
    end
end

// ---------------- 1Hz 闪烁（0.5s 亮 / 0.5s 灭） ----------------
reg [24:0] bcnt;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)                       bcnt <= 25'd0;
    else if(bcnt >= 25'd24_999_999)  bcnt <= 25'd0;
    else                             bcnt <= bcnt + 25'd1;
end
assign blink = (bcnt >= 25'd12_500_000);

endmodule
