// ============================================================================
// mul18_shared.v - 全工程唯一的 18x18 有符号硬乘法器（带 req/ack 握手）
// ----------------------------------------------------------------------------
// 整个工程只有本文件里这一处乘法表达式，Gowin 只会推断出 1 个 DSP。
// 三种乘法都先把操作数补到 18bit 有符号再送进来：
//   A 16x16 无符号（env x gain）：高位补 0，按有符号解释仍为正；
//   B 16x17 有符号（wave x eg）：符号扩展到 18bit；
//   C 28x16 总音量：拆成 2 次 18x18（见 audio_mixer.v）。
//
// 握手：req 拉高并保持 a/b 稳定，LAT 拍后 ack 单拍脉冲，p 与 ack 同拍有效。
// LAT = 3（拍1 打输入，拍2 出乘积，拍3 出 ack/p）。
// ============================================================================
module mul18_shared (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                req,
    input  wire signed [17:0]  a,
    input  wire signed [17:0]  b,
    output reg                 ack,
    output reg  signed [35:0]  p
);
    reg               v1, v2;
    reg signed [17:0] a_r, b_r;
    reg signed [35:0] prod_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_r    <= 18'sd0;
            b_r    <= 18'sd0;
            v1     <= 1'b0;
            v2     <= 1'b0;
            prod_r <= 36'sd0;
            p      <= 36'sd0;
            ack    <= 1'b0;
        end else begin
            a_r    <= a;
            b_r    <= b;
            v1     <= req;
            prod_r <= a_r * b_r;    // 唯一乘法：推断为 1 个 DSP
            v2     <= v1;
            p      <= prod_r;
            ack    <= v2;
        end
    end
endmodule
