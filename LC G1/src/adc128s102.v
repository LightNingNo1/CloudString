// ============================================================================
// adc128s102.v - ADC 模拟前端分时读取（XADC088S022 / TI ADC088S022，8 通道 8bit SPI SAR ADC）
//   注：模块名沿用历史命名 adc128s102；实际驱动的是 pin-to-pin 兼容的 ADC088S022 系列
//       （武汉芯昌 XADC088S022 或 TI ADC088S022），8bit 分辨率。
// ----------------------------------------------------------------------------
// 硬件连接（外部）：
//   FPGA adc_cs_n -> ADC CS#（低有效；CS 高时 DOUT 高阻）
//   FPGA adc_sclk -> ADC SCLK
//   FPGA adc_din  -> ADC DIN（控制字，MSB first；通道地址在 bit5:3 = ADD2:ADD0）
//   ADC DOUT      -> FPGA adc_dout（转换结果，MSB first）
//   VA = 参考电压（同时是模拟输入满幅），故 8bit 码值 = V/VA*256（左对齐取数后满幅≈4080）
//   本器件内置 8 选 1 多路开关，不需要外置 74HC4051（即取代 adc_mux8.v）
//
// 协议（每帧 16 个 SCLK，CS 低有效）：
//   - CS 下降沿开始一帧并同时启动本次转换，一帧共 16 个 SCLK（3 拍 track + 13 拍转换）。
//   - DIN 在前 8 个 SCLK 上升沿被锁存进控制寄存器，决定"下一个"转换周期的通道：
//       bit7   = DONTC（任意）
//       bit6   = ZERO （必须 0）
//       bit5   = ADD2 ┐
//       bit4   = ADD1 ├ 通道号：000=IN0 … 111=IN7
//       bit3   = ADD0 ┘
//       bit2   = ONE  （【必须为 1】否则 XADC088S022 不能正确工作）
//       bit1,0 = ZERO （必须 0）
//     控制字 = {1'b0, 1'b0, addr[2:0], 1'b1, 2'b00} = 8'b00_ADDR_100。
//   - DOUT 在 SCLK 下降沿更新：第 1~4 个下降沿输出 4 个前导 0，
//     第 5~12 个下降沿输出 8bit 结果（MSB first），第 13~16 个下降沿输出 4 个尾随 0；
//     第 16 个下降沿 DOUT 进入三态。下降沿后 tDACC(<=27ns) 数据有效。
//     → 16bit 移位结果 sr[15:12]=前导0、sr[11:4]=8bit 数据、sr[3:0]=尾随0；
//       取 sr[11:0] 即"数据左对齐 ×16"，与原 12bit 口径一致（满幅≈4080）。
//   - 通道选择带"一帧"流水延迟：本帧结果 = 上一帧 DIN 指定的通道；
//     上电后第一帧结果固定为 IN0（与器件默认一致）。
//
// 本模块实现（fs = 50MHz）：
//   SCLK 周期 = 2*CLK_HALF 拍（默认 16 拍 = 320ns = 3.125MHz，占空比 50%）。
//   XADC088S022/ADC088S022 的 SCLK 规格为 0.8~3.2MHz、采样率 50~200ksps，
//   故必须把 SCLK 降到 3.2MHz 以内（原 8.33MHz 超规格，器件不能正确工作）。
//   每帧固定 16 个 SCLK。
//   帧间 CS 拉高 CS_HIGH 拍（默认 99 拍 ≈ 2us）。
//   每帧耗时 ≈ CS_HIGH + 16*2*CLK_HALF = 99 + 256 = 355 拍 ≈ 7.1us；
//   8 通道一轮 ≈ 57us，即每通道更新率 ≈ 17.6kHz。
//   DOUT 采样点取在 SCLK 低电平末尾（下降沿后 CLK_HALF 拍 = 160ns，
//   大于 tDACC = 27ns，留有余量）；DIN 逐位串行移出（MSB first），靠上升沿锁存，
//   在高电平末尾移位，保证下一位在下降沿前已建立（满足 tDS=10ns），且在上升沿后保持
//   半个 SCLK 周期（160ns > tDH=10ns）。
//
// 通道流水调度：req_ch = 本帧请求的通道，got_ch = 本帧结果所属通道（= 上一帧的 req_ch）。
//   复位时 req_ch=1、got_ch=0，于是第 1 帧读到 IN0（器件上电默认通道），
//   之后逐帧推进，8 帧恰好覆盖 IN0~IN7，第 8 帧结束给出 scan_done。
//
// 平滑：每路做一阶 IIR（新码权重 1/2^SMOOTH_SH，带四舍五入），
//   抑制电位器/连线噪声引起的音高抖动。每通道更新率约 17.6kHz 时，SMOOTH_SH=4 的
//   时间常数约 0.9ms；想更快跟手把 SMOOTH_SH 设为 3，想更稳把 SMOOTH_SH 设为 6。
// ============================================================================
module adc128s102 #(
    parameter [15:0] CS_HIGH   = 16'd99,   // 帧间 CS 高电平拍数
    parameter [15:0] CLK_HALF  = 16'd8,    // SCLK 半周期拍数（>=1）：SCLK = 50M/(2*CLK_HALF)
                                           //   =8 -> 3.125MHz（须 <=3.2MHz，XADC088S022 规格）
    parameter [4:0]  SMOOTH_SH = 5'd4      // IIR 平滑位数，必须 >= 1
)(
    input  wire        clk,
    input  wire        rst_n,
    // ---------------- 外部 SPI 前端 ----------------
    output reg         adc_cs_n,    // CS#（低有效）
    output reg         adc_sclk,    // SCLK
    output wire        adc_din,     // DIN（串行控制字帧，MSB first，逐位移出）
    input  wire        adc_dout,    // DOUT
    // ---------------- 8 路结果（已平滑，0..4095） ----------------
    output wire [11:0] adc_ch0, adc_ch1, adc_ch2, adc_ch3,
    output wire [11:0] adc_ch4, adc_ch5, adc_ch6, adc_ch7,
    output reg  [2:0]  cur_ch,      // 最近完成转换的通道
    output reg         adc_upd,     // 单通道更新脉冲
    output reg         scan_done,   // 八通道一轮完成脉冲
    // ---- 调试：8 通道各自最近一帧的原始 16bit 回读（判断 DOUT 是否被驱动、通道是否切换）----
    output wire [127:0] dbg_raw_all // slot k = ch k：[16*k +: 16]，含 4 前导 0 + 8bit 数据 + 4 尾随 0
);
    localparam [4:0] NBITS = 5'd16;                     // 每帧 SCLK 数
    localparam signed [13:0] ROUND = 14'sd1 << (SMOOTH_SH - 1); // IIR 四舍五入

    localparam [2:0] S_IDLE = 3'd0, S_LO = 3'd1, S_HI = 3'd2, S_DONE = 3'd3;

    reg  [2:0]  st;
    reg  [15:0] cnt;
    reg  [4:0]  bit;
    reg  [15:0] sr;                 // 16bit 串行移位寄存器（4 前导 0 + 8bit 数据 + 4 尾随 0）
    reg  [15:0] din_sr;             // DIN 16bit 帧字移位寄存器（MSB first）
    reg  [2:0]  req_ch;             // 本帧请求的通道（下一帧转换）
    reg  [2:0]  got_ch;             // 本帧结果所属通道（上一帧请求）
    reg signed [12:0] sm [0:7];     // 每路平滑值
    reg [15:0] dbg_raw_r [0:7];     // 每路最近一帧原始 16bit（调试）
    integer n;

    wire signed [13:0] code_s = {2'b0, sr[11:0]};        // 刚收到的 8bit 码（左对齐 ×16，满幅≈4080）
    wire signed [13:0] diff_s = code_s - sm[got_ch];

    assign adc_ch0 = sm[0][11:0];
    assign adc_ch1 = sm[1][11:0];
    assign adc_ch2 = sm[2][11:0];
    assign adc_ch3 = sm[3][11:0];
    assign adc_ch4 = sm[4][11:0];
    assign adc_ch5 = sm[5][11:0];
    assign adc_ch6 = sm[6][11:0];
    assign adc_ch7 = sm[7][11:0];

    // 调试总线：8 通道各自的原始 16bit 帧（slot k = ch k）
    assign dbg_raw_all = {dbg_raw_r[7], dbg_raw_r[6], dbg_raw_r[5], dbg_raw_r[4],
                          dbg_raw_r[3], dbg_raw_r[2], dbg_raw_r[1], dbg_raw_r[0]};

    // DIN 是串行输入：ADC 在前 8 个 SCLK 上升沿把 DIN 逐位 MSB first 移入控制寄存器。
    assign adc_din = din_sr[15];                 // 帧字最高位先出

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            st        <= S_IDLE;
            cnt       <= 16'd0;
            bit       <= 5'd0;
            sr        <= 16'd0;
            din_sr    <= 16'd0;
            req_ch    <= 3'd1;          // 首帧请求 IN1
            got_ch    <= 3'd0;
            cur_ch    <= 3'd0;
            adc_cs_n  <= 1'b1;
            adc_sclk  <= 1'b1;
            adc_upd   <= 1'b0;
            scan_done <= 1'b0;
            for(n=0;n<8;n=n+1) begin
                sm[n]        <= 13'sd2048;  // 上电默认中值（VA=5V 时约 2.5V，滑音 ratio≈2.87）
                dbg_raw_r[n] <= 16'd0;
            end
        end else begin
            adc_upd   <= 1'b0;
            scan_done <= 1'b0;
            case(st)
            // ---- CS 高电平保持（帧间间隔）；随后 CS 拉低、SCLK 保持高，
            //      下一个 SCLK 下降沿即进入 track（满足 datasheet 条件 1）----
            S_IDLE: begin
                adc_sclk <= 1'b1;
                if(cnt != CS_HIGH) cnt <= cnt + 1'b1;
                else begin
                    adc_cs_n <= 1'b0;
                    cnt      <= 16'd0;
                    bit      <= 5'd0;
                    sr       <= 16'd0;
                    din_sr   <= {2'b00, req_ch, 3'b100, 8'd0};  // 帧字：bit2=ONE 必须为 1（MSB 先出）
                    st       <= S_LO;
                end
            end
            // ---- SCLK 低电平：本拍的下降沿已让 ADC 移出下一位 ----
            S_LO: begin
                adc_sclk <= 1'b0;
                if(cnt != CLK_HALF - 1'b1) cnt <= cnt + 1'b1;
                else begin
                    cnt <= 16'd0;
                    sr  <= {sr[14:0], adc_dout};   // 低电平末尾采样（下降沿后 CLK_HALF 拍）
                    st  <= S_HI;
                end
            end
            // ---- SCLK 高电平：DIN 在本拍上升沿被 ADC 锁存，随后移出下一位 ----
            S_HI: begin
                adc_sclk <= 1'b1;
                if(cnt != CLK_HALF - 1'b1) cnt <= cnt + 1'b1;
                else begin
                    cnt    <= 16'd0;
                    din_sr <= {din_sr[14:0], 1'b0};   // 锁存后移位（下降沿前建立下一位）
                    if(bit == NBITS - 1'b1) st <= S_DONE;
                    else begin bit <= bit + 1'b1; st <= S_LO; end
                end
            end
            // ---- 收帧：CS 拉高、IIR 平滑、推进通道流水 ----
            S_DONE: begin
                adc_cs_n   <= 1'b1;
                adc_upd    <= 1'b1;
                sm[got_ch] <= sm[got_ch] + ((diff_s + ROUND) >>> SMOOTH_SH);
                cur_ch     <= got_ch;
                dbg_raw_r[got_ch] <= sr;     // 按通道锁存本帧原始 16bit，供调试串口回读
                if(got_ch == 3'd7) scan_done <= 1'b1;
                got_ch <= req_ch;           // 下一帧的结果 = 本帧请求的通道
                req_ch <= req_ch + 1'b1;    // 3bit 自然回卷 7->0
                cnt    <= 16'd0;
                st     <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule