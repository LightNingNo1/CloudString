// ============================================================================
// ec11.v - EC11 旋转编码器输入：正交解码 + 颤音深度档位 + 轴按开关（按住使能）
// ----------------------------------------------------------------------------
// 接线约定：EC11 的 A/B 两相与轴按开关三路各自的公共端接 GND，引脚侧靠 FPGA
//           内部上拉，所以空闲=高、动作（转动产生低电平 / 按下开关）=低。
//
// 一、正交解码
//   A/B 各自先做"两级同步 + 稳定滤波"：输入连续 FLT_MAX(=14999 拍 ≈ 0.30ms)
//   保持不变才被接受，滤掉机械触点的抖动（EC11 抖动通常在 100us 量级）。
//   滤波后的 {A,B} 按格雷环 0..3 走位：
//     正转 CW ：00->01->11->10->00
//     反转 CCW：00->10->11->01->00
//   走满一整圈（4 次合法跳变）产生一个脉冲，正转记 up_p、反转记 dn_p。
//   合法跳变只有"相邻两位"这一种，若两相同时变化（非法跳变）则丢弃该次跳变，
//   位置环与脉冲都不变，可自恢复。
//
// 二、轴按开关
//   复用 debounce.v（20ms 消抖，输入约定"按下=0"），取反得 vib_en：
//   按住=1（颤音开），松开=0（颤音关）——瞬时开关，不是 toggle。
//
// 三、深度档位
//   depth[3:0] 上电默认 DEPTH_INIT(=8)，up_p 时 +1、dn_p 时 -1，
//   到 DEPTH_MAX(=15) / 0 饱和，不回绕。
// ============================================================================
module ec11 #(
    parameter [3:0] DEPTH_INIT = 4'd8,
    parameter [3:0] DEPTH_MAX  = 4'd15
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enc_a,      // A 相（空闲=1，公共端接 GND）
    input  wire       enc_b,      // B 相
    input  wire       enc_sw,     // 轴按开关：按下=0，松开=1
    output reg  [3:0] depth,      // 颤音深度 0..15
    output wire       vib_en      // 按住轴开关期间为 1
);

    // ---------------- 两级同步（防亚稳态） ----------------
    reg a_s1, a_s2, b_s1, b_s2;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            a_s1 <= 1'b1; a_s2 <= 1'b1;
            b_s1 <= 1'b1; b_s2 <= 1'b1;
        end else begin
            a_s1 <= enc_a; a_s2 <= a_s1;
            b_s1 <= enc_b; b_s2 <= b_s1;
        end
    end

    // ---------------- 稳定滤波：连续 FLT_MAX 拍不变才接受 ----------------
    localparam [13:0] FLT_MAX = 14'd14999;   // 50MHz × 0.30ms
    reg        a_f, b_f;
    reg [13:0] acnt, bcnt;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            a_f  <= 1'b1; b_f  <= 1'b1;
            acnt <= 14'd0; bcnt <= 14'd0;
        end else begin
            if(a_s2 == a_f) acnt <= 14'd0;
            else if(acnt == FLT_MAX) begin a_f <= a_s2; acnt <= 14'd0; end
            else acnt <= acnt + 14'd1;

            if(b_s2 == b_f) bcnt <= 14'd0;
            else if(bcnt == FLT_MAX) begin b_f <= b_s2; bcnt <= 14'd0; end
            else bcnt <= bcnt + 14'd1;
        end
    end

    // ---------------- 格雷环方向解码 ----------------
    wire [1:0] q_now = {a_f, b_f};
    reg  [1:0] q_prev;
    reg  [1:0] q_pos;                 // 位置环 0..3

    wire fwd = (q_prev == 2'b00 && q_now == 2'b01) ||
               (q_prev == 2'b01 && q_now == 2'b11) ||
               (q_prev == 2'b11 && q_now == 2'b10) ||
               (q_prev == 2'b10 && q_now == 2'b00);
    wire rev = (q_prev == 2'b00 && q_now == 2'b10) ||
               (q_prev == 2'b10 && q_now == 2'b11) ||
               (q_prev == 2'b11 && q_now == 2'b01) ||
               (q_prev == 2'b01 && q_now == 2'b00);

    reg up_p, dn_p;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            q_prev <= 2'b00; q_pos <= 2'd0;
            up_p   <= 1'b0;  dn_p  <= 1'b0;
        end else begin
            up_p <= 1'b0;
            dn_p <= 1'b0;
            if(q_now != q_prev) begin
                q_prev <= q_now;
                if(fwd) begin
                    if(q_pos == 2'd3) begin q_pos <= 2'd0; up_p <= 1'b1; end
                    else                   q_pos <= q_pos + 2'd1;
                end else if(rev) begin
                    if(q_pos == 2'd0) begin q_pos <= 2'd3; dn_p <= 1'b1; end
                    else                   q_pos <= q_pos - 2'd1;
                end
                // 既非 fwd 也非 rev：两相同时变化，非法跳变，丢弃
            end
        end
    end

    // ---------------- 深度档位（边界饱和，不回绕） ----------------
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)                            depth <= DEPTH_INIT;
        else if(up_p && (depth < DEPTH_MAX))  depth <= depth + 4'd1;
        else if(dn_p && (depth != 4'd0))      depth <= depth - 4'd1;
    end

    // ---------------- 轴按开关：20ms 消抖 + 取反 ----------------
    wire sw_db;
    debounce u_sw (.clk(clk), .rst_n(rst_n), .key_in(enc_sw),
                   .key_out(sw_db), .key_press(), .key_release());
    assign vib_en = ~sw_db;

endmodule
