// ============================================================================
// mode_switch.v - 拨弦/拉弦模式切换
// ----------------------------------------------------------------------------
// mode = 0: 拨弦模式（Pluck）- ADR 包络，滑音失效，松开触发，音量由 ADC CH0 统一调控
// mode = 1: 拉弦模式（Bow）  - ASR 包络，滑音使能，按下触发，Sustain 保持
// 每按一次模式键翻转一次。
// 注意：mode 同时也控制音高来源——拨弦用固定音高，拉弦用 ADC 电压，
//       因此 mode 可直接作为 adc_pitch_en 使用。
// ============================================================================
module mode_switch #(
    parameter DEFAULT_MODE = 1'b0        // 上电默认：0=拨弦，1=拉弦
)(
    input  wire clk,
    input  wire rst_n,
    input  wire mode_press,            // 消抖后的按下单周期脉冲
    output reg  mode                   // 0=拨弦, 1=拉弦
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mode <= DEFAULT_MODE;
        else if (mode_press)
            mode <= ~mode;
    end
endmodule