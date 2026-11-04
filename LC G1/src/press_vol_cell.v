// ============================================================================
// press_vol_cell.v - 单路"按压时长 -> 音量"增益 + 松开触发
// ----------------------------------------------------------------------------
// 按下时清零计数器并开始计时；松开瞬间把按压时长映射成增益（Q15），
// 同时产生一个单周期触发脉冲 trig_out。
// 增益映射：按压时长 CNT_MIN~CNT_MAX 线性映射到 G_MIN~G_MAX。
// ============================================================================
module press_vol_cell #(
    parameter [15:0] CNT_MIN = 16'd8681,
    parameter [15:0] CNT_MAX = 16'd43403,
    parameter [15:0] G_MIN   = 16'd8192,
    parameter [15:0] G_MAX   = 16'd32767,
    parameter [31:0] STEP    = 32'd0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,
    input  wire        key_in,       // 1 = 按下
    output reg         trig_out,     // 松开瞬间单周期脉冲
    output reg [15:0]  gain_out      // 锁存的增益（Q15）
);
    reg lvl_q;
    reg [15:0] cnt;

    function [15:0] map_gain(input [15:0] c);
        reg [31:0] cc;
        reg [31:0] g;
        begin
            if (c <= CNT_MIN)      cc = CNT_MIN;
            else if (c >= CNT_MAX) cc = CNT_MAX;
            else                   cc = c;
            g = G_MIN + (((cc - CNT_MIN) * STEP) >> 16);
            map_gain = (g >= G_MAX) ? G_MAX : g[15:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lvl_q    <= 1'b0;
            cnt      <= 16'd0;
            trig_out <= 1'b0;
            gain_out <= G_MIN;
        end else if (sample_en) begin
            lvl_q    <= key_in;
            trig_out <= 1'b0;

            if (key_in & ~lvl_q) begin
                cnt <= 16'd0;
            end else if (key_in) begin
                if (cnt < CNT_MAX) begin
                    cnt <= cnt + 1'b1;
                end
            end else if (~key_in & lvl_q) begin
                trig_out <= 1'b1;
                gain_out <= map_gain(cnt);
            end
        end
    end
endmodule