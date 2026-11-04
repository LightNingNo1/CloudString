// ============================================================================
// reverb.v - Schroeder 简化混响（单延迟线 + 3 路互质反射 + 衰减反馈）
// ----------------------------------------------------------------------------
// 96kHz 采样 / 120MHz 音频域。每帧（sample_en）触发一次 5 拍处理，
//   单帧处理在 1250 拍内绰绰有余，效果器完全不影响音频合成链时序。
//
// 算法：
//   delay 环形缓冲区（DEPTH 采样），3 个互质反射偏移 D1/D2/D3 << DEPTH，
//   反馈系数 G（Q15）：当前槽旧值 × G 与输入相加后写回。
//   输出 = DRY*x + WET*(r1+r2+r3)/4    （/4 近似 /3，定点更简单）
//
// RAM 架构（关键！强制 Gowin 推断 SDPB 而非 DPB）：
//   写口 always 块：只看到一个写地址 wr_addr_reg
//   读口 always 块：只看到一个读地址 rd_addr_reg（状态机里的多个读地址
//                   先 MUX 成一个组合线再锁存到 rd_addr_reg）
//   → Gowin 推断 Simple Dual Port RAM（1 写口 + 1 读口）
//   → 默认 Write Mode = Write First (2'b00) ✓（Gowin 支持）
//
//   SDPB 支持：同拍不同地址写 A / 读 B（完美匹配 reverb 的 S_FB 行为）
//   SDPB 不支持：同拍同地址写+读 —— 但 reverb 里 wr_addr ≠ rd_addr 恒成立
//     （rd_r1 = wr_ptr-D1，D1≥1；同拍写 wr_ptr、读 wr_ptr-D1）
//
// 定点：
//   delay 存 20bit 有符号中间值（Q19）
//   输入 24bit Q22 裁到 20bit（右移 4 位）
//   干/湿/反馈系数均 Q15
//   输出扩展回 24bit
// ============================================================================
module reverb #(
    parameter integer DEPTH   = 4096,              // 延迟线深度 2^12 ≈ 42.7ms @ 96kHz
    parameter integer D1      = 1337,              // 3 个互质反射偏移（都 < DEPTH）
    parameter integer D2      = 2017,
    parameter integer D3      = 3167,
    parameter [15:0]  FB_GAIN = 16'd19661,         // 反馈 G = 0.6 (Q15)
    parameter [15:0]  WET     = 16'd13107,         // 湿信号 0.4 (Q15)
    parameter [15:0]  DRY     = 16'd19661          // 干信号 0.6 (Q15)
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  sample_en,
    input  wire signed [23:0]    x_in,            // 24bit 有符号 PCM（输入）
    input  wire                  en,               // 1=开启混响, 0=bypass 直通
    output reg  signed [23:0]    y_out            // 24bit 有符号 PCM（输出）
);
    localparam NIDX = $clog2(DEPTH);

    // ---------- 延迟线 RAM（推断为 Gowin BSRAM SDPB）----------
    reg signed [19:0] delay [0:DEPTH-1];

    // ---------- RAM 独立地址寄存器（关键！让 Gowin 只看到 1 写地址 + 1 读地址）----------
    reg [NIDX-1:0] wr_addr_reg;     // 写地址（只用 wr_ptr）
    reg [NIDX-1:0] rd_addr_reg;     // 读地址（所有读地址 MUX 后锁存）
    reg             wr_en_reg;      // 写使能
    reg signed [19:0] wr_data_reg;  // 写数据
    reg signed [19:0] rd_data_reg;  // 同步读输出（1 拍延迟）

    // ---------- 状态寄存器 ----------
    reg [2:0]       st;
    reg [NIDX-1:0]  wr_ptr;
    reg signed [23:0] x_latched;
    reg signed [19:0] fb_old;
    reg signed [19:0] r1, r2, r3;

    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_FB   = 3'd1;
    localparam [2:0] S_R1   = 3'd2;
    localparam [2:0] S_R2   = 3'd3;
    localparam [2:0] S_R3   = 3'd4;

    // ---------- 反射读地址（组合，MUX 进 rd_addr_reg）----------
    wire [NIDX-1:0] rd_r1 = wr_ptr - D1;
    wire [NIDX-1:0] rd_r2 = wr_ptr - D2;
    wire [NIDX-1:0] rd_r3 = wr_ptr - D3;

    // ---------- SDPB 写口：独立 always 块 ----------
    integer pi;
    initial begin
        wr_ptr      = {NIDX{1'b0}};
        wr_addr_reg = {NIDX{1'b0}};
        rd_addr_reg = {NIDX{1'b0}};
        wr_en_reg   = 1'b0;
        wr_data_reg = 20'sd0;
        rd_data_reg = 20'sd0;
    end

    always @(posedge clk) begin
        // SDPB 写口：单写地址 wr_addr_reg
        if(wr_en_reg) delay[wr_addr_reg] <= wr_data_reg;
        // SDPB 读口：单读地址 rd_addr_reg，同步读 1 拍延迟
        rd_data_reg <= delay[rd_addr_reg];
    end

    // ---------- 状态机：只负责设置 RAM 控制信号 + 处理数据 ----------
    reg signed [22:0] refl_sum;
    reg signed [39:0] wet_p, dry_p;

    always @(posedge clk) begin
        if(!rst_n) begin
            wr_ptr      <= {NIDX{1'b0}};
            wr_addr_reg <= {NIDX{1'b0}};
            rd_addr_reg <= {NIDX{1'b0}};
            wr_en_reg   <= 1'b0;
            wr_data_reg <= 20'sd0;
            st          <= S_IDLE;
            y_out       <= 24'sd0;
            x_latched   <= 24'sd0;
            fb_old      <= 20'sd0;
            r1 <= 20'sd0; r2 <= 20'sd0; r3 <= 20'sd0;

        end else if(!en) begin
            // ------ bypass：直通 ------
            wr_en_reg <= 1'b0;
            y_out     <= x_in;
            st        <= S_IDLE;

        end else case(st)

        S_IDLE: begin
            wr_en_reg <= 1'b0;  // 本拍不写
            if(sample_en) begin
                x_latched   <= x_in;
                // 发起读：delay[wr_ptr]（反馈旧值）→ 1 拍后 rd_data_reg 稳定
                rd_addr_reg <= wr_ptr;
                st          <= S_FB;
            end
        end

        S_FB: begin
            // rd_data_reg 就是 delay[wr_ptr]（S_IDLE 发的读，这拍稳定）
            fb_old <= rd_data_reg;
            // 发起写：新值 = x(24→20 裁) + FB_GAIN × fb_old
            wr_en_reg   <= 1'b1;
            wr_addr_reg <= wr_ptr;
            wr_data_reg <= x_latched[23:4] + (rd_data_reg * $signed({1'b0, FB_GAIN}) >>> 15);
            // 同时发起反射 1 的读（不同地址，SDPB 完美支持同拍写+读不同地址）
            rd_addr_reg <= rd_r1;
            st          <= S_R1;
        end

        S_R1: begin
            wr_en_reg <= 1'b0;
            r1        <= rd_data_reg;   // delay[rd_r1]（S_FB 发的读，这拍稳定）
            rd_addr_reg <= rd_r2;       // 发起反射 2 的读
            st          <= S_R2;
        end

        S_R2: begin
            wr_en_reg <= 1'b0;
            r2        <= rd_data_reg;   // delay[rd_r2]
            rd_addr_reg <= rd_r3;       // 发起反射 3 的读
            st          <= S_R3;
        end

        S_R3: begin
            wr_en_reg <= 1'b0;
            r3        <= rd_data_reg;   // delay[rd_r3]
            // 混合输出（3 路反射加权平均 + 干/湿）
            refl_sum = ((r1 + r2 + r3) >>> 2);
            wet_p    = $signed(refl_sum) * $signed({1'b0, WET});
            dry_p    = $signed(x_latched) * $signed({1'b0, DRY});
            y_out    <= (wet_p + dry_p) >>> 15;
            wr_ptr   <= wr_ptr + 1;
            st       <= S_IDLE;
        end

        default: begin
            wr_en_reg <= 1'b0;
            st        <= S_IDLE;
        end
        endcase
    end
endmodule
