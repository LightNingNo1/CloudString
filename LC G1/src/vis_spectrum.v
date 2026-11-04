// ============================================================================
// vis_spectrum.v - 最终合成波形(mix)的实时频谱（符号相关 DFT，无乘法器）
// ----------------------------------------------------------------------------
// 算法：N=512 点一帧，对 k=1..63 各频点计算"符号相关"
//        C[k] = Σ sign(x[n]) * sign(cos(2π·n·k/512))
//        S[k] = Σ sign(x[n]) * sign(sin(2π·n·k/512))
//      幅度近似 M = |C| + |S|。sign() 只有 ±1，所以全程只有加减，不占 DSP；
//      频点间隔 fs/N = 42187.5/512 = 82.4Hz，覆盖 82Hz~5.2kHz
//      （C4=261.6 落在 bin3、A4=440 落在 bin5、C5=523 落在 bin6，
//        各弦 2/3/4 次分音沿 bin6/9/12 阶梯清晰可见）。
//
// 时序：CLEAR(64 拍清零) -> 采 512 个 sample_en（512×640/27MHz=12.1ms，
//   超过半帧但小于一帧 18.5ms），每采样后用 2 拍×63 频点完成累加
//   （126 拍 << 采样间隔 640 拍）-> MAG 阶段把幅度写进幅值 RAM。
//   相位 ph=n·k mod 512 用"每换一个频点加一次 n"递推，连乘法都省了。
//
// 双缓冲：幅值 RAM 深 256，{bank,1'b0,bin}（两 bank 间各插一行空行凑推断
//   阈值）。start 时翻转写 bank，整段分析写新
//   bank；pclk 读 ~wbank（上一帧已算完的 bank）。因分析时长 12.1ms 且
//   start 位于帧末消隐期，下一帧末（18.5ms）再次 start 时 MAG 早已写完，
//   屏上看到的是前一帧的频谱，延迟 1 帧且无撕裂。
//
// 符号约定（512 点周期）：cos 在相位 128..383 为负 = ph[7]；
//   sin 在 256..511 为负 = ph[8]。
// RAM：cmem/smem 各补到 128×16、mmem 补到 128×16——Gowin 对 ≥2048bit 的
//   数组才推断 BSRAM（更小会落到 LUT 分布式 RAM）。多出的位/行写零浪费，
//   换来省下约 2500 个寄存器/LUT。cmem/smem 为 clk 单口，mmem 为 clk 写 /
//   pclk 读简单双口（SDP）。
// ============================================================================
module vis_spectrum (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_en,
    input  wire               start,      // 采集启动（clk 域单周期脉冲）
    input  wire signed [15:0] s16,        // mix 截高 16bit（只用其符号位）
    input  wire               pclk,
    input  wire [5:0]         rbin,       // 频点号 0..63
    output reg  [7:0]         rmag        // 柱高 0..104（1 拍 pclk 流水）
);
    localparam [2:0] ST_IDLE = 3'd0, ST_CLR = 3'd1, ST_WAIT = 3'd2,
                     ST_RD = 3'd3, ST_UP = 3'd4, M_RD = 3'd5, M_UP = 3'd6;

    reg [2:0]          st;
    reg [6:0]          ci;      // 清零地址
    reg [9:0]          n;       // 采样序号 0..511
    reg [6:0]          k;       // 频点号 1..63
    reg [8:0]          ph;      // n*k mod 512
    reg                xsgn;    // 本采样符号：1=负
    reg                wbank;   // 当前帧写入 bank
    reg signed [15:0]  xc, xs;  // 计数器读回值（补宽配合块 RAM 端口）

    // cmem/smem：实际只用 0..63 / 低 11bit，补宽补深到 128×16 以推断 BSRAM。
    // mmem：双时钟 SDP 阈值更高，做深到 256×8（两 bank 各 128 行、中间插空行）。
    reg signed [15:0]  cmem [0:127];
    reg signed [15:0]  smem [0:127];
    reg [7:0]          mmem [0:255];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= ST_IDLE;
            wbank <= 1'b0;
            ci    <= 7'd0;
            n     <= 10'd0;
            k     <= 7'd1;
            ph    <= 9'd0;
            xsgn  <= 1'b0;
        end else begin
            case (st)
            ST_IDLE:
                if (start) begin
                    wbank <= ~wbank;       // 新帧写另一个 bank
                    ci    <= 7'd0;
                    st    <= ST_CLR;
                end

            ST_CLR: begin
                    cmem[ci] <= 16'sd0;
                    smem[ci] <= 16'sd0;
                    if (ci == 7'd127) begin
                        n  <= 10'd0;
                        st <= ST_WAIT;
                    end else begin
                        ci <= ci + 7'd1;
                    end
                end

            ST_WAIT:
                if (sample_en) begin
                    xsgn <= s16[15];       // 锁存本采样符号
                    ph   <= n[8:0];        // k=1 时相位 = n
                    k    <= 7'd1;
                    st   <= ST_RD;
                end

            ST_RD: begin
                    xc <= cmem[k];
                    xs <= smem[k];
                    st <= ST_UP;
                end

            ST_UP: begin
                    // ±1：输入符号与基函数符号相同为 +1，相异为 -1
                    cmem[k] <= xc + ((xsgn ^ ph[7]) ? -16'sd1 : 16'sd1);
                    smem[k] <= xs + ((xsgn ^ ph[8]) ? -16'sd1 : 16'sd1);
                    if (k == 7'd63) begin
                        if (n == 10'd511) begin
                            k  <= 7'd0;
                            st <= M_RD;    // 512 点采完 -> 算幅度（k=0 自然为 0）
                        end else begin
                            n  <= n + 10'd1;
                            st <= ST_WAIT;
                        end
                    end else begin
                        k  <= k + 7'd1;
                        ph <= ph + n[8:0]; // 下一频点相位再加 n
                        st <= ST_RD;
                    end
                end

            M_RD: begin
                    xc <= cmem[k];
                    xs <= smem[k];
                    st <= M_UP;
                end

            M_UP: begin : MAG_W
                    reg signed [17:0] ac;
                    reg [7:0]         h;
                    begin
                        ac = (xc < 0 ? -xc : xc) + (xs < 0 ? -xs : xs);
                        // |C|+|S| 最大约 724；>>2 满量程超百像素，
                        // 416>>2=104 封顶（柱区可视高 96，超出部分自然截掉）
                        h  = (ac > 18'sd416) ? 8'd104 : ac[9:2];
                        // 唯一一条 mmem 写语句（k=0..63 全覆盖，bin0 恒为 0）
                        mmem[{wbank, 1'b0, k[5:0]}] <= h;
                        if (k == 7'd63) begin
                            st <= ST_IDLE;
                        end else begin
                            k  <= k + 7'd1;
                            st <= M_RD;
                        end
                    end
                end

            default: st <= ST_IDLE;
            endcase
        end
    end

    // 写 bank 同步到 pclk；读与之相对的、上一帧已完成的 bank
    reg wb_s1, wb_s2;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            wb_s1 <= 1'b0;
            wb_s2 <= 1'b0;
        end else begin
            wb_s1 <= wbank;
            wb_s2 <= wb_s1;
        end
    end

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) rmag <= 8'd0;
        else        rmag <= mmem[{~wb_s2, 1'b0, rbin}];
    end
endmodule
