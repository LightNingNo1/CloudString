// ============================================================================
// i2s_tx.v - 标准 I2S 发送器（24bit PCM 左对齐放入 32bit slot，适配MAX98357A）
//            120MHz 音频域版本：小数分频，精确输出 96kHz
// ----------------------------------------------------------------------------
// 时钟关系（输入 clk = 120MHz 音频域时钟，由 Gowin_rPLL_audio 产生）
//   一帧（左右声道各 SLOT_WIDTH 位）总拍数 FRAME_CYCLES = clk / fs
//   本设计 FRAME_CYCLES = 1250（120MHz / 96kHz），SLOT_WIDTH = 32：
//     BCLK 半周期 = FRAME_CYCLES / (2 × 2 × SLOT_WIDTH) = 1250/128 = 9.765625 拍
//     → BCLK 周期 19.53125 拍 → BCLK = 120MHz/19.53125 = 6.144MHz
//     → fs = BCLK / (2×SLOT_WIDTH) = 6.144MHz/64 = 96000.00 Hz（精确）
//   注：SLOT_WIDTH=32 即 MAX98357A 的"BCLK = 64×LRCLK"模式；24bit 数据左对齐、
//       低 8 位补 0，完整保留 24bit 精度（不再截断成 16bit）。
//
//   【为什么不能用固定整数分频】9.765625 不是整数。若用 9 或 10 拍的整数计数器，
//   不但短期抖动，长期频率还会有偏差（音调不准）。改用小数累加器：
//     每拍 acc += 2×2×SLOT_WIDTH(=128)；acc+128 >= FRAME_CYCLES(=1250) 时扣减 1250
//     并翻转 BCLK。长期平均严格等于 9.765625 拍/半周期，抖动仅 ±1 拍。
//   该累加器同时是"每帧 1250 拍"的天然节拍源，无需另设帧计数器。
//
// I2S时序定义（标准Philips I2S）
// 1. LRCLK=0：左声道；LRCLK=1：右声道
// 2. 串行数据在 BCLK 下降沿移出，MSB最先送出
// 3. 声道数据相对于LRCLK边沿滞后1个BCLK周期（标准I2S要求）
//
// 端口说明
// clk        : 音频域系统时钟 120MHz
// rst_n      : 异步复位，低有效
// sample_l   : 左声道 24bit 有符号PCM采样
// sample_r   : 右声道 24bit 有符号PCM采样
// bclk       : I2S位时钟输出
// lrclk      : I2S左右声道时钟
// dout       : I2S串行数据输出
// sample_en  : 帧同步脉冲，每1帧(左右声道一组)产生1个clk高脉冲（120MHz 域），
//              用于通知音频合成链产生下一个采样点
// ============================================================================
module i2s_tx #(
    parameter FRAME_CYCLES = 1250,     // 每帧系统时钟数 = clk/fs（120MHz/96kHz = 1250）
    parameter DATA_WIDTH   = 24,       // PCM有效数据位宽（输入侧）
    parameter SLOT_WIDTH   = 32        // I2S每个声道时隙总位宽（24bit 左对齐，低 8 位补 0）
)(
    input  wire                                clk,
    input  wire                                rst_n,
    input  wire signed [DATA_WIDTH-1:0]        sample_l,
    input  wire signed [DATA_WIDTH-1:0]        sample_r,
    output reg                                 bclk,
    output reg                                 lrclk,
    output reg                                 dout,
    output reg                                 sample_en
);
    // ------------------------------------------------------------------
    // 1. BCLK 小数分频（长期平均 FRAME_CYCLES/(2·2·SLOT_WIDTH) 拍/半周期）
    // ------------------------------------------------------------------
    localparam [12:0] ACC_MOD = FRAME_CYCLES;        // 1250：一帧的总拍数
    localparam [12:0] ACC_INC = (2 * 2 * SLOT_WIDTH);// 128：每帧需要的 BCLK 半周期数（2 声道×2 沿×SLOT_WIDTH）

    reg  [12:0] acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          acc <= 13'd0;
        else if ((acc + ACC_INC) >= ACC_MOD) acc <= acc + ACC_INC - ACC_MOD;
        else                                 acc <= acc + ACC_INC;
    end

    wire bclk_turn = ((acc + ACC_INC) >= ACC_MOD);   // 本拍需要翻转 BCLK

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                bclk <= 1'b0;
        else if (bclk_turn)        bclk <= ~bclk;
    end

    // ------------------------------------------------------------------
    // 检测"数据移出点" = 真正的 BCLK 下降沿：bclk 当前为高、本拍即将翻低。
    //   【修正】原写法 `bclk_turn && (~bclk)` 选中的其实是"当前低、即将翻高"
    //   的上升沿，与下方注释"数据在下降沿更新"相反。标准 I2S 是"发射端在
    //   BCLK 下降沿移出数据、接收端在上升沿采样"；MAX98357A 对 DIN 要求
    //   tSETUP=tHOLD=10ns。若在上升沿更新，DIN 与 BCLK 同沿跳变，对接收端
    //   建立时间≈0，会偶发采错位 —— 表现为干净单音上糊一层"毛刺/发毛"。
    //   改到下降沿后，DIN 在下一个上升沿采样前已稳定半个 BCLK（≈325ns）。
    // ------------------------------------------------------------------
    wire bclk_fall = bclk_turn && bclk;

    // ------------------------------------------------------------------
    // 2. I2S移位、LRCLK声道切换、串行数据输出逻辑
    // 每当数据移出点到来：
    //  1. 把shift_reg最高位送到dout（MSB先行）
    //  2. 移位寄存器左移1bit，最低位补0
    //  3. bit计数+1；当一个声道SLOT_WIDTH bit全部发完，预计算下一LRCLK，加载新声道采样
    //  4. lrclk_next 延迟一拍给到 lrclk，满足I2S：LR变化后延迟1BCLK输出MSB
    // ------------------------------------------------------------------
    reg [$clog2(SLOT_WIDTH)-1:0]  cnt_bit;     // 声道内bit计数：0 ~ SLOT_WIDTH-1
    reg [SLOT_WIDTH-1:0]          shift_reg;   // 移位寄存器，存放当前声道待发送数据
    reg                           lrclk_next;  // 预存下一帧LRCLK值，实现LRCLK延迟1BCLK更新

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_bit    <= 0;
            lrclk      <= 1'b1;
            lrclk_next <= 1'b0;
            dout       <= 1'b0;
            shift_reg  <= {SLOT_WIDTH{1'b0}};
            sample_en  <= 1'b0;
        end else begin
            sample_en <= 1'b0;                       // 默认采样脉冲拉低
            if(bclk_fall) begin
                dout      <= shift_reg[SLOT_WIDTH-1];    // 输出最高位 MSB first
                shift_reg <= {shift_reg[SLOT_WIDTH-2:0], 1'b0}; // 左移，丢弃已发送bit

                // 当前声道 SLOT_WIDTH bit 全部发送完毕
                if (cnt_bit == SLOT_WIDTH - 1) begin
                    cnt_bit <= 0;                        // bit计数器清零，准备下一个声道
                    lrclk_next <= ~lrclk;                // 预先计算下一个声道

                    // lrclk == 1'b1：刚刚发完右声道 → 一帧结束，产生sample_en脉冲
                    // 24bit 采样左对齐放进 32bit 槽（低 8 位补 0，MSB first，符号位保留）
                    if (lrclk == 1'b1) begin
                        shift_reg <= {sample_l, {(SLOT_WIDTH-DATA_WIDTH){1'b0}}};
                        sample_en <= 1'b1;               // 一帧（左右声道全部发完），产生采样脉冲
                    end else begin
                        shift_reg <= {sample_r, {(SLOT_WIDTH-DATA_WIDTH){1'b0}}};
                    end
                end else begin
                    cnt_bit <= cnt_bit + 1'b1;
                end

                // LRCLK延迟1个BCLK周期更新，保证LR边沿与MSB间隔1BCLK，符合飞利浦I2S
                lrclk <= lrclk_next;
            end
        end
    end
endmodule