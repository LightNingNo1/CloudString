// ============================================================================
// audio_mixer.v - 8 路音频合成：波形 × 包络 × 按压增益 → 混音 → 总音量 → 限幅
// ----------------------------------------------------------------------------
// 算术结果与旧"纯组合"版本逐位一致，唯一区别是乘法改走全工程共享的 18x18 乘法器
// （mul18_arb / mul18_shared），因此本模块改为顺序状态机：
//   1) 等 8 根弦本采样点的 osc_out 全部算完（str_valid 全部到齐）；
//   2) 锁存各路波形/包络与总音量（此后不再受外部变化影响）；
//   3) 依次对 8 路做 2 次乘法（eg=env×gain、ch=wave×eg），累加得 sum_mix（28bit）；
//   4) 总音量 sum_mix×vol 拆成 2 次 18x18 乘法精确完成；
//   5) 24bit 硬限幅后把 mix 寄存输出。
//
// 每路：eg = env_amp[k] * gain[k]（Q15 截断到 17bit）
//       ch = str_wave[k] * eg >>> CH_SHIFT
// 输出：mix = clamp((sum_mix * vol) >>> 15)，vol 为 Q15（0..32767）
// ============================================================================
module audio_mixer #(
    parameter CH_SHIFT = 6'd7            // 最终右移位数，控制总体增益
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_en,                 // 43.4028kHz 采样脉冲
    input  wire signed [15:0] str0, str1, str2, str3, str4, str5, str6, str7,  // 各弦波形
    input  wire        [15:0] env0, env1, env2, env3, env4, env5, env6, env7,  // ADSR 包络
    input  wire        [127:0] gain,                     // 8 路 Q15 增益，gain[16*k+:16]
    input  wire        [15:0] vol,                       // 总音量 Q15
    input  wire        [7:0]  str_valid,                 // 各弦 osc_out 就绪脉冲
    output reg  [17:0]        mul_a, mul_b,              // 共享乘法器操作数
    output reg                mul_req,                   // 共享乘法器请求
    input  wire               mul_ack,                   // 共享乘法器应答（单拍）
    input  wire signed [35:0] mul_p,                     // 共享乘法器乘积
    output reg  signed [23:0] mix                        // 混音输出
);
    // ---------------- 输入打平为数组 ----------------
    wire signed [15:0] str_wave [0:7];
    wire        [15:0] env_amp  [0:7];

    assign str_wave[0] = str0;  assign str_wave[1] = str1;
    assign str_wave[2] = str2;  assign str_wave[3] = str3;
    assign str_wave[4] = str4;  assign str_wave[5] = str5;
    assign str_wave[6] = str6;  assign str_wave[7] = str7;

    assign env_amp[0] = env0;   assign env_amp[1] = env1;
    assign env_amp[2] = env2;   assign env_amp[3] = env3;
    assign env_amp[4] = env4;   assign env_amp[5] = env5;
    assign env_amp[6] = env6;   assign env_amp[7] = env7;

    // ---------------- 状态 / 寄存器 ----------------
    localparam [3:0]
        X_IDLE = 4'd0,
        X_EG_R = 4'd1, X_EG_W = 4'd2,     // eg = env × gain
        X_CH_R = 4'd3, X_CH_W = 4'd4,     // ch = wave × eg
        X_V1_R = 4'd5, X_V1_W = 4'd6,     // PU = U × V（总音量第 1 次）
        X_V2_R = 4'd7, X_V2_W = 4'd8,     // PH = H × V（总音量第 2 次）
        X_OUT  = 4'd9;

    reg [3:0]         xst;
    reg [2:0]         k;
    reg signed [16:0] eg;
    reg signed [27:0] sum;
    reg        [35:0] pu, ph;
    reg signed [15:0] S [0:7];            // 锁存波形
    reg        [15:0] E [0:7];            // 锁存包络
    reg        [15:0] vol_r;              // 锁存总音量
    reg        [7:0]  seen;               // 已见 str_valid 的弦集合
    reg               ran;                // 本采样周期是否已启动过混音
    integer m;

    wire all_done = &seen;

    // ---------------- 请求方 8（最低优先级）的乘法操作数 ----------------
    wire [15:0] g_sel = gain[16*k +: 16];
    // 总音量 sum_mix(28bit signed) × vol(16bit) 拆分：S = H·2^17 + U
    wire [17:0] U18 = {1'b0, sum[16:0]};
    wire [17:0] H18 = {7'b0, sum[27:17]};
    wire [17:0] V18 = {2'b0, vol_r};
    wire signed [45:0] q_val  = ({10'b0, ph} << 17) + {10'b0, pu};
    wire signed [45:0] vc_val = {28'b0, V18} << 28;
    wire signed [45:0] prod_v = sum[27] ? (q_val - vc_val) : q_val;
    wire signed [29:0] mix_v  = prod_v >>> 15;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            xst     <= X_IDLE;
            k       <= 3'd0;
            eg      <= 17'sd0;
            sum     <= 28'sd0;
            pu      <= 36'd0;
            ph      <= 36'd0;
            mul_a   <= 18'sd0;
            mul_b   <= 18'sd0;
            mul_req <= 1'b0;
            mix     <= 24'sd0;
            seen    <= 8'd0;
            ran     <= 1'b0;
            vol_r   <= 16'd0;
            for(m=0;m<8;m=m+1) begin S[m] <= 16'sd0; E[m] <= 16'd0; end
        end else begin
            if(sample_en) begin
                seen <= 8'd0;                       // 新采样周期：重新等 8 根弦
                ran  <= 1'b0;
            end else begin
                seen <= seen | str_valid;
            end

            case(xst)
            X_IDLE: begin
                mul_req <= 1'b0;
                if(all_done && !ran) begin         // 8 弦 osc_out 均已稳定
                    ran   <= 1'b1;
                    vol_r <= vol;
                    for(m=0;m<8;m=m+1) begin
                        S[m] <= str_wave[m];
                        E[m] <= env_amp[m];
                    end
                    k   <= 3'd0;
                    sum <= 28'sd0;
                    xst <= X_EG_R;
                end
            end
            X_EG_R: begin
                mul_a   <= {2'b00, E[k]};
                mul_b   <= {2'b00, g_sel};
                mul_req <= 1'b1;
                xst     <= X_EG_W;
            end
            X_EG_W: if(mul_ack) begin
                mul_req <= 1'b0;
                eg      <= $signed(mul_p[31:15]);  // (env×gain)>>15，17bit 有符号
                xst     <= X_CH_R;
            end
            X_CH_R: begin
                mul_a   <= {{2{S[k][15]}}, S[k]};  // 波形 16bit 有符号 -> 18bit
                mul_b   <= {eg[16], eg};           // eg 17bit 有符号 -> 18bit
                mul_req <= 1'b1;
                xst     <= X_CH_W;
            end
            X_CH_W: if(mul_ack) begin
                mul_req <= 1'b0;
                sum     <= sum + ($signed(mul_p[32:0]) >>> CH_SHIFT);
                if(k == 3'd7) xst <= X_V1_R;
                else begin
                    k   <= k + 1'b1;
                    xst <= X_EG_R;
                end
            end
            X_V1_R: begin
                mul_a   <= U18;
                mul_b   <= V18;
                mul_req <= 1'b1;
                xst     <= X_V1_W;
            end
            X_V1_W: if(mul_ack) begin
                mul_req <= 1'b0;
                pu      <= mul_p[35:0];
                xst     <= X_V2_R;
            end
            X_V2_R: begin
                mul_a   <= H18;
                mul_b   <= V18;
                mul_req <= 1'b1;
                xst     <= X_V2_W;
            end
            X_V2_W: if(mul_ack) begin
                mul_req <= 1'b0;
                ph      <= mul_p[35:0];
                xst     <= X_OUT;
            end
            default: begin                          // X_OUT：24bit 硬限幅
                mix <= (mix_v >=  30'sh7FFFFF) ?  24'sh7FFFFF :
                       (mix_v <= -30'sh800000) ? -24'sh800000 : mix_v[23:0];
                xst <= X_IDLE;
            end
            endcase
        end
    end
endmodule
