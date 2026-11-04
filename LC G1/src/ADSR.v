// ==============================================================
// ADSR.v : adsr_32ch - 32 路独立包络发生器（TDM 共享数据通路版），两种模式：
//   mode=0 拨弦(Pluck)：ADR = Attack -> Decay -> Release（省略 Sustain）
//            note_on(触发)起振
//            A: 288 点（3ms，竖琴典型：拨弦近乎瞬时起振）
//            D: 快衰 tau=2^17 拍（1.365s → -6.36dB/s），主包络衰到 -6dB(幅度减半)即转 Release
//               —— 竖琴"拨下去"那一下，先掉一截再拖长尾（双段衰减）
//            S: 省略（竖琴无持续平台）
//            R: 长尾 tau=2^18 拍（2.73s → -3.18dB/s），作为兜底包络
//            注：拨弦的"音高依赖衰减"（低音响久、高音短促）不在本模块做，而是由
//                additive_engine 的泛音包络按声部档位 voff 实现；本模块的拨弦 R
//                故意放得较慢，只作为兜底包络，避免给低音弦设过快的衰减下限
//   mode=1 拉弦(Bow)：ASR = Attack -> Sustain -> Release（省略 D）
//            note_on(按下)触发，Sustain 期间保持满幅，
//            检测到按键松开(key_level=0)进入 Release
//            起音 4096 点（42.7ms，弓毛渐咬弦的慢起振），
//            释放 tau=2^13 拍（85.3ms，弓离弦即止）——这两个时长是"像拉弦"
//            的关键：瞬起+长余韵会听成拨弦，慢起振+快收弓才是弓弦感
// 注：fs = 96kHz（sample_en 脉冲，音频域 120MHz/1250 拍 = 96kHz），所有采样点数已按此校准。
// 注：包络输出为串行写口 {env_waddr, env_wdata, env_we}（Q15，0..32767），
//     在扫描 SC_WR 拍把该声部包络写出，由 additive_engine 侧 32x16 RAM 按声部号读回
//     （同属 120MHz 域，无跨域）。
// 声部号 ch = sub*8 + grp（sub=一级片号 0..3，grp=组号 0..7），与扫描一致。
// --------------------------------------------------------------
// 【TDM 改造说明】原实现把 32 路状态机完整并行，综合出 5815 LUT + 2048 ALU
//   （占全工程逻辑约 59%，是 CLS 88% 的主要来源）。本版保持接口与行为不变，
//   把"每路一套状态机"改为"1 条共享数据通路串行扫 32 路"：
//     - 每路状态 {state,cnt,amp,rel_prod} 打包成 69bit 存在 ast[0:31]；
//       该阵列只做"同地址读/写"，交给综合器推断分布式 RAM（LUTRAM）省 LUT；
//       故不写复位循环（RAM 不能复位），改用上电后一次性 init 扫描把 32 项清零。
//     - 包络输出改为串行写口：扫描到 SC_WR 拍把本路包络连同声部号写出，
//       引擎侧 32x16 RAM 按声部号读回（避免 512bit 扁总线的长走线/高扇出）。
//     - 帧内时序：sample_en 后延迟 START_DLY 拍，再 3 拍/路
//       （RD 读状态 + CALC 寄存下一状态 + WR 写回），共约 8+96=104 拍
//       << 每帧 1250 拍（120MHz/96kHz）。
//     - note_on 是单拍脉冲，可能落在"本轮已扫过该路"之后；
//       故用 no_pend[31:0] 锁存任意 note_on，扫到该路时取用并清位（响应延迟 ≤1 帧≈10.4µs）。
// ==============================================================
module adsr_32ch#(
    parameter A_CNT     = 18'd288,     // 拨弦起音采样点数（fs=96kHz，288步=3ms，竖琴典型）
    parameter A_CNT_BOW = 18'd4096,    // 拉弦起音采样点数（fs=96kHz，4096步=42.7ms）
    parameter START_DLY = 4'd8         // 帧起始延迟（120MHz 拍），给接口/复位留余量
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,
    input  wire        mode,          // 0=拨弦ADR, 1=拉弦ASR
    input  wire [31:0] ch_note_on,    // 每通道触发单周期脉冲
    input  wire [31:0] ch_key_level,  // 按键电平 1=按下（拉弦模式 SUSTAIN 用）
    // ---- 调试参数写口（由 dbg_tune 驱动，单拍脉冲）----
    input  wire [4:0]  prm_wa,        // 声部号
    input  wire [19:0] prm_wd,        // {R_SH[4:0], D_SH[4:0], A_INC[9:0]}
    input  wire        prm_we,
    output wire [15:0] env_wdata,     // 声部包络串行写数据（Q15）：SC_WR 拍有效
    output wire [4:0]  env_waddr,     // 声部号（= 扫描 idx）
    output wire        env_we         // 写使能（SC_WR 拍）
);

localparam ST_IDLE      = 3'b000;
localparam ST_ATTACK    = 3'b001;
localparam ST_DECAY     = 3'b010; // 仅拨弦：D 段快衰，幅度减半(-6dB)后转 ST_RELEASE 长尾
localparam ST_SUSTAIN   = 3'b011; // 拉弦：保持满幅，等松开
localparam ST_RELEASE   = 3'b100; // 慢衰减到 0

localparam [31:0] REL_FULL = 32'h7FFF0000;       // 起始满幅 32767.0
localparam [15:0] GATE_AMP = 16'd400;            // 噪声门（≈-38dB：尾音在 D 类功放死区/低幅量化区之前截断，消除交越破音）
localparam [15:0] D_FAST_END = 16'd16384;        // 拨弦 D 段结束阈值（幅度减半 = -6dB），随后转入长尾 R

// 扫描状态机（5 拍/路）
//   RD  : 同步读出 ast[radr] 与 prm_mem[radr] -> w_ast / w_prm
//   C1  : 把"读状态 -> 算术"里最重的一步（可变右移量的 10:1 选择、18bit 加一 /
//         起音线性幅值）寄存到 c_* 一组寄存器，切断 LUTRAM 读输出直驱算术的长链
//   C1B : 用 C1 级寄存好的操作数做 32bit 减法（可变移位后的衰减量）
//   C2  : 用 c_* 做纯 mux / 小逻辑，算出 n_ast 并寄存进 p_ast
//   WR  : 用 p_ast 写回 ast[idx]，正常扫描时经串行写口输出包络
// 【120MHz 拆分依据】PnR 实测最差路径始终是 u_adsr/ast_ast_0_0_s/DO -> p_ast
//   （data 8.29ns vs 限 8.333ns，slack 仅 +0.001ns）：综合器把 w_ast 这一级寄存器
//   并进了 LUTRAM 读出，使"RAM 读 + 比较/移位/减法"挤在同一拍。本版在二者之间再插
//   一级 c_* 寄存器，并把可变移位后的 32bit 减法独立成 C1B 级（5 拍/路）；
//   每帧约 8+32*5=168 拍 << 1250 拍。
localparam SC_IDLE = 3'd0, SC_RD = 3'd1, SC_C1 = 3'd2, SC_C1B = 3'd5,
           SC_C2 = 3'd3, SC_WR = 3'd4;

// ast 打包：{state[2:0], cnt[17:0], amp[15:0], rel_prod[31:0]} = 69bit
reg  [68:0] ast [0:31];                          // 每路状态，同地址读写 -> 推断 LUTRAM

// ---------------- 每声部 A/D/R 参数表（调试可写，20bit） ----------------
// {R_SH[4:0], D_SH[4:0], A_INC[9:0]}：
//   A_INC 起音每帧线性增量（拨弦基准 227 = 144 步/3ms，拉弦基准 16 = 2048 步/42.7ms）
//   D_SH  拨弦 D 段快衰右移量（基准 16；拉弦无 D 段，天然无效）
//   R_SH  释放段右移量（拨弦基准 17 = 2.73s，拉弦基准 12 = 85.3ms）
// 上电按拨弦基准填充；模式切换/调试改动后由 dbg_tune 重写对应的声部。
reg  [19:0] prm_mem [0:31];
reg  [19:0] w_prm;
integer pri;
initial begin
    for(pri=0;pri<32;pri=pri+1) prm_mem[pri] = {5'd18, 5'd17, 10'd114};
end
always @(posedge clk) begin
    if(prm_we) prm_mem[prm_wa] <= prm_wd;
end

// 【包络输出改为串行写口】原先把 32 路包络拼成 512bit 的 env_all 扁总线送引擎，
//   引擎要用 8:1 mux（4 组）去选，PnR 实测该变址读是音频域时序最差点（+0.003ns）。
//   现改为：扫描到 SC_WR 拍时把本路包络按 {addr,data,we} 写出去，引擎侧用
//   32x16 的 RAM（与 vw_arr 同款分布式 RAM）按声部号读，彻底消除扁总线的长走线。
assign env_waddr = idx;
assign env_we    = (st == SC_WR);
assign env_wdata = inited ? p_ast[47:32] : 16'd0;   // 上电 init 扫描写 0

reg  [2:0]  st;
reg  [4:0]  idx;
reg  [4:0]  radr;                                // ast 读地址（C1/C2 时 = idx+1，故意错开）
reg  [3:0]  dly;
reg         inited;
reg  [31:0] no_pend;                             // 待处理 note_on 锁存
reg  [68:0] w_ast;                               // 当前路状态（寄存读出）
reg  [68:0] p_ast;                               // C2 级：寄存的下一状态（含 n_amp 于 [47:32]）

// 读出的字段
wire [2:0]  s_state = w_ast[68:66];
wire [17:0] s_cnt   = w_ast[65:48];
wire [15:0] s_amp   = w_ast[47:32];
wire [31:0] s_prod  = w_ast[31:0];

// mode / key_level 在帧起始（sample_en 拍）锁存，与原并行版"在 sample_en 沿采样"一致；
// 否则 TDM 扫描在帧内较晚才读到 mode，会与 mode 切换沿错开一帧（RELEASE 中 amp 滞后
// prod 一拍，会把该错位放大成可见的常量偏移）。
reg         mode_l;
reg  [31:0] key_l;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)              begin mode_l <= 1'b0;  key_l <= 32'd0; end
    else if(sample_en)      begin mode_l <= mode;  key_l <= ch_key_level; end
end

// 起音线性幅值（增量累加，只占一级 17bit 加法器）：
//   每声部增量 A_INC 来自 prm_mem：拨弦基准 114（288 步到满幅 = 3ms 竖琴典型起振），
//   拉弦基准 8（4096 步 = 42.7ms）。调参范围见 dbg_tune。
//   起音结束判据 = 幅值到满幅（att_inc 饱和到 32767），与增量大小无关。
wire [9:0]  a_inc_s = w_prm[9:0];
wire [4:0]  d_sh_s  = w_prm[14:10];
wire [4:0]  r_sh_s  = w_prm[19:15];
wire [16:0] amp_p   = {1'b0, s_amp} + {7'b0, a_inc_s};
wire [15:0] att_inc = (amp_p >= 17'd32768) ? 16'd32767 : amp_p[15:0];

// 衰减右移量：D 段用 D_SH，其余（RELEASE）用 R_SH。10..20 共 11 档常量移位并联，
//   再做 11:1 选择（避免可变移位量推断出桶形移位器，把长链压在一拍里）。
wire [4:0]  sh_sel  = (s_state == ST_DECAY) ? d_sh_s : r_sh_s;
wire [31:0] p10 = s_prod >> 10;
wire [31:0] p11 = s_prod >> 11;
wire [31:0] p12 = s_prod >> 12;
wire [31:0] p13 = s_prod >> 13;
wire [31:0] p14 = s_prod >> 14;
wire [31:0] p15 = s_prod >> 15;
wire [31:0] p16 = s_prod >> 16;
wire [31:0] p17 = s_prod >> 17;
wire [31:0] p18 = s_prod >> 18;
wire [31:0] p19 = s_prod >> 19;
wire [31:0] p20 = s_prod >> 20;
wire [31:0] prod_shr = (sh_sel == 5'd10) ? p10 : (sh_sel == 5'd11) ? p11 :
                       (sh_sel == 5'd12) ? p12 : (sh_sel == 5'd13) ? p13 :
                       (sh_sel == 5'd14) ? p14 : (sh_sel == 5'd15) ? p15 :
                       (sh_sel == 5'd16) ? p16 : (sh_sel == 5'd17) ? p17 :
                       (sh_sel == 5'd18) ? p18 : (sh_sel == 5'd19) ? p19 : p20;

wire        pend  = no_pend[idx];
wire        keylv = key_l[idx];

// 扫描本拍是否在"消费"（清）idx 路的 note_on 标志
//   注：上电 init 扫描（!inited）不消费——否则复位后极早到达的 note_on 会被
//       写 0 覆盖而丢失；留给首次正常扫描处理。
wire [31:0] consume = (st == SC_WR && inited) ? (32'd1 << idx) : 32'd0;

// ---------------- C1 级：寄存"读状态 -> 算术"里最重的一步 ----------------
//   全部由 w_ast（已寄存的 RAM 读出）组合算出并寄存，下一拍 C2 只做 mux。
//   目的：让 LUTRAM 读输出不再直驱 32bit 减法 / 18bit 比较 / 18bit 加到 p_ast。
reg  [31:0] c_prod_raw;     // = s_prod
reg  [31:0] c_prod_shr;     // = s_prod >> sh_sel（10 档常量移位 + 10:1 选择）
reg  [31:0] c_sub;          // = c_prod_raw - c_prod_shr（C1B 级 32bit 减法）
reg  [17:0] c_cnt_raw;      // = s_cnt
reg  [17:0] c_cnt_p1;       // = s_cnt + 1
reg  [15:0] c_amp_raw;      // = s_amp
reg  [15:0] c_amp_hi;       // = s_prod[31:16]
reg  [15:0] c_att_amp;      // 起音线性幅值
reg  [2:0]  c_state;
reg         c_pend, c_keylv;
reg         c_att_full;     // 起音幅值已到满幅（起音结束判据）
reg         c_amp_le_gate;  // s_amp <= GATE_AMP
reg         c_amp_le_half;  // s_amp <= D_FAST_END（拨弦 D 段结束判据）

always @(posedge clk) begin
    c_prod_raw    <= s_prod;
    c_prod_shr    <= prod_shr;
    c_cnt_raw     <= s_cnt;
    c_cnt_p1      <= s_cnt + 18'd1;
    c_amp_raw     <= s_amp;
    c_amp_hi      <= s_prod[31:16];
    c_att_amp     <= att_inc;                    // 每声部 A_INC 增量累加（带饱和）
    c_att_full    <= (att_inc == 16'd32767);
    c_state       <= s_state;
    c_pend        <= pend;
    c_keylv       <= keylv;
    c_amp_le_gate <= (s_amp <= GATE_AMP);
    c_amp_le_half <= (s_amp <= D_FAST_END);
end

// ---------------- C1B 级：32bit 减法（操作数均已在 C1 级寄存） ----------------
//   原来"移位 + 减法"要在 C1 一拍内完成；可变移位量（10..19）使移位选择变宽，
//   这里把减法单独拆一拍，保证每段路径都远小于 8.333ns。
always @(posedge clk) begin
    c_sub <= c_prod_raw - c_prod_shr;
end

// ---------------- C2 级：纯 mux / 小逻辑 -> n_ast ----------------
reg  [2:0]  n_state;
reg  [17:0] n_cnt;
reg  [15:0] n_amp;
reg  [31:0] n_prod;

always @(*) begin
    n_state = c_state; n_cnt = c_cnt_raw; n_amp = c_amp_raw; n_prod = c_prod_raw;
    if (c_pend) begin
        // note_on 优先级最高：立即重装为起音
        n_state = ST_ATTACK; n_cnt = 18'd0; n_amp = 16'd0; n_prod = REL_FULL;
    end else begin
        case (c_state)
        ST_IDLE: begin
            n_amp = 16'd0;
        end

        ST_ATTACK: begin
            if (c_att_full) begin
                n_amp   = 16'd32767;
                n_cnt   = 18'd0;
                n_prod  = REL_FULL;
                n_state = mode_l ? ST_SUSTAIN : ST_DECAY;
            end else begin
                // 线性起音（增量累加）：每声部 A_INC 来自调试参数表
                n_amp = c_att_amp;
                n_cnt = c_cnt_p1;
            end
        end

        ST_DECAY: begin // 仅拨弦：D 段快衰（基准 tau=2^17=1.365s → -6.36dB/s），幅度减半后转长尾 R
            n_prod = c_sub;
            n_amp  = c_amp_hi;
            n_cnt  = c_cnt_p1;
            if (c_amp_le_half) n_state = ST_RELEASE;
        end

        ST_SUSTAIN: begin // 仅拉弦模式：保持满幅，等松开
            n_amp = 16'd32767;
            if (c_keylv == 1'b0) begin
                n_prod  = REL_FULL;
                n_state = ST_RELEASE;
            end
        end

        ST_RELEASE: begin
            if (c_amp_le_gate) begin
                n_amp   = 16'd0;
                n_state = ST_IDLE;
                n_cnt   = 18'd0;
            end else begin
                // 释放时间常数：拉弦 tau=2^13 拍（85.3ms）；拨弦 tau=2^18 拍（2.73s，长尾 R）
                //   拨弦的 D 段快衰已在 ST_DECAY 做掉，这里只负责后面的长尾。
                //   主包络长尾放得较慢，是因为"低音响久、高音短促"的音高依赖衰减
                //   改由 additive_engine 的泛音包络（SH 按声部档位 voff）来实现 ——
                //   若主包络设得过快，它会给所有声部设一个衰减下限，
                //   低音弦就无法响得比它更久（参考竖琴 C3 ≈ -12dB/s）。
                n_prod = c_sub;
                n_amp  = c_amp_hi;
            end
        end

        default: begin
            n_amp   = 16'd0;
            n_state = ST_IDLE;
        end
        endcase
    end
end

wire [68:0] n_ast = {n_state, n_cnt, n_amp, n_prod};

// ---------------- 扫描状态机 ----------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st       <= SC_IDLE;
        idx      <= 5'd0;
        radr     <= 5'd0;
        dly      <= 4'd0;
        inited   <= 1'b0;
        no_pend  <= 32'd0;
        w_ast    <= 69'd0;
        w_prm    <= {5'd18, 5'd17, 10'd114};
        p_ast    <= 69'd0;
    end
    else begin
        // note_on 单拍脉冲随时锁存；扫到该路（SC_WR）时清掉那一位
        no_pend <= (no_pend & ~consume) | ch_note_on;

        case (st)
        SC_IDLE: begin
            if (sample_en || !inited) begin
                idx  <= 5'd0;
                radr <= 5'd0;
                dly  <= START_DLY;
                st   <= SC_RD;
            end
        end

        SC_RD: begin
            if (dly != 4'd0) begin
                dly <= dly - 4'd1;
            end else begin
                // 用 radr 读出当前路状态；同时把读地址预置到 idx+1，
                // 使后续 C1/C2 期间 ast 的数据输出 ≠ w_ast（LUTRAM 读地址是组合的）。
                w_ast <= ast[radr];
                w_prm <= prm_mem[radr];        // A/D/R 参数与状态同址同拍读出
                radr  <= idx + 5'd1;
                st    <= SC_C1;
            end
        end

        SC_C1: begin
            // c_* 在上述 always @(posedge clk) 里本拍末寄存（可变移位的 10:1 选择、
            // 18bit 加一、起音幅值等），这里只推进状态。
            st <= SC_C1B;
        end

        SC_C1B: begin
            // c_sub 在独立 always 块里本拍末寄存（32bit 减法）
            st <= SC_C2;
        end

        SC_C2: begin
            // 用 c_* 做纯 mux，算出 n_ast 并寄存进 p_ast。
            p_ast <= n_ast;
            st    <= SC_WR;
        end

        SC_WR: begin
            if (!inited) begin
                // 上电首次扫描：把 RAM 初始化为全 0（RAM 无法复位，只能靠写一遍）
                ast[idx] <= 69'd0;
            end else begin
                ast[idx] <= p_ast;
            end
            if (idx == 5'd31) begin
                st     <= SC_IDLE;
                inited <= 1'b1;
            end else begin
                idx <= idx + 5'd1;
                st  <= SC_RD;
            end
        end

        default: st <= SC_IDLE;
        endcase
    end
end

endmodule