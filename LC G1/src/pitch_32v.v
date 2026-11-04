// ============================================================================
// pitch_32v.v - 32 声部基波相位步长（拨弦 32 固定音 / 拉弦 4 弦 x 8 段 + 滑音）
// ----------------------------------------------------------------------------
// 声部号 v = sub*8 + grp（sub = 一级 4051 片号 0..3，grp = 组号 0..7）。
//
// 拨弦(mode=0)：32 声部全开、音高固定，按 32 弦竖琴 C3~F7 的【连续白键】分布：
//   弦号 = 七声音阶序号（C3 起）：音级 = v mod 7，八度 = 3 + v / 7。
//   每 8 弦为一组（= 一块 4051 板），组间音高顺接、不重复：
//     v0..7   = C3 D3 E3 F3 G3 A3 B3 C4
//     v8..15  = D4 E4 F4 G4 A4 B4 C5 D5
//     v16..23 = E5 F5 G5 A5 B5 C6 D6 E6
//     v24..31 = F6 G6 A6 B6 C7 D7 E7 F7
//
// 拉弦(mode=1)：4 根标准小提琴空弦 x 每弦 8 段全音递进，铺满 v0..v31：
//     v = 弦号 s * 8 + 段号 k      （s = v[4:3]，k = v[2:0]）
//     freq(v) = 空弦[s] * 2^(2k/12)   // 每段一个全音
//     弦0..3 = G3(196.00) D4(293.66) A4(440.00) E5(659.26)
//   音名：s0 G3 A3 B3 C#4 D#4 F4 G4 A4 / s1 D4 E4 F#4 G#4 A#4 C5 D5 E5
//         s2 A4 B4 C#5 D#5 F5 G5 A5 B5 / s3 E5 F#5 G#5 A#5 C6 D6 E6 F#6
//
// 【滑音（拉弦演奏模式）】slide_act = mode & ~dbg_en（顶层给出）有效时，
//   ADC ch1 滑轨对全部 32 声部做全局滑音，每个声部只滑到"相邻下一段音"：
//     滑轨底端(code≈0) = 本键基准音，顶端(4095) = 上行一个全音（+2 半音），
//     1/8 半音步进。例：按住弦0 A3 键，滑轨从底到顶 = A3 连续滑到 B3；
//     改按 B3 键，则同一滑轨行程 = B3 -> C#4。
//   滑轨变化 -> 一次 32 声部扫描重算（约 100 拍 ≈ 0.9us），正在发声的音随之滑动。
//   退出滑音状态（进调试 / 切拨弦）时按比例 1.0 重扫一遍，保证基准恢复。
//
// 【调试比例】dbg_tune 写入 (v, ratio) 存进 rdbg[v]；inc_r[v] 始终按
//     inc = base[v] x rdbg[v] >> 16 再 x rsl[v] >> 16
//   两级 32x18 乘法流水（每声部 4 拍），两类写请求共用同一数据通路：
//   滑音全量扫描中途可被 dbg_tune 写请求挂起/恢复（单槽 pend 即可，
//   dbg_tune 相邻写口间隔 ≥ 19 拍，挂起响应 ≤ 4 拍）。
//
// 【同步复位】与 pitch_bank8 同理：本器件异步复位只能装载常量，装载非常量
//   （基频/比例）会被误判为组合环（AG0100/AG0101）。故本块全部同步复位。
// ============================================================================
module pitch_32v (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          mode,          // 0=拨弦, 1=拉弦
    // ---- 调试比例写口（由 dbg_tune 驱动，单拍脉冲）----
    input  wire          wrt_en,
    input  wire [4:0]    wrt_v,
    input  wire [17:0]   wrt_ratio,     // Q16 定点：65536 = 1.0
    // ---- 滑音输入（仅拉弦演奏模式；其余状态内部按底端=不滑处理）----
    input  wire          slide_act,     // = mode & ~dbg_en（已同步到本时钟域）
    input  wire [11:0]   slide_code,    // ADC ch1 快照（底端 0 = 基准音）
    // ---- 32 路步长 ----
    output wire [1023:0] inc_all        // inc_all[32*v +: 32]
);

    // ---------------- 拨弦固定音表（32 声部，C3~F7 连续白键，无重复音） ----------------
    // fs = 96kHz：inc = round(f × 2^32 / 96000)，由 48kHz 旧表逐项 (x+1)>>1 得到，
    // 换算频率与旧表偏差 <= 0.000011 Hz。
    localparam [1023:0] PLK_ALL =
        1024'h07734076070834ba0643cd1c0594d30d0544a17404b17e4b042e68ac03b9a03b03841a5d0321e68e02ca698702a250ba0258bf260217345601dcd01d01c20d2f0190f347016534c40151285d012c5f93010b9a2b00ee680f00e1069800c879a400b29a6200a8942f00962fca0085cd16007734080070834c00643cd200594d31;

    // ---------------- 拉弦 4 弦 x 8 段全音递进（G3 D4 A4 E5，fs = 96kHz） ----------------
    localparam [1023:0] BOW_ALL =
        1024'h03f254d903841a5d0321e68d02ca6987027c780c0237078401f92a6d01c20d2f02a250ba0258bf260217345701dcd01e01a8cac4017a725b0151285d012c5f9301c20d360190f34d016534c9013e3c0b011b83c600fc953b00e1069b00c879a7012c5f93010b9a2b00ee680f00d4656200bd392d00a8942f00962fca0085cd16;

    // ---------------- 滑音比例表（Q16，65536 = 1.0） ----------------
    // T17[i] = round(65536 * 2^(i/96))，i = 0..16（1/8 半音一格，共 +2 半音 = 一个全音）。
    //   滑轨码值 -> 档位：m = (code*16 + 2048) >> 12（四舍五入，底端 ~127 码内 m=0）。
    //   m=0 时比例 65536，输出与常量基准逐位一致；m=16 时 = 2^(2/12) ≈ 1.1225。
    localparam [305:0] T17 =
        306'h11F5A475211B3B464C5172C454A5132B444C10F39435150B56425A507804166D03B94076D0000;

    // ---------------- 每声部比例存储 ----------------
    reg  [17:0] rdbg [0:31];     // 调试比例（dbg_tune 写入）
    reg  [17:0] rsl  [0:31];     // 滑音比例（各声部相同；非滑音状态 = 65536）
    integer ri;
    initial begin
        for(ri=0; ri<32; ri=ri+1) begin
            rdbg[ri] = 18'd65536;
            rsl[ri]  = 18'd65536;
        end
    end

    // ---------------- 请求锁存 ----------------
    // dbg_tune 的写口是单拍脉冲，滑音扫描中途也可能到达 -> 单槽锁存，
    // 在扫描的声部边界挂起扫描、优先服务（间隔 ≥19 拍，响应 ≤4 拍，不会溢出）。
    reg        dbg_pend;
    reg  [4:0] dbg_pv;
    reg  [17:0] dbg_pr;

    reg  [11:0] code_l;          // 上次滑音扫描采用的码值
    reg         act_d;
    reg         slide_pend;

    wire [11:0] d_code = (slide_code > code_l) ? (slide_code - code_l)
                                               : (code_l - slide_code);

    // ---------------- 作业寄存器 ----------------
    reg  [3:0]  st;
    reg  [4:0]  vj;              // 当前作业声部
    reg         slide_job;       // 1 = 滑音全量扫描 / 0 = 单声部调试写
    reg         susp;            // 滑音扫描被 dbg 写挂起
    reg  [4:0]  vj_sav;          // 挂起时的下一声部
    reg  [4:0]  r_idx;           // T17 档位（0..16）
    reg  [17:0] rr;              // 本次扫描的滑音比例
    reg  [31:0] base_l;
    reg  [17:0] a_l, b_l;
    reg  [49:0] p1, p2;
    reg         mode_d;

    // 滑轨码值 -> T17 档位 m（0..16）：四舍五入，底端 ~127 码内归 0（= 不滑）
    wire [16:0] m_num = code_l * 13'd16 + 17'd2048;
    wire [4:0]  m_idx = m_num[16:12];

    // S_LD 组合前级：基准步长选择
    wire [31:0] base_sel = mode ? BOW_ALL[32*vj +: 32] : PLK_ALL[32*vj +: 32];
    wire [17:0] t18 = T17[18*r_idx +: 18];

    localparam S_IDLE = 4'd0, S_SA = 4'd1, S_SB = 4'd2,
               S_LD   = 4'd4, S_M1 = 4'd5, S_M2 = 4'd6, S_WR = 4'd7;

    reg  [31:0] inc_r [0:31];    // 重算后的步长（used=1 的声部生效）
    reg  [31:0] used;

    always @(posedge clk) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            dbg_pend   <= 1'b0;
            dbg_pv     <= 5'd0;
            dbg_pr     <= 18'd65536;
            code_l     <= 12'd0;
            act_d      <= 1'b0;
            slide_pend <= 1'b0;
            vj         <= 5'd0;
            slide_job  <= 1'b0;
            susp       <= 1'b0;
            vj_sav     <= 5'd0;
            r_idx      <= 5'd0;
            rr         <= 18'd65536;
            base_l     <= 32'd0;
            a_l        <= 18'd65536;
            b_l        <= 18'd65536;
            p1         <= 50'd0;
            p2         <= 50'd0;
            mode_d     <= 1'b0;
            used       <= 32'd0;
        end else begin
            mode_d <= mode;
            if (mode_d != mode) used <= 32'd0;   // 换模式：全部回落基准表

            // ---- 请求锁存（与状态机消费解耦）----
            act_d <= slide_act;
            if (wrt_en) begin
                dbg_pend <= 1'b1;
                dbg_pv   <= wrt_v;
                dbg_pr   <= wrt_ratio;
            end else if (st == S_IDLE && dbg_pend) begin
                dbg_pend <= 1'b0;                // IDLE 取走
            end else if (slide_job && (st == S_WR) && (vj != 5'd31) && dbg_pend) begin
                dbg_pend <= 1'b0;                // 扫描挂起时取走（vj==31 时留给 IDLE 取）
            end

            if (slide_act && !act_d) begin       // 进入滑音状态：按当前位置扫一遍
                slide_pend <= 1'b1;
                code_l     <= slide_code;
            end else if (!slide_act && act_d) begin  // 退出滑音状态：回底（不滑）扫一遍
                slide_pend <= 1'b1;
                code_l     <= 12'd0;
            end else if (slide_act && (d_code > 12'd16)) begin
                slide_pend <= 1'b1;              // 滑轨移动（滞回 16 码防抖）
                code_l     <= slide_code;
            end else if (st == S_SA) begin
                slide_pend <= 1'b0;              // 扫描启动
            end

            // ---- 主状态机 ----
            case (st)
            S_IDLE: begin
                if (dbg_pend) begin
                    rdbg[dbg_pv] <= dbg_pr;
                    vj        <= dbg_pv;
                    slide_job <= 1'b0;
                    base_l    <= mode ? BOW_ALL[32*dbg_pv +: 32] : PLK_ALL[32*dbg_pv +: 32];
                    a_l       <= dbg_pr;
                    b_l       <= rsl[dbg_pv];
                    st        <= S_M1;
                end else if (slide_pend) begin
                    slide_job <= 1'b1;
                    st        <= S_SA;           // 清 slide_pend 见上
                end
            end

            // 码值 -> 档位 -> 查表（分 2 拍，表查找独占一拍）
            S_SA: begin
                r_idx <= m_idx;
                st    <= S_SB;
            end
            S_SB: begin
                rr <= t18;                       // 17:1 常量选择，一拍内完成
                vj <= 5'd0;
                st <= S_LD;
            end

            // 每声部：装入基准/调试比例/滑音比例（各声部同一 rr，无需按段钳位）
            S_LD: begin
                base_l  <= base_sel;
                a_l     <= rdbg[vj];
                b_l     <= rr;
                rsl[vj] <= rr;
                st      <= S_M1;
            end

            S_M1: begin                          // base x rdbg
                p1 <= base_l * a_l;
                st <= S_M2;
            end
            S_M2: begin                          // (>>16 中间值) x rsl
                p2 <= p1[47:16] * b_l;
                st <= S_WR;
            end

            S_WR: begin
                inc_r[vj] <= p2[47:16];
                used[vj]  <= 1'b1;
                if (slide_job) begin
                    if (vj == 5'd31) begin
                        st <= S_IDLE;            // 扫描完成（残余 dbg_pend 下拍 IDLE 取走）
                    end else if (dbg_pend) begin
                        // 挂起扫描，先服务调试写
                        susp      <= 1'b1;
                        vj_sav    <= vj + 5'd1;
                        rdbg[dbg_pv] <= dbg_pr;
                        vj        <= dbg_pv;
                        slide_job <= 1'b0;
                        base_l    <= mode ? BOW_ALL[32*dbg_pv +: 32]
                                          : PLK_ALL[32*dbg_pv +: 32];
                        a_l       <= dbg_pr;
                        b_l       <= rsl[dbg_pv];
                        st        <= S_M1;
                    end else begin
                        vj <= vj + 5'd1;
                        st <= S_LD;
                    end
                end else begin
                    if (susp) begin              // 恢复被挂起的扫描
                        susp      <= 1'b0;
                        slide_job <= 1'b1;
                        vj        <= vj_sav;
                        st        <= S_LD;
                    end else begin
                        st <= S_IDLE;
                    end
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

    // ---------------- 输出：未被重算覆盖的声部直接用该模式的基准表 ----------------
    // 写成一层嵌套选择，综合可折叠进单个 LUT4（1 bit/1 LUT），比先做 base_all 再选省一半 LUT。
    genvar gv;
    generate
        for (gv = 0; gv < 32; gv = gv + 1) begin : g_inc
            assign inc_all[32*gv +: 32] = used[gv] ? inc_r[gv] :
                                          (mode ? BOW_ALL[32*gv +: 32] : PLK_ALL[32*gv +: 32]);
        end
    endgenerate

endmodule
