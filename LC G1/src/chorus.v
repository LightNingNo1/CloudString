// ============================================================================
// chorus.v - 合成效果器（Ensemble / Chorus：可变延迟 + LFO 三角波调制）
// ----------------------------------------------------------------------------
// 96kHz 采样 / 120MHz 音频域。
//
// 原理：把输入信号存进环形延迟线，读出时用一个低频三角波调制延迟量，
//   模拟"轻微失谐的叠加声部"，产生合唱/合奏效果。
//   输出 = DRY*x + WET * delay[wr_ptr - D0 + lfo(t)]
//
// 设计要点：
//   - 基础延迟 D0 = 1600 采样 (16.7ms @ 96kHz)
//   - 调制幅度 AMP = 240 采样 (2.5ms)
//   - 调制频率约 0.8Hz（三角波，半周期 = 60 帧）
//   - DEPTH = 2048（D0+AMP=1840 < 2048，D0-AMP=1360 ≥ 0 ✓）
//
// RAM 架构（强制 Gowin 推断 SDPB 而非 DPB）：
//   写口 always 块：一个写地址 wr_addr_reg（= wr_ptr）
//   读口 always 块：一个读地址 rd_addr_reg（= wr_ptr - D0 + lfo_cnt）
//   → 只有 1 写地址 + 1 读地址 → SDPB ✓
//   SDPB 支持同拍不同地址写+读（chorus 每拍写 wr_ptr、读 wr_ptr-D0+lfo_cnt）
//
// 定点：输入/输出 24bit；延迟线存 24bit；干/湿系数 Q15。
// ============================================================================
module chorus #(
    parameter integer DEPTH     = 2048,          // 延迟线深度 2^11 ≈ 21.3ms @ 96kHz
    parameter integer D0        = 1600,          // 基础延迟 16.7ms
    parameter integer AMP       = 240,           // 调制幅度 ±2.5ms
    parameter integer STEP      = 8,             // LFO 每帧步进 → 约 0.8Hz 三角波
    parameter [15:0]  WET       = 16'd16384,      // 湿信号 0.5 (Q15)
    parameter [15:0]  DRY       = 16'd16384       // 干信号 0.5 (Q15)
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  sample_en,
    input  wire signed [23:0]    x_in,
    input  wire                  en,
    output reg  signed [23:0]    y_out
);
    localparam NIDX = $clog2(DEPTH);
    localparam LW   = $clog2(AMP) + 2;          // LFO 位宽：±AMP 带符号

    // ---------- 延迟线 RAM（推断为 Gowin BSRAM SDPB）----------
    reg signed [23:0] delay [0:DEPTH-1];

    // ---------- RAM 独立地址寄存器（关键！强制 SDPB 推断）----------
    reg [NIDX-1:0] wr_addr_reg;
    reg [NIDX-1:0] rd_addr_reg;
    reg             wr_en_reg;
    reg signed [23:0] wr_data_reg;
    reg signed [23:0] rd_data_reg;

    // ---------- LFO 三角波 ----------
    reg signed [LW-1:0] lfo_cnt;    // 范围 -AMP ~ +AMP
    reg                 lfo_dir;     // 0 向上, 1 向下

    // ---------- 状态 + 临时 ----------
    reg                  st;
    reg [NIDX-1:0]       wr_ptr;
    reg signed [23:0]    x_hold;
    reg signed [39:0]    dry_p, wet_p;

    localparam st_IDLE = 1'b0;
    localparam st_MIX  = 1'b1;

    // 读地址 MUX（组合，锁存到 rd_addr_reg）
    // wr_ptr - D0 + lfo_cnt：DEPTH=2^NIDX 自然回绕
    wire [NIDX-1:0] rd_addr_comb = wr_ptr - D0 + lfo_cnt;

    integer qi;
    initial begin
        wr_ptr      = {NIDX{1'b0}};
        wr_addr_reg = {NIDX{1'b0}};
        rd_addr_reg = {NIDX{1'b0}};
        wr_en_reg   = 1'b0;
        wr_data_reg = 24'sd0;
        rd_data_reg = 24'sd0;
        lfo_cnt     = 0;
        lfo_dir     = 1'b0;
        x_hold      = 24'sd0;
    end

    // ---------- SDPB 写口 + 读口：独立 always 块 ----------
    always @(posedge clk) begin
        if(wr_en_reg) delay[wr_addr_reg] <= wr_data_reg;  // 单写地址
        rd_data_reg <= delay[rd_addr_reg];                 // 单读地址，1 拍延迟
    end

    // ---------- 状态机 ----------
    always @(posedge clk) begin
        if(!rst_n) begin
            wr_ptr      <= {NIDX{1'b0}};
            wr_addr_reg <= {NIDX{1'b0}};
            rd_addr_reg <= {NIDX{1'b0}};
            wr_en_reg   <= 1'b0;
            wr_data_reg <= 24'sd0;
            st          <= st_IDLE;
            y_out       <= 24'sd0;
            lfo_cnt     <= 0;
            lfo_dir     <= 1'b0;
            x_hold      <= 24'sd0;

        end else if(!en) begin
            // ------ bypass：直通 ------
            wr_en_reg <= 1'b0;
            y_out     <= x_in;
            st        <= st_IDLE;

        end else case(st)

        st_IDLE: begin
            if(sample_en) begin
                x_hold <= x_in;
                // ① 发起写：新值到环形头（覆盖最旧）
                wr_en_reg   <= 1'b1;
                wr_addr_reg <= wr_ptr;
                wr_data_reg <= x_in;
                // ② 发起延迟读（同拍不同地址，SDPB 完美支持）
                rd_addr_reg <= rd_addr_comb;
                st          <= st_MIX;
            end
        end

        st_MIX: begin
            wr_en_reg <= 1'b0;
            // rd_data_reg = delay[rd_addr_comb]（st_IDLE 发的读，这拍稳定）
            // 混合：out = (DRY·x_in + WET·delayed) >> 15
            dry_p = $signed(x_hold)          * $signed({1'b0, DRY});
            wet_p = $signed(rd_data_reg)    * $signed({1'b0, WET});
            y_out <= (dry_p + wet_p) >>> 15;

            // LFO 三角波更新：每帧步进 STEP，到达 ±AMP 翻转方向
            if(lfo_dir) begin
                lfo_cnt <= lfo_cnt - STEP;
                if(lfo_cnt <= -(AMP - STEP)) lfo_dir <= 1'b0;
            end else begin
                lfo_cnt <= lfo_cnt + STEP;
                if(lfo_cnt >=  (AMP - STEP)) lfo_dir <= 1'b1;
            end

            wr_ptr <= wr_ptr + 1;
            st     <= st_IDLE;
        end

        default: begin
            wr_en_reg <= 1'b0;
            st        <= st_IDLE;
        end
        endcase
    end
endmodule
