// ============================================================================
// press_vol.v - 六路"按压时长 -> 音量"增益 + 松开触发
// ----------------------------------------------------------------------------
// 例化 6 个 press_vol_cell（见 press_vol_cell.v），每路独立计时、映射增益、
// 松开瞬间产生触发脉冲。增益为 Q15 格式，按压时长 0.2s~1.0s 映射到 0.25~1.00。
// ============================================================================
module press_vol #(
    parameter [15:0] CNT_MIN = 16'd4340,    // 0.2 s @ fs = 21.7014 kHz
    parameter [15:0] CNT_MAX = 16'd21701,   // 1.0 s @ fs = 21.7014 kHz
    parameter [15:0] G_MIN   = 16'd8192,   // 最小音量 0.25 (-12 dB)
    parameter [15:0] G_MAX   = 16'd32767   // 最大音量 1.00 (0 dB)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,
    input  wire [5:0]  key_level,   // 1 = 按下
    output wire [5:0]  trig,        // 每路松开瞬间单周期脉冲
    output wire [95:0] gain         // 每路 16bit Q15，第 n 路 = gain[16*n +: 16]
);

    localparam [31:0] C_SPAN = CNT_MAX - CNT_MIN;
    localparam [31:0] STEP   = 32'd65536;

    genvar i;
    generate
    for (i = 0; i < 6; i = i + 1) begin : g_chan
        wire trig_w;
        wire [15:0] gain_w;
        press_vol_cell #(
            .CNT_MIN(CNT_MIN),
            .CNT_MAX(CNT_MAX),
            .G_MIN(G_MIN),
            .G_MAX(G_MAX),
            .STEP(STEP)
        ) cell_inst (
            .clk(clk),
            .rst_n(rst_n),
            .sample_en(sample_en),
            .key_in(key_level[i]),
            .trig_out(trig_w),
            .gain_out(gain_w)
        );
        assign trig[i] = trig_w;
        assign gain[16*i +:16] = gain_w;
    end
    endgenerate

endmodule