// ============================================================================
// mul18_arb.v - 9 个请求方 -> 1 个 18x18 乘法器的固定优先级仲裁
// ----------------------------------------------------------------------------
// 请求方编号：0..7 = 弦0..弦7 的分音乘累加，8 = 混音器。
// 编号小 = 优先级高，且弦优先于混音器 —— 于是混音器必然等 8 根弦的乘法全部
// 算完才拿到乘法器（此时各弦 osc_out 已稳定）。pROM 扫描天然错开、每弦只占
// 约 17 拍，固定优先级不会饿死任何请求方。
//
// 握手：请求方拉高 m_req[n] 并保持 m_a/m_b 稳定，直到收到 m_ack[n]（单拍脉冲）；
//       m_p 在 m_ack 有效那一拍同步有效，广播给所有请求方（各取所需）。
//
// 防重触发：某个请求方被服务后先"阻塞"，直到它自己把 req 撤销，才允许再次
// 参与仲裁 —— 否则请求方撤 req 前会被重复服务一次，产生多余的 ack。
// ============================================================================
module mul18_arb (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [8:0]         m_req,
    input  wire [161:0]       m_a,     // 9 x 18bit，编号 n 占 [18n +: 18]
    input  wire [161:0]       m_b,
    output reg  [8:0]         m_ack,   // one-hot，响应给被选中的请求方
    output reg  signed [35:0] m_p      // 广播乘积（与 m_ack 同拍有效）
);
    // 最低置位 = 最高优先级
    function [3:0] prio;
        input [8:0] r;
        integer i;
        begin
            prio = 4'd0;
            for (i = 8; i >= 0; i = i - 1)
                if (r[i]) prio = i[3:0];
        end
    endfunction

    reg        busy;
    reg [3:0]  sel_r;
    reg [8:0]  blocked;                // 被服务后、尚未撤 req 的请求方

    wire [8:0] req_ok  = m_req & ~blocked;
    wire       any_ok  = |req_ok;
    wire [3:0] sel_now = prio(req_ok);

    wire       start = ~busy & any_ok;
    wire [3:0] sel   = busy ? sel_r : sel_now;

    wire signed [17:0] sa = m_a[sel*18 +: 18];
    wire signed [17:0] sb = m_b[sel*18 +: 18];
    wire               s_ack;
    wire signed [35:0] s_p;

    mul18_shared u_mul (
        .clk(clk), .rst_n(rst_n), .req(start),
        .a(sa), .b(sb), .ack(s_ack), .p(s_p)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy    <= 1'b0;
            sel_r   <= 4'd0;
            blocked <= 9'd0;
            m_ack   <= 9'd0;
            m_p     <= 36'sd0;
        end else begin
            m_ack <= 9'd0;
            if (s_ack) m_p <= s_p;

            // 被服务后先阻塞，直到请求方撤销 req 才解除
            blocked <= blocked & m_req;
            if (busy && s_ack) blocked[sel_r] <= 1'b1;

            if (!busy) begin
                if (any_ok) begin
                    busy  <= 1'b1;
                    sel_r <= sel_now;
                end
            end else if (s_ack) begin
                busy         <= 1'b0;
                m_ack[sel_r] <= 1'b1;
            end
        end
    end
endmodule
