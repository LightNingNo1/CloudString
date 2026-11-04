// ============================================================================
// dbg_tune.v - 音色调试参数派生（120MHz 音频域）
// ----------------------------------------------------------------------------
// 六路滑轨（ADC ch1~ch6）在调试模式下分别调整：
//   ch1 音调 / ch2 响度 / ch3 A / ch4 D（拉弦无 D 段，天然无效）/ ch5 R /
//   ch6 基音与泛音组的比例
// 每个声部按模式分两组（共 64 组）各存 6 个 8bit 偏移 t8：
//   t8 = clamp((code-2048)/16, -121, 121)，|code-2048| <= 96 视为 0（中位死区）
// 所有参数都在基准值附近按 t8 调整：
//   ch1 音调 : ratio = 65536 + 128*t8      -> 0.76 ~ 1.24 倍（约 ±4.5 个半音）
//   ch2 响度 : lvl   = clamp(128+t8, 64, 255) -> 0.5 ~ 1.95 倍（引擎 S_VOICE 内乘）
//   ch3 A    : A_INC = clamp(A_base*m >> 8, 1, 1023)
//              m = t8>=0 ? 256+6*t8 : 256-3*|t8|/2   -> 约 0.29 ~ 3.8 倍起音时间
//   ch4 D    : D_SH = 17 + doff（基准 17，仅拨弦有 D 段）
//   ch5 R    : R_SH = R_base + doff（拨弦基准 18 / 拉弦 13）
//              doff = t8>=96?+2 : t8>=32?+1 : t8<=-96?-2 : t8<=-32?-1 : 0
//   ch6 平衡 : 单侧衰减，保证 ΣW 不超过基准（不削顶）
//              t8>0 -> 基音组 x(128-|t8|)/128，泛音组 x1
//              t8<0 -> 基音组 x1，泛音组 x(128-|t8|)/128
//
// 触发时机：
//   上电 / 模式切换      -> 全部 32 声部按存储参数重写（音高比例、A/D/R、权重、响度）
//   调试模式下滑轨变化    -> 先存入选中声部的参数槽，再只重写该声部
//   （变化检测比较的是量化后的 t8，非 ADC 原码；重写期间的滑轨改动会在作业结束后补上）
//   dbg_hold = 1（选中声部正在发声，含尾音）时冻结滑轨载入：appl 不更新，
//   滑轨新值一直挂起（adc_chg 持续为真），等该声部包络消失后自动补上。
// 每声部 17 次 18x18 乘法（A_INC 1 次 + 16 个泛音权重），一次一个串行完成，
// 全部 32 声部约 1300 拍（≈11us），只在人操作时发生，不占每帧音频预算。
// ============================================================================
module dbg_tune (
    input  wire        clk,          // 120MHz
    input  wire        rst_n,
    input  wire        mode,         // 0=拨弦 1=拉弦（已同步）
    input  wire        dbg_en,       // 调试模式（已同步）
    input  wire [4:0]  sel_v,        // 当前选中声部（已同步）
    input  wire        dbg_hold,     // 1 = 选中声部正在发声：冻结滑轨参数载入
    input  wire [11:0] adc1, adc2, adc3, adc4, adc5, adc6,   // 六路滑轨（已同步）
    // ---- 音高比例写口（pitch_32v）----
    output reg         wrt_en,
    output reg  [4:0]  wrt_v,
    output reg  [17:0] wrt_ratio,
    // ---- A/D/R 参数写口（adsr_32ch）----
    output reg  [4:0]  prm_wa,
    output reg  [19:0] prm_wd,
    output reg         prm_we,
    // ---- 泛音权重写口（additive_engine）----
    output reg  [8:0]  wgt_wa,
    output reg  [15:0] wgt_wd,
    output reg         wgt_we,
    // ---- 响度写口（additive_engine）----
    output reg  [4:0]  lvl_wa,
    output reg  [7:0]  lvl_wd,
    output reg         lvl_we
);

// ---------------- 基准表（与各模块 localparam 一致） ----------------
localparam [255:0] W_PLK =
    256'h000000000000000000000000000000000000000000000FD50B3519190D543B87;
localparam [255:0] W_BOW =
    256'h0044006B00AA010D01AA02A4035302F604B2054405E90BCA07710D3B25491A66;

localparam [9:0] A_BASE_PLK = 10'd114;
localparam [9:0] A_BASE_BOW = 10'd8;
localparam [4:0] R_BASE_PLK = 5'd18;
localparam [4:0] R_BASE_BOW = 5'd13;

// ---------------- 每声部参数槽（{模式, 声部号} x 6 个 t8） ----------------
// 上电全 0 = 不偏移，等价于各模块的基准常量。
reg  [47:0] pak [0:63];
integer ki;
initial begin
    for(ki=0; ki<64; ki=ki+1) pak[ki] = 48'd0;
end

// ---------------- 滑轨码值 -> t8（带中位死区） ----------------
function [7:0] adc_t8;
    input [11:0] code;
    reg signed [12:0] d;
    begin
        d = $signed({1'b0, code}) - 13'sd2048;
        if(d > 13'sd2032)       d = 13'sd2032;
        else if(d < -13'sd2032) d = -13'sd2032;
        if(d > 13'sd96)         d = d - 13'sd96;
        else if(d < -13'sd96)   d = d + 13'sd96;
        else                    d = 13'sd0;
        adc_t8 = d >>> 4;                     // /16
    end
endfunction

wire [7:0] t8_ch1 = adc_t8(adc1);
wire [7:0] t8_ch2 = adc_t8(adc2);
wire [7:0] t8_ch3 = adc_t8(adc3);
wire [7:0] t8_ch4 = adc_t8(adc4);
wire [7:0] t8_ch5 = adc_t8(adc5);
wire [7:0] t8_ch6 = adc_t8(adc6);

// ---------------- 事件检测 ----------------
// 比较对象是"量化后的 t8"而不是 ADC 原码：滑轨末位抖动不会引发无谓重写。
// appl = 已写入参数槽的 t8 快照；与当前 snap 不等即表示"有一笔待处理动作"，
// 即使在重写作业期间滑轨又动了，作业结束后也会补上（不会被单拍边沿漏掉）。
reg         mode_d, dbg_d;
reg  [47:0] snap;                // {t8_ch6..t8_ch1}
reg  [47:0] appl;                // 已应用的 t8 快照
always @(posedge clk) begin
    mode_d <= mode;
    dbg_d  <= dbg_en;
    snap   <= {t8_ch6, t8_ch5, t8_ch4, t8_ch3, t8_ch2, t8_ch1};
end
wire mode_chg = (mode_d != mode);
wire dbg_rise = dbg_en & ~dbg_d;
wire adc_chg  = (snap != appl);

// 上电初始化请求（等存储/乘法器稳定后启动一次全量重写）
reg [5:0] init_cnt;
reg       started;
always @(posedge clk) begin
    if(!rst_n) begin
        init_cnt <= 6'd0;
        started  <= 1'b0;
    end else if(!started) begin
        init_cnt <= init_cnt + 6'd1;
        if(init_cnt == 6'd63) started <= 1'b1;
    end
end
wire init_req = (init_cnt == 6'd3);

// ---------------- 当前作业的声部与参数 ----------------
reg  [4:0] vj;                   // 作业声部
reg        mode_j;               // 作业模式（作业期间锁定）
reg        all_j;                // 1 = 本次要扫完全部 32 声部
reg  [47:0] job;                 // 当前声部参数（6 x t8）
reg  [3:0] h;                    // 泛音序号（查基准表用）
reg  [3:0] hr;                   // 泛音序号（写回用）

wire signed [7:0] t_p = job[7:0];
wire signed [7:0] t_l = job[15:8];
wire signed [7:0] t_a = job[23:16];
wire signed [7:0] t_d = job[31:24];
wire signed [7:0] t_r = job[39:32];
wire signed [7:0] t_b = job[47:40];

// ch1 音调：ratio = 65536 + 128*t8（Q16）
wire signed [17:0] t_p_s = {{10{t_p[7]}}, t_p};
wire        [17:0] ratio = 18'd65536 + (t_p_s <<< 7);

// ch2 响度：Q7，128 = 1.0
wire signed [8:0] lvl_s = {t_l[7], t_l} + 9'sd128;
wire        [7:0] lvl_v = (lvl_s < 9'sd64) ? 8'd64 : lvl_s[7:0];

// ch3 起音：m = 256 + 6*t（t>=0） / 256 - 1.5*|t|（t<0）
wire [7:0]  t_a_mag = t_a[7] ? (~t_a + 8'd1) : t_a;
wire [10:0] m_att   = t_a[7] ? (11'd256 - ((11'd3 * t_a_mag) >> 1))
                             : (11'd256 + (11'd6 * t_a_mag));
wire [9:0]  a_base  = mode_j ? A_BASE_BOW : A_BASE_PLK;

// ch4(D) / ch5(R)：各自独立的衰减档位 doff（-2..+2）
//   D 滑块只动拨弦 D 段右移量（16+doff）；R 滑块只动释放段右移量（基准+doff）。
//   拉弦模式没有 D 段，ch4 天然无效（需求即如此）。
wire signed [2:0] doff_d = (t_d >= 8'sd96)  ?  3'sd2 :
                           (t_d >= 8'sd32)  ?  3'sd1 :
                           (t_d <= -8'sd96) ? -3'sd2 :
                           (t_d <= -8'sd32) ? -3'sd1 : 3'sd0;
wire signed [2:0] doff_r = (t_r >= 8'sd96)  ?  3'sd2 :
                           (t_r >= 8'sd32)  ?  3'sd1 :
                           (t_r <= -8'sd96) ? -3'sd2 :
                           (t_r <= -8'sd32) ? -3'sd1 : 3'sd0;
wire [4:0] r_base = mode_j ? R_BASE_BOW : R_BASE_PLK;
wire signed [5:0] r_base_s = {1'b0, r_base};        // 需声明为 signed，否则带 doff 的加法会按无符号算
wire signed [5:0] d_sh_s = 6'sd17 + doff_d;         // 15..19
wire signed [5:0] r_sh_s = r_base_s + doff_r;       // 11..20
wire [4:0] d_sh   = d_sh_s[4:0];
wire [4:0] r_sh   = r_sh_s[4:0];

// ch6 平衡：单侧衰减
wire [7:0] t_b_mag = t_b[7] ? (~t_b + 8'd1) : t_b;
wire [7:0] g_fund  = t_b[7] ? 8'd128 : (8'd128 - t_b_mag);
wire [7:0] g_ovt   = t_b[7] ? (8'd128 - t_b_mag) : 8'd128;
wire [7:0] g_sel   = (h == 4'd0) ? g_fund : g_ovt;
wire [15:0] bw     = mode_j ? W_BOW[16*h +: 16] : W_PLK[16*h +: 16];

// ---------------- 共享乘法（一次一个，寄存器输入 -> 组合乘积） ----------------
reg  [17:0] ma, mb;
wire [35:0] mprod = ma * mb;
wire [9:0]  a_inc = (mprod[17:8] == 18'd0) ? 10'd1 :
                    (mprod[17:8] > 18'd1023) ? 10'd1023 : mprod[17:8];

// ---------------- 作业状态机 ----------------
localparam Q_IDLE = 4'd0, Q_CAP = 4'd1, Q_LOAD = 4'd2, Q_P = 4'd3,
           Q_A0   = 4'd4, Q_A1 = 4'd5, Q_W0  = 4'd6, Q_W1 = 4'd7,
           Q_NEXT = 4'd8;

reg [3:0] st;

always @(posedge clk) begin
    if(!rst_n) begin
        st       <= Q_IDLE;
        vj       <= 5'd0;
        mode_j   <= 1'b0;
        all_j    <= 1'b0;
        job      <= 48'd0;
        h        <= 4'd0;
        hr       <= 4'd0;
        appl     <= 48'd0;
        ma       <= 18'd0;
        mb       <= 18'd0;
        wrt_en   <= 1'b0;  wrt_v <= 5'd0;   wrt_ratio <= 18'd65536;
        prm_wa   <= 5'd0;  prm_wd <= 20'd0; prm_we <= 1'b0;
        wgt_wa   <= 9'd0;  wgt_wd <= 16'd0; wgt_we <= 1'b0;
        lvl_wa   <= 5'd0;  lvl_wd <= 8'd0;  lvl_we <= 1'b0;
    end else begin
        // 写口脉冲默认清零（各状态按需拉高一拍）
        wrt_en <= 1'b0;
        prm_we <= 1'b0;
        wgt_we <= 1'b0;
        lvl_we <= 1'b0;

        case(st)
        Q_IDLE: begin
            if(init_req || mode_chg) begin
                // 上电/换模式：按已存参数全量重写 32 声部
                appl <= snap;
                vj <= 5'd0;  mode_j <= mode;  all_j <= 1'b1;  st <= Q_LOAD;
            end else if(dbg_rise) begin
                // 刚进调试：以当前滑轨位置为基准，不当作一次调节动作
                appl <= snap;
            end else if(dbg_en && adc_chg && !dbg_hold) begin
                // 先把六路滑轨的新值存入选中声部，再走一拍让写落地
                // （发声期间 dbg_hold=1：不更新 appl，滑轨新值挂起到本音结束）
                pak[{mode, sel_v}] <= snap;
                appl <= snap;
                vj <= sel_v;  mode_j <= mode;  all_j <= 1'b0;  st <= Q_CAP;
            end
        end

        Q_CAP: st <= Q_LOAD;

        Q_LOAD: begin
            job <= pak[{mode_j, vj}];
            h   <= 4'd0;
            hr  <= 4'd0;
            st  <= Q_P;
        end

        Q_P: begin                             // 音高比例
            wrt_en    <= 1'b1;
            wrt_v     <= vj;
            wrt_ratio <= ratio;
            st        <= Q_A0;
        end

        Q_A0: begin
            ma <= {8'd0, a_base};
            mb <= {7'd0, m_att};
            st <= Q_A1;
        end

        Q_A1: begin                            // A/D/R + 响度
            prm_wa <= vj;
            prm_wd <= {r_sh, d_sh, a_inc};
            prm_we <= 1'b1;
            lvl_wa <= vj;
            lvl_wd <= lvl_v;
            lvl_we <= 1'b1;
            st     <= Q_W0;
        end

        Q_W0: begin
            ma <= {2'd0, bw};
            mb <= {10'd0, g_sel};
            hr <= h;
            h  <= h + 4'd1;
            st <= Q_W1;
        end

        Q_W1: begin                            // 写第 hr 个泛音权重
            wgt_we <= 1'b1;
            wgt_wa <= {vj, hr};
            wgt_wd <= mprod[22:7];
            if(hr == 4'd15) st <= Q_NEXT;
            else            st <= Q_W0;
        end

        Q_NEXT: begin
            if(all_j && (vj != 5'd31)) begin
                vj <= vj + 5'd1;
                st <= Q_LOAD;
            end else begin
                st <= Q_IDLE;
            end
        end

        default: st <= Q_IDLE;
        endcase
    end
end

endmodule
