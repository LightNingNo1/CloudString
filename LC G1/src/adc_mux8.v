// ============================================================================
// adc_mux8.v - 74HC4051 八选一模拟开关 + MCP3201 单通道 12bit ADC 分时读取
// ----------------------------------------------------------------------------
// 硬件连接（外部）：
//   FPGA mux_sel[2:0] -> 74HC4051 的 A/B/C（A=LSB），/INH(6) 接地，VEE(7) 接地
//   CH0..CH7          -> 八路 0~3.3V 模拟输入，用途分工（见 tone_gen_top.v）：
//                        CH0~CH5 = 六根弦的滑音压控（各弦空弦基频 × ratio=2^(code/2048)）
//                        CH6     = 六弦总音量（0V=静音，3.3V≈满幅，线性）
//                        CH7     = 无效通道，数据丢弃（不参与任何运算）
//   FPGA adc_cs_n     -> MCP3201 /CS
//   FPGA adc_clk      -> MCP3201 DCLK
//   MCP3201 DOUT      -> FPGA adc_dout
//   MCP3201 VREF=VDD=3.3V，所以 12bit 码值 = V/3.3*4095
//
// 时序（fs_clk = 50MHz）：
//   每通道：切 mux -> 等 MUX_SETTLE -> CS 拉低(此刻 ADC 采样) -> 等 CS_SETUP
//          -> 打 LEAD+12 个 DCLK（高/低各 CLK_HALF+1 拍）-> 取数 -> CS 拉高 -> 等 CS_HIGH
//   默认参数下每通道 1405 拍 = 28.1us，八路一轮 11240 拍 = 224.8us（每路更新率 4.4kHz）。
//   DCLK 周期 = 2*(CLK_HALF+1) = 62 拍，即 50MHz/62 = 806kHz，
//   低于 MCP3201 在 3.3V 下的上限，留有余量。
//
// MCP3201 位序：CS 下降沿采样输入；之后的 DCLK 下降沿依次输出
//   第1位 = 无效(仍在采样,Hi-Z)、第2位 = null、第3..14位 = B11..B0（MSB first）。
//   本模块先给一个 DCLK 上升沿，再由每个下降沿让 ADC 移出下一位；
//   DOUT 采样点取在"相邻两个下降沿的正中间"（距本位的下降沿 CLK_HALF+1 拍，
//   约 620ns，远大于 DOUT 的建立时间），且每个 DCLK 周期只移 1 位
//   （早期版本在 S_HI 的每个时钟都移位，会把 sr 冲成全 0 或全 1，
//     表现为码值恒为 0/4095、音高只在 C3 与 C5 之间跳变）。
//   移位 LEAD+12 次后取 sr[11:0]。
//   若实测位序有偏差，只改 LEAD 一个参数即可（前导位数）。
//
// 平滑：每路做一阶 IIR（新码权重 1/2^SMOOTH_SH，带四舍五入），
//   抑制电位器/连线噪声引起的音高抖动，SMOOTH_SH=4 时时间常数约 3.5ms。
// ============================================================================
module adc_mux8 #(
    parameter [15:0] MUX_SETTLE = 16'd237,  // 4.74us，等模拟开关稳定
    parameter [15:0] CS_SETUP   = 16'd60,   // 1.19us，CS 低到第一个时钟
    parameter [15:0] CLK_HALF   = 16'd30,   // 593ns，DCLK 半周期
    parameter [15:0] CS_HIGH    = 16'd237,  // 4.74us，两次转换间 CS 高电平
    parameter [3:0]  LEAD       = 4'd2,     // 数据前的无效位个数
    parameter [4:0]  SMOOTH_SH  = 5'd4      // IIR 平滑位数，必须 >= 1
)(
    input  wire        clk,
    input  wire        rst_n,
    // ---------------- 外部模拟前端 ----------------
    output reg  [2:0]  mux_sel,     // 74HC4051 通道选择
    output reg         adc_cs_n,    // MCP3201 /CS
    output reg         adc_clk,     // MCP3201 DCLK
    input  wire        adc_dout,    // MCP3201 DOUT
    // ---------------- 8 路结果（已平滑，0..4095） ----------------
    output wire [11:0] adc_ch0, adc_ch1, adc_ch2, adc_ch3,
    output wire [11:0] adc_ch4, adc_ch5, adc_ch6, adc_ch7,
    output reg  [2:0]  cur_ch,      // 当前通道
    output reg         adc_upd,     // 单路转换完成脉冲
    output reg         scan_done    // 八路一轮完成脉冲
);
    localparam [3:0] NBITS = LEAD + 4'd12;              // 需要打的总时钟数
    localparam signed [13:0] ROUND = 14'sd1 << (SMOOTH_SH - 1); // IIR 四舍五入

    localparam [2:0] S_HOLD = 3'd0, S_MUX = 3'd1, S_CS = 3'd2,
                     S_LO   = 3'd3, S_HI  = 3'd4, S_DONE = 3'd5;

    reg  [2:0]  st;
    reg  [15:0] cnt;
    reg  [3:0]  bit;
    reg  [14:0] sr;                 // 串行移位寄存器
    reg signed [12:0] sm [0:7];     // 每路平滑值
    integer n;

    wire signed [13:0] code_s = {1'b0, sr[11:0]};        // 刚收到的 12bit 码
    wire signed [13:0] diff_s = code_s - sm[cur_ch];

    assign adc_ch0 = sm[0][11:0];
    assign adc_ch1 = sm[1][11:0];
    assign adc_ch2 = sm[2][11:0];
    assign adc_ch3 = sm[3][11:0];
    assign adc_ch4 = sm[4][11:0];
    assign adc_ch5 = sm[5][11:0];
    assign adc_ch6 = sm[6][11:0];
    assign adc_ch7 = sm[7][11:0];

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            st        <= S_HOLD;
            cnt       <= 16'd0;
            bit       <= 4'd0;
            sr        <= 15'd0;
            cur_ch    <= 3'd0;
            mux_sel   <= 3'd0;
            adc_cs_n  <= 1'b1;
            adc_clk   <= 1'b0;
            adc_upd   <= 1'b0;
            scan_done <= 1'b0;
            for(n=0;n<8;n=n+1) sm[n] <= 13'sd2048;   // 上电默认中值 1.65V（滑音 ratio=2.0）
        end else begin
            adc_upd   <= 1'b0;
            scan_done <= 1'b0;
            case(st)
            // ---- CS 高电平保持，等 ADC 采样电容恢复；顺带切到下一路 ----
            S_HOLD: begin
                adc_cs_n <= 1'b1;
                adc_clk  <= 1'b0;
                if(cnt != CS_HIGH) cnt <= cnt + 1'b1;
                else begin
                    mux_sel <= cur_ch;
                    cnt     <= 16'd0;
                    st      <= S_MUX;
                end
            end
            // ---- 等模拟开关 + 源阻抗稳定 ----
            S_MUX: begin
                if(cnt != MUX_SETTLE) cnt <= cnt + 1'b1;
                else begin
                    adc_cs_n <= 1'b0;       // CS 下降沿：ADC 在此刻采样输入
                    cnt      <= 16'd0;
                    bit      <= 4'd0;
                    st       <= S_CS;
                end
            end
            // ---- 采样保持；结束时打出第一个 DCLK 上升沿 ----
            S_CS: begin
                if(cnt != CS_SETUP) cnt <= cnt + 1'b1;
                else begin cnt <= 16'd0; adc_clk <= 1'b1; st <= S_HI; end
            end
            // ---- DCLK 高：本拍结束时拉低，产生下降沿让 ADC 移出下一位 ----
            S_HI: begin
                if(cnt != CLK_HALF) begin
                    adc_clk <= 1'b1;
                    cnt     <= cnt + 1'b1;
                end else begin
                    adc_clk <= 1'b0;            // 下降沿
                    cnt     <= 16'd0;
                    st      <= S_LO;
                end
            end
            // ---- DCLK 低：中点采样 DOUT，每个周期只移 1 位 ----
            S_LO: begin
                adc_clk <= 1'b0;
                if(cnt != CLK_HALF) cnt <= cnt + 1'b1;
                else begin
                    cnt <= 16'd0;
                    sr  <= {sr[13:0], adc_dout};    // 相邻两个下降沿的正中间
                    if(bit == NBITS - 1'b1) st <= S_DONE;
                    else begin bit <= bit + 1'b1; st <= S_HI; end
                end
            end
            // ---- 取数 + IIR 平滑 + 换通道 ----
            S_DONE: begin
                adc_cs_n <= 1'b1;
                adc_upd  <= 1'b1;
                sm[cur_ch] <= sm[cur_ch] + ((diff_s + ROUND) >>> SMOOTH_SH);
                if(cur_ch == 3'd7) begin
                    scan_done <= 1'b1;
                    cur_ch    <= 3'd0;
                end else begin
                    cur_ch <= cur_ch + 1'b1;
                end
                st <= S_HOLD;
            end
            default: st <= S_HOLD;
            endcase
        end
    end
endmodule