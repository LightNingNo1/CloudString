// ============================================================================
// additive_engine.v - 32 声部 x 16 泛音 加法合成引擎（TDM，120MHz 域）
// ----------------------------------------------------------------------------
// 每帧（sample_en，96kHz = 120MHz/1250）流程：
//   S_IDLE  : 等 sample_en，清空声部累加器/总累加器
//   S_SCAN  : 520 拍扫过 512 个条目（条目 = {声部[4:0], 泛音[3:0]}，条目号 rc = v*16 + h）
//             每个条目就是一个独立振荡器（独立 32bit 相位 + 独立步长 n×inc[v]），
//             每个条目做四件事：
//               (1) 相位就地更新：phase[条目] += 本条目步长（读口提前 1 拍预取，写口同拍写回）
//               (2) 从 512x32 的泛音包络 BSRAM 读出旧包络 henv，算新包络写回
//                   （拉弦恒满幅 / 拨弦触发重装 / 否则按 SH 指数泄漏衰减）
//               (3) 用更新后相位的 mod 2^32 高 12bit 查 4096x16 正弦表
//               (4) sine x 泛音包络 送 DSP-A，乘积 >>15 累加进本声部的声部累加器
//   S_VOICE : 32 声部依次 声部波形 x 主 ADSR 包络 送 DSP-B，乘积累加得 sum
//   S_V1/S_V2/S_OUT : sum x master_vol 拆 2 次 18x18 乘法（与 audio_mixer 逐位一致），
//                     24bit 硬限幅输出
//
// 流水对齐（sc 为 S_SCAN 内的周期号，"周期 sc" 指该周期内驱动的组合值被 sc 结尾的
// 上升沿采样）：
//   正弦地址 AD(sc) = addr(条目 sc)                     (sc = 0..511)
//   正弦数据 dout(sc) = sine[条目 sc-2]                 (sc = 2..513)
//   泛音包络读 henv_q(sc) = henv[条目 sc-1]              (sc = 1..512)
//   再过一拍 hd2(sc) = henv[条目 sc-2]  -> 与 dout 同条目
//   DSP-A 输入 a=dout,b=hd2 于 sc = 2..513，p/ack 于 sc = 5..516（3 拍延迟）
//   累加落在 sc = 5..516，对应条目 rc = sc-5
//   包络写回落在 sc = 2..513，对应条目 rc = sc-2；读地址恒比写地址晚 2 拍，无冲突
//   （sc 在 512..516 时 sc[8:0] 回绕，正好等价于 rc = sc-5 的模 512 结果）
//
// 定点：
//   泛音权重 W[n] 拨弦/拉弦分表（见下方 W_TBL_PLK / W_TBL_BOW），ΣW ≈ 32000（未饱和）
//     拨弦=竖琴谱、拉弦=小提琴谱，均由参考乐器采样实测谐波谱反解标定
//   包络满幅存 W[n]<<16（32bit BSRAM），取出 henv[31:16] = W[n] 送 DSP
//   单条泛音项 term = (sine x W[n]) >> 15；各项之和峰值约 1.6e4（ΣW = 32768，未饱和）
//   声部波形 = 该和（16bit 有符号，带饱和）；主 ADSR 包络为 Q15
//   每声部 = (声部波形 x 主包络 x 响度Q7/128) >> SHV；32 声部求和后套 audio_mixer 的总音量数学
//
// 【调试模式】泛音权重 wgt_mem[512] 与响度 lvl_mem[32] 均可由 dbg_tune 写入；
//   上电/未调试时 wgt_mem = 拨弦基准表、lvl_mem = 128，与改动前逐位一致。
// ============================================================================
module additive_engine #(
    parameter [4:0] SHV = 5'd9        // 声部波形 x 主包络 后的右移位数（整机增益；默认与顶层一致，
                                     // 保证 3 键同时发声不削顶：单声部约 2.0M，3 键≈6.1M < 8.39M）
)(
    input  wire               clk,          // 120MHz 音频时钟
    input  wire               rst_n,
    input  wire               sample_en,    // 帧起始单拍脉冲（96kHz）
    input  wire               mode,         // 0=拨弦(竖琴), 1=拉弦(小提琴)
    input  wire [1023:0]      inc_all,      // 32 声部基波相位步长，inc_all[32*v +: 32]
    input  wire [31:0]        note_on,      // 32 声部触发脉冲（单拍）
    input  wire [15:0]        env_wdata,    // 主 ADSR 包络串行写数据（Q15）
    input  wire [4:0]         env_waddr,    // 写入声部号
    input  wire               env_we,       // 写使能
    // ---- 调试参数写口（由 dbg_tune 驱动，均单拍脉冲）----
    input  wire [8:0]         wgt_wa,       // 每声部泛音权重表写地址 {v[4:0], h[3:0]}
    input  wire [15:0]        wgt_wd,       // 权重（Q15 口径，同原 W_TBL）
    input  wire               wgt_we,
    input  wire [4:0]         lvl_wa,       // 每声部响度写地址（声部号）
    input  wire [7:0]         lvl_wd,       // 响度增益 Q7：128 = 1.0
    input  wire               lvl_we,
    input  wire [15:0]        master_vol,   // 总音量 Q15
    output reg  signed [23:0] mix           // 24bit 混音输出
);

    // ---------------- 泛音权重表 W[1..16]（Q15）—— 拨弦/拉弦分表 ----------------
    // 标定来源：virtualinstruments.net 虚拟乐器采样（竖琴 C5 / 小提琴 A4）的实测谐波谱，
    //   在 PC 上用 timbre_model.py（本 RTL 的逐帧数学复刻）反解 W 并比对至 ±2dB。
    //
    // 【拨弦 = 竖琴】W = 15239,3412,6425,2869,4053,0...（ΣW=31998，不饱和）
    //   winB(t≈0.275s) 实测谐波(dB)：H1 0 / H2 -13.0 / H3 -10.9 / H4 -24.7 / H5 -21.7
    //   参考竖琴采样：                H1 0 / H2 -14.2 / H3 -11.4 / H4 -27.0 / H5 -20.9
    //   起音实测(0-.15s)：            H2 -13.0 / H3 -8.4 / H4 -17.3 / H5 -14.3
    //   参考起音(0-.15s)：            H2 -22.1 / H3 -18.1 / H4 -25.6 / H5 -14.1
    //   6 次以上置 0：高次衰减极快，若用大 W 补偿会让起音出现压过基音的突出分音
    //   （"铃铛/空洞"感），而它们在 winB 时已弱到 -40dB 以下、本就听不见。
    localparam [255:0] W_TBL_PLK =
        256'h000000000000000000000000000000000000000000000FD50B3519190D543B87;
    // 【拉弦 = 小提琴】W = 6758,9545,3387,1905,3018,1513,1348,1202,758,851,676,...（ΣW=32001）
    //   稳态谱(dB)：H1 0 / H2 +3 / H3 -6 / H4 -11 / H5 -7 / H6 -13 / H8 -15 / H12 -24
    //   参考小提琴采样：H1 0 / H2 +3 / H3 -9 / H4 -14 / H5 -9 / H6 -18 / H8 -13 / H12 -32
    //   2 次略高于基音、奇偶混合、谐波延伸到 16 次 -> 弓弦的持续富谐波音色。
    //   注：拉弦模式恒重装满幅(见 pl_b)，故稳态谱 = 本表本身；SH_TBL 对拉弦无影响。
    localparam [255:0] W_TBL_BOW =
        256'h0044006B00AA010D01AA02A4035302F604B2054405E90BCA07710D3B25491A66;
    // 【调试模式】权重不再在本模块按 mode 选表：wgt_mem 上电用拨弦表填充，
    //   拉弦时由 dbg_tune 在模式切换后重写全部 32 声部 x 16 泛音（基准 = 上面的 BOW 表）。
    //   本模块只用 W_TBL_PLK 做 initial 填充，W_TBL_BOW 仅作基准值文档保留。
    // ---------------- 泛音衰减右移位数 SH[1..16]（τ = 2^SH / 96kHz） ----------------
    // 【拨弦·竖琴演化：亮起音 + 暖余韵】基音慢衰 + 高次逐级快衰：
    //   17/16/16/15/15/14/13... -> τ1=1.37s，τ2=τ3=0.68s，τ4=τ5=0.34s，τ6=0.17s
    //   本表按参考竖琴 C5 实测的各次谐波衰减速率(dB/s)反推（再叠加八度档 voff，见下方）：
    //     参考 Hn 衰减(dB/s) H1~H6 ≈ [21, 27, 46, 71, 72, ...] -> sh_eff=[17,16,16,15,15,14]
    //   （H2 由 17 收紧到 16：参考竖琴 2 次谐波随时间是"变暗"的，原表 H2 与基音同衰太亮）
    //   注：SH 必须落在 11..17 —— 引擎用 s11..s17 的 7:1 常量移位选择，越界会选错移位。
    //   注：本表是"基准值"（voff=0 低音档），实际右移量还要减去按声部音高的档位 voff
    //       （见下方 sh_c 处）：竖琴低音弦响得久、高音弦衰减快（参考 C3≈-12、C5≈-16 dB/s）。
    localparam [79:0]  SH_TBL =
        80'h6318C6318D6B5CF7C211;

    // ---------------- 每声部泛音权重 / 响度表（调试可写） ----------------
    // wgt_mem：512 x 16bit，地址 = {声部[4:0], 泛音[3:0]}，异步读（与 S_SCAN 同拍查表，
    //   时序与原来的常量 16:1 mux 一致）；上电按拨弦基准表填充。
    // lvl_mem：32 x 8bit 响度增益 Q7（128 = 1.0，即逐位等价于改动前）。
    reg [15:0] wgt_mem [0:511];
    reg [7:0]  lvl_mem [0:31];

    integer wgi;
    initial begin
        for(wgi=0; wgi<32; wgi=wgi+1) begin
            wgt_mem[wgi*16+ 0] = 16'h3B87;   // H1  15239
            wgt_mem[wgi*16+ 1] = 16'h0D54;   // H2   3412
            wgt_mem[wgi*16+ 2] = 16'h1919;   // H3   6425
            wgt_mem[wgi*16+ 3] = 16'h0B35;   // H4   2869
            wgt_mem[wgi*16+ 4] = 16'h0FD5;   // H5   4053
            wgt_mem[wgi*16+ 5] = 16'h0000;
            wgt_mem[wgi*16+ 6] = 16'h0000;
            wgt_mem[wgi*16+ 7] = 16'h0000;
            wgt_mem[wgi*16+ 8] = 16'h0000;
            wgt_mem[wgi*16+ 9] = 16'h0000;
            wgt_mem[wgi*16+10] = 16'h0000;
            wgt_mem[wgi*16+11] = 16'h0000;
            wgt_mem[wgi*16+12] = 16'h0000;
            wgt_mem[wgi*16+13] = 16'h0000;
            wgt_mem[wgi*16+14] = 16'h0000;
            wgt_mem[wgi*16+15] = 16'h0000;
            lvl_mem[wgi] = 8'd128;
        end
    end

    always @(posedge clk) begin
        if(wgt_we) wgt_mem[wgt_wa] <= wgt_wd;
        if(lvl_we) lvl_mem[lvl_wa] <= lvl_wd;
    end

    // ---------------- 512 路独立相位累加器（每个分音一个，扫描内就地更新，TDM） ----------------
    // 【独立振荡器】条目号 e = {声部 v[4:0], 泛音 h[3:0]} 对应一个独立振荡器：每个条目
    //   持有自己的 32bit 相位，每帧各自累加自己的步长 inc_n = n × inc[v]（n = h+1 = 1..16）。
    //   旧实现是 φ_n = n × φ_v（相位锁定谐波）；整数倍步长下二者数值逐位等价
    //   （n×(Σinc) ≡ Σ(n·inc) mod 2^32），但物理上是 512 个独立振荡器，每个都有独立
    //   相位寄存器与独立步长，可各自失谐（只需把步长写成非整数倍）。
    //
    //   存储：512×32bit 相位 RAM（BSRAM SDP，1 读 1 写）。读地址组合给出"条目号+1"
    //     （pra = sc+1，靠 BSRAM 自带输出寄存器 1 拍），使 ph_rd 在"条目 sc"的节拍上
    //     恰好等于 phase[sc]；写口同拍写回 psum = phase[sc] + inc_n。
    //   步长：同一声部 16 个泛音的步长是等差 inc,2inc,…,16inc，用 1 个 32bit 加法器在块内
    //     累加（nsum）即可，块首（h==0）重装为 inc，无需逐条做乘法（省掉 512 次乘法）。
    //   步长 32 选 1 仍是三级流水（4:1 -> 4:1 -> 2:1）。三级分别按索引的 [5:4]、[8:7]、[6]
    //     选（即声部号的低/高/中位），配合取号偏移 mi0 = sc+5，使 inc_r 在"条目 sc"拍
    //     恰好给出 nsum 需要的基波步长：块内 h=0..14 为本声部 inc[v]，块尾 h=15 给的是
    //     下一声部 inc[v+1]（h_next==0 重装时正好用它），故 16 个泛音步长天然成等差。
    reg  [31:0] phase_mem [0:511];
    reg  [31:0] ph_rd;          // 相位 RAM 读数据
    wire [8:0]  pra;            // 相位 RAM 读地址（组合 = 条目号+1，靠 RAM 自带读寄存器对齐）
    reg  [31:0] nsum;           // 当前条目步长 = n × inc[v]
    reg  [8:0]  mi0, mi1, mi2;  // 步长 mux 三级流水索引
    reg  [255:0] inc_part_a;    // 步长 32 选 1 第 1 级（4 选 1）→ 8 个候选
    reg  [63:0]  inc_part_b;    // 第 2 级（4 选 1）  → 2 个候选
    reg  [31:0]  inc_r;         // 第 3 级（2 选 1）= 条目所属声部的基波步长
    wire [31:0] psum = ph_rd + nsum;   // 该条目更新后的相位（mod 2^32）

    // 步长 32 选 1 若一级做完，实测是一条 9.8ns 的长路径（6 级 LUT）。
    // 这里拆成三级流水，每级最多 1 个 LUT4 级：
    //   第 1 级的 4 个候选只是 inc_all 的"纯重排线"（无逻辑）：
    //     inc_wS[32*g +: 32] = inc_all[32*(4g+S) +: 32]      (g = 0..7, S = 0..3)
    //   第 2 级按索引[4:3] 在 inc_part_a 里 4 选 1，第 3 级按索引[2] 2 选 1。
    //   合起来 inc_r = inc_all[32*索引 +: 32]。
    wire [255:0] inc_w0 = {inc_all[32*28+:32],inc_all[32*24+:32],inc_all[32*20+:32],inc_all[32*16+:32],
                           inc_all[32*12+:32],inc_all[32*8 +:32],inc_all[32*4 +:32],inc_all[32*0 +:32]};
    wire [255:0] inc_w1 = {inc_all[32*29+:32],inc_all[32*25+:32],inc_all[32*21+:32],inc_all[32*17+:32],
                           inc_all[32*13+:32],inc_all[32*9 +:32],inc_all[32*5 +:32],inc_all[32*1 +:32]};
    wire [255:0] inc_w2 = {inc_all[32*30+:32],inc_all[32*26+:32],inc_all[32*22+:32],inc_all[32*18+:32],
                           inc_all[32*14+:32],inc_all[32*10+:32],inc_all[32*6 +:32],inc_all[32*2 +:32]};
    wire [255:0] inc_w3 = {inc_all[32*31+:32],inc_all[32*27+:32],inc_all[32*23+:32],inc_all[32*19+:32],
                           inc_all[32*15+:32],inc_all[32*11+:32],inc_all[32*7 +:32],inc_all[32*3 +:32]};
    integer pmi;
    initial begin
        for(pmi=0;pmi<512;pmi=pmi+1) phase_mem[pmi] = 32'd0;
    end

    // ---------------- 状态机 / 计数器 ----------------
    // 【时序优化】S_OUT 原来把"46bit 加法 -> 46bit 减法 -> 30bit 限幅"串在一拍里，
    //   120MHz 实测只能到 102MHz。这里拆成 S_O1(算 q_val) / S_O2(算 prod_v) /
    //   S_OUT(限幅) 三级流水，每级深度都远小于 8.33ns。
    // 【时序优化】原二进制 4bit 编码下，状态位之间互相依赖深、扇出大，
    //   120MHz 实测最差路径全部来自 st（st_*->st_*，含 CE），故改用手工 one-hot 12bit：
    //   每个状态 = 独立一位，case/比较退化为单位测试，下一状态方程显著变浅。
    //   代价仅 +8 个寄存器（资源充足，优先保时序余量）。
    localparam [11:0] S_IDLE = 12'h001, S_SCAN = 12'h008, S_VOICE= 12'h010,
                      S_V1   = 12'h020, S_V1W  = 12'h040, S_V2  = 12'h080,
                      S_V2W  = 12'h100, S_O1   = 12'h200, S_O2  = 12'h400,
                      S_OUT  = 12'h800;

    localparam [9:0] SCAN_END  = 10'd519;
    localparam [5:0] VOICE_END = 6'd36;      // 32 次请求 + 请求/应答 3 拍错位 + vw_s 流水 1 拍

    reg [11:0] st;
    reg [9:0] sc;
    reg [5:0] p2;

    // ---------------- 扫描相位 ----------------
    // 每个条目（= 一个独立振荡器）在扫描当拍完成"读相位 -> 加步长 -> 写回 -> 查正弦表"。
    //   读口地址 pra = sc+1（提前 1 拍），配合同步读 1 拍延迟，使 ph_rd 在"条目 sc"的
    //   节拍上恰好等于 phase[sc]；写口同拍把 psum = phase[sc] + inc_n 写回同一地址。
    //   帧起始（S_IDLE 拍）把 pra 清 0，保证 S_SCAN 首拍（sc=0）即得到 phase[0]。
    wire        scan_on  = (st == S_SCAN);
    wire [8:0]  ent_now  = sc[8:0];

    wire        rd_ok    = scan_on && (sc <= 10'd511);     // 相位读/写有效
    wire        reqA     = scan_on && (sc >= 10'd2) && (sc <= 10'd513);  // DSP-A 请求
    wire [11:0] sine_ad  = rd_ok ? psum[31:20] : 12'd0;    // 独立相位直接查表

    // 相位 RAM：组合给出"条目号+1"的读地址（RAM 自带输出寄存器 1 拍），使 ph_rd 在
    //   "条目 sc" 拍恰好等于 phase[sc]；写口同拍写回 psum = phase[sc] + inc_n。
    //   注：读地址是组合的（不做额外打拍），否则两级寄存器会把读数据再推后一拍，
    //   导致 sc=1 时 ph_rd 仍停留在 phase[0]（首块 h=1 的相位会少累加一次）。
    assign pra = scan_on ? (ent_now + 9'd1) : 9'd0;
    always @(posedge clk) begin
        if(rd_ok) phase_mem[ent_now] <= psum;
        ph_rd <= phase_mem[pra];
    end

    // 步长 32 选 1 三级流水：索引 mi0 = 条目号+4（流水 3 级 + 1 级预取对齐），
    //   inc_r 在"条目 sc"拍 = inc_all[v(sc+1)]（声部号取条目号的 [8:4]）
    always @(posedge clk) begin
        if(st == S_IDLE) begin
            mi0 <= 9'd0;  mi1 <= 9'd0;  mi2 <= 9'd0;    // 首块（声部 0）
            inc_part_a <= inc_w0;                       // 条目 0（声部 0，声部号低 2 位 = 0）
            inc_part_b <= {inc_all[32 +: 32], inc_all[31:0]};
            inc_r      <= inc_all[31:0];
        end else begin
            mi0 <= sc[8:0] + 9'd5;
            mi1 <= mi0;
            mi2 <= mi1;
            inc_part_a <= (mi0[5:4] == 2'd0) ? inc_w0 : (mi0[5:4] == 2'd1) ? inc_w1 :
                          (mi0[5:4] == 2'd2) ? inc_w2 : inc_w3;
            inc_part_b <= {inc_part_a[64*mi1[8:7] + 32 +: 32], inc_part_a[64*mi1[8:7] +: 32]};
            inc_r      <= inc_part_b[32*mi2[6] +: 32];
        end
    end

    // 块内步长累加：h==0 重装为 inc，否则累加 inc；nsum 恰为 n × inc[v]
    wire [3:0]  h_next   = sc[3:0] + 4'd1;                 // 下一条目泛音号（511+1 回绕到 0）
    wire [31:0] nsum_nxt = (h_next == 4'd0) ? inc_r : (nsum + inc_r);
    always @(posedge clk) begin
        if(st == S_IDLE)        nsum <= inc_all[31:0];      // 条目 0 = 基波步长
        else if(scan_on)        nsum <= nsum_nxt;
    end

    // ---------------- 正弦表 ----------------
    wire [15:0] rom_dout;
    Gowin_pROM_sin u_sin (
        .dout  (rom_dout),
        .clk   (clk),
        .oce   (1'b1),
        .ce    (1'b1),
        .reset (1'b0),
        .ad    (sine_ad)
    );

    // ---------------- 泛音包络 RAM（512 x 32bit，SDP BSRAM） ----------------
    reg  [31:0] henv_mem [0:511];
    reg  [31:0] henv_q;
    reg  [31:0] hd2;

    integer hmi;
    initial begin
        for(hmi=0;hmi<512;hmi=hmi+1) henv_mem[hmi] = 32'd0;
    end

    // ---------------- 待重装标志（note_on 到达即置位，扫过该声部最后一个泛音后清除） ----------------
    // 【时序优化】原 pend_clr = 1 << v_wr 要经"sc 减法 -> 5bit 比较 -> 32 路译码"，
    //   该族路径实测 -0.195/-0.113。改用一位有效移位指针 oh：S_SCAN 期间
    //   sc∈[16k,16k+15] 时 oh = 1<<k（纯移位寄存器，无译码逻辑）。
    //   oh_d2（延迟 2 拍）在写回条目 v_wr 的节拍上 = one-hot(v_wr)，用于 pend_clr；
    //   oh_d3（延迟 3 拍）对齐写回第二级流水里 pend_a 的取值拍，用于重装判定位。
    reg [31:0] pend;
    reg [31:0] oh;                          // 声部一位有效指针
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)                             oh <= 32'd1;
        else if(st == S_IDLE)                  oh <= 32'd1;
        else if(scan_on && (sc[3:0] == 4'd15)) oh <= {oh[30:0], 1'b0};
    end
    reg [31:0] oh_d1, oh_d2, oh_d3;
    always @(posedge clk) begin
        oh_d1 <= oh;  oh_d2 <= oh_d1;  oh_d3 <= oh_d2;
    end
    wire [8:0] ent_wr = sc[8:0] - 9'd2;                    // 写回条目号
    wire [3:0] h_wr   = ent_wr[3:0];
    wire       wr_ok  = scan_on && (sc >= 10'd2) && (sc <= 10'd513);
    // 【时序优化】pend_clr 原来是 (wr_ok && h_wr==15)，要串"sc-2 的 9bit 减法 -> 4bit 比较 ->
    //   再与 wr_ok 的 10bit 范围比较合并"，实测 8 级逻辑（sc -> pend，slack -0.21ns）。
    //   因 ent_wr = sc-2，(sc-2)[3:0]==15 ⟺ sc[3:0]==1；又 S_SCAN 内 sc∈[0,SCAN_END=519]，
    //   满足 sc[3:0]==1 的只有 1,17,33,...,513，排除 sc=1（即 sc[9:4]!=0）后与
    //   "sc∈[2,513] 且 h_wr==15" 完全等价。路径缩短为"nibble 比较 + 6bit 或 + AND"。
    wire [31:0] pend_clr = (scan_on && (sc[3:0] == 4'd1) && (|sc[9:4])) ? oh_d2 : 32'd0;

    // 【调试实时音色】dbg_tune 每次改写某声部的泛音权重（wgt_we）时，也把该声部的
    //   pend 置位：本次扫描（或下一帧扫描）经过该声部时重装 henv_mem = W<<16。
    //   这样调试模式下拨动 ch6 平衡滑轨，正在发声的音立刻换成新音色；
    //   只重装泛音包络，不碰主 ADSR，因此不会重新起音，也不会中断试音。
    wire [31:0] wgt_pend = wgt_we ? (32'd1 << wgt_wa[8:4]) : 32'd0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) pend <= 32'd0;
        else       pend <= (pend & ~pend_clr) | note_on | wgt_pend;
    end

    // 【时序优化】原写回路径 = sc -> 16:1 的 SH_TBL/W_TBL 查找 -> 32bit 桶形移位
    //   (移位量 0..31) -> 32bit 减法 -> 条件 mux -> henv_mem，实测约 9.7ns 逻辑延时。
    //   这里拆两级：
    //     一级：把本条目的 SH/W/写地址/有效位 提前一拍查表并寄存（sc 已知，很松）；
    //     二级：用寄存好的移位量做"7 个常量移位并联 + 7:1 选择"（SH ∈ 11..17），
    //           再做减法与条件 mux 后写入。整条路径不再有桶形移位器。
    //   hd2_a/pend_a 与 sh_a 同步寄存，保证与 sh_a 指向同一条目。
    reg  [4:0]  sh_a;
    reg  [15:0] w_a;
    reg  [8:0]  ea;
    reg         we_a;
    reg  [31:0] hd2_a;
    reg  [31:0] pend_a;

    // 【音高依赖衰减】参考竖琴实测：低音弦衰减慢（C3≈-6.8 dB/s）、高音弦衰减快（C5≈-16.5 dB/s）。
    //   本条目的声部号 = ent_wr[8:4]，取八度档 voff = ent_wr[8:7] = 0/1/2/3（v0-7 / v8-15 / v16-23 / v24-31），
    //   把该声部的泛音右移量减去 voff（右移越小 -> 衰减越快），下限钳到 11
    //   （因硬件只做 11..17 的常量移位 7:1 选择）。右移量减小最多 3，基准 SH 最小 11，需钳位。
    //   注：拉弦模式恒重装满幅（pl_b），SH 对其无效 -> 本改动只影响拨弦。
    wire [1:0]  voff = ent_wr[8:7];                     // 声部八度衰减档 0..3
    wire [4:0]  sh_h = SH_TBL[5*h_wr +: 5];
    wire [4:0]  sh_s = sh_h - {3'b0, voff};
    wire [4:0]  sh_c = (sh_s < 5'd11) ? 5'd11 : sh_s;   // 钳到 11..17

    always @(posedge clk) begin
        sh_a   <= sh_c;
        w_a    <= wgt_mem[ent_wr];        // 每声部权重（调试可写，未调时为基准值）
        ea     <= ent_wr;
        we_a   <= wr_ok;
        hd2_a  <= hd2;
        pend_a <= pend;
    end
    wire pend_hit = |(pend_a & oh_d3);      // 该写回条目对应声部的重装标志

    // SH ∈ 11..17：常量移位是纯走线，再 7:1 选择
    wire [31:0] s11 = hd2_a >> 11;
    wire [31:0] s12 = hd2_a >> 12;
    wire [31:0] s13 = hd2_a >> 13;
    wire [31:0] s14 = hd2_a >> 14;
    wire [31:0] s15 = hd2_a >> 15;
    wire [31:0] s16 = hd2_a >> 16;
    wire [31:0] s17 = hd2_a >> 17;
    wire [4:0]  sdi  = sh_a - 5'd11;                       // SH-11 ∈ 0..6
    wire [31:0] shv  = (sdi == 5'd0) ? s11 : (sdi == 5'd1) ? s12 :
                       (sdi == 5'd2) ? s13 : (sdi == 5'd3) ? s14 :
                       (sdi == 5'd4) ? s15 : (sdi == 5'd5) ? s16 : s17;
    wire [31:0] hnew_a0 = hd2_a - (shv | {31'd0, |hd2_a});

    // 【时序优化】再拆一级：把"7:1 选择 + 32bit 减法"与 该条目的重装标志/写地址一起寄存，
    //   写回本身只剩一次 2:1 选择（寄存器 -> RAM）。写回时刻由 sc=3..514 后移一拍到
    //   sc=4..515，仍 ≤ SCAN_END(519)；读地址恒比写地址早 4 拍，无冲突。
    reg  [31:0] sub_r;
    reg  [15:0] w_b;
    reg  [8:0]  ea_b;
    reg         we_b, pl_b;

    always @(posedge clk) begin
        sub_r <= hnew_a0;
        w_b   <= w_a;
        ea_b  <= ea;
        we_b  <= we_a;
        pl_b  <= mode || pend_hit;
    end

    wire [31:0] hnew_b = pl_b ? {w_b, 16'd0} : sub_r;

    always @(posedge clk) begin
        if(we_b) henv_mem[ea_b] <= hnew_b;
        henv_q <= henv_mem[rd_ok ? ent_now : 9'd0];
        hd2    <= henv_q;
    end

    // ---------------- 全工程共享乘法器 x2 ----------------
    wire signed [35:0] pA;
    wire signed [35:0] pB;
    reg         reqB;
    reg  [17:0] aB, bB;

    mul18_shared u_dspA (
        .clk(clk), .rst_n(rst_n),
        .req(reqA),
        .a  (reqA ? {{2{rom_dout[15]}}, rom_dout} : 18'sd0),
        .b  (reqA ? {2'b00, hd2[31:16]} : 18'sd0),
        .ack(), .p(pA)
    );

    mul18_shared u_dspB (
        .clk(clk), .rst_n(rst_n),
        .req(reqB), .a(aB), .b(bB),
        .ack(), .p(pB)
    );

    // 请求 -> 乘积 恰为 3 拍，用请求的延迟链判定"哪一拍的 p 有效"
    reg [2:0] reqA_pipe, reqB_pipe;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin reqA_pipe <= 3'd0; reqB_pipe <= 3'd0; end
        else begin
            reqA_pipe <= {reqA_pipe[1:0], reqA};
            reqB_pipe <= {reqB_pipe[1:0], reqB};
        end
    end
    wire ackA_v = reqA_pipe[2];
    wire ackB_v = reqB_pipe[2];

    // ---------------- 声部波形 16bit 有符号饱和 ----------------
    function signed [15:0] sat16;
        input signed [27:0] x;
        begin
            if(x > 28'sd32767)       sat16 = 16'sd32767;
            else if(x < -28'sd32768) sat16 = -16'sd32768;
            else                     sat16 = x[15:0];
        end
    endfunction

    // ---------------- 声部累加器（16 泛音之和） ----------------
    // 【时序优化】原写法 vacc[ent_acc[8:4]] <= vacc[...] + term 会在同一个周期里
    //   串起"32 选 1 读 mux -> 28bit 加法 -> 32 路写回译码"，实测 120MHz 下
    //   只能跑到 86.7MHz（slack -3.2ns）。
    //   由于扫描顺序本来就是"同一泛音的 16 条连续处理完再换声部"，
    //   这里改成：用 1 个寄存器 vacc_cur 做当前声部的累加（无变址 mux），
    //   在声部最后一个泛音（h==15）那一拍把饱和后的 16bit 声部波形写入
    //   vw_arr[v]（写地址 v_acc 连续 16 拍不变，译码很松）。
    //   S_VOICE 仍按 p2v 读 vw_arr 做 32 选 1（16bit 只读 mux，量级小得多）。
    reg signed [27:0] vacc_cur;                            // 当前声部 16 泛音累加
    reg signed [15:0] vw_arr [0:31];                       // 各声部饱和后的波形
    wire [8:0]  ent_acc = sc[8:0] - 9'd5;                  // 累加条目号 = sc-5
    wire [4:0]  v_acc   = ent_acc[8:4];
    wire [3:0]  h_acc   = ent_acc[3:0];
    wire signed [27:0] term_acc = $signed(pA) >>> 15;
    wire signed [27:0] vacc_nxt = vacc_cur + term_acc;

    integer vi;
    initial begin
        for(vi=0;vi<32;vi=vi+1) vw_arr[vi] = 16'sd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)                             vacc_cur <= 28'sd0;
        else if(sample_en && (st == S_IDLE))   vacc_cur <= 28'sd0;   // 帧起始清零
        // 每声部第一个泛音（h_acc==0）用本项乘积重新起头，其余累加；
        // 否则 16 泛音之商会跨声部（乃至跨帧）累加，各声部波形互相串扰。
        else if(ackA_v)                        vacc_cur <= (h_acc == 4'd0) ? term_acc : vacc_nxt;
    end

    // 声部波形写回：整帧扫描结束时 32 个 vw_arr 必然已全部刷新（先扫后唱）。
    // 【时序优化】vacc_cur -> vacc_nxt(28bit 加法) -> sat16(饱和) -> vw_arr 写口 实测是
    //   一条约 7.5ns 的长路径（加法 ~2ns + 饱和比较/mux ~5.2ns），为音频域当前最差点。
    //   资源充足，这里在加法与饱和之间插一级流水：vacc_nxt 先寄存进 vacc_pipe，
    //   下一拍再用 sat16(vacc_pipe) 写 vw_arr（写地址/写使能同步延迟一拍）。
    //   累加反馈回路（vacc_cur <= vacc_nxt）不受影响，仍每拍累加；写回由 sc=516 后移
    //   到 sc=517，仍 ≤ SCAN_END(519)，早于 S_VOICE，功能不变。
    reg signed [27:0] vacc_pipe;
    reg  [4:0]        v_acc_d;
    reg               vw_wr_d;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            vacc_pipe <= 28'sd0;  v_acc_d <= 5'd0;  vw_wr_d <= 1'b0;
        end else begin
            if(sample_en && (st == S_IDLE)) vacc_pipe <= 28'sd0;   // 帧起始清零
            else if(ackA_v)                 vacc_pipe <= vacc_nxt;
            v_acc_d <= v_acc;
            vw_wr_d <= ackA_v && (h_acc == 4'd15);
        end
    end
    always @(posedge clk) begin
        if(vw_wr_d) vw_arr[v_acc_d] <= sat16(vacc_pipe);
    end

    // 【时序优化】原来 p2 -> vw_arr 32选1(16bit) + env_all 32选1(16bit) -> aB/bB
    //   一路组合直连 DSP 输入寄存器，实测约 9.7ns。这里先把两路 mux 结果寄存一拍
    //   （vw_s/env_s_r），S_VOICE 再用寄存值驱动 aB/bB。请求窗口相应改为 p2∈[1,32]，
    //   即第 p2 拍请求的是第 p2-1 号声部（此时 vw_s 已稳定）。
    wire [4:0]        p2v = p2[4:0];
    reg  signed [15:0] vw_s;
    reg  [7:0]        lvl_s;         // 该声部响度增益（Q7，与 env_s_r 同拍读出）

    // 主 ADSR 包络改为 32x16 RAM 变址读（与 vw_arr 同款分布式 RAM）：ADSR 扫描在
    //   SC_WR 拍经 {env_waddr, env_wdata, env_we} 写入，本引擎按声部号 p2v 同步读出。
    //   同步读延迟 1 拍，与 vw_s 完全对齐（替换原 512bit 扁总线的 32 选 1，该路径
    //   实测 slack 仅 +0.003ns，是音频域最差点）。
    reg  [15:0] env_mem [0:31];
    reg  [15:0] env_s_r;

    integer emi;
    initial begin
        for(emi=0;emi<32;emi=emi+1) env_mem[emi] = 16'd0;
    end

    always @(posedge clk) begin
        if(env_we) env_mem[env_waddr] <= env_wdata;
        vw_s    <= vw_arr[p2v];
        env_s_r <= env_mem[p2v];
        lvl_s   <= lvl_mem[p2v];
    end

    // 每声部响度：包络 x lvl >> 7（16x8 乘法，lvl=128 时逐位等价于 (env) 原值）
    wire [23:0] env_lv = env_s_r * lvl_s;

    // ---------------- 总累加器（32 声部主包络加权求和） ----------------
    reg signed [27:0] sum;
    reg        [35:0] pu, ph;
    reg signed [45:0] q_r, d_r;                            // S_O1 / S_O2 流水寄存器

    wire [17:0] U18 = {1'b0, sum[16:0]};
    wire [17:0] H18 = {7'b0, sum[27:17]};
    wire [17:0] V18 = {2'b0, master_vol};
    wire signed [45:0] q_val  = ({10'b0, ph} << 17) + {10'b0, pu};
    wire signed [45:0] vc_val = {28'b0, V18} << 28;
    wire signed [29:0] mix_v  = d_r >>> 15;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)                           sum <= 28'sd0;
        else if(st == S_IDLE)                sum <= 28'sd0;   // 帧起始清零（唯一驱动点）
        else if(ackB_v && (st == S_VOICE))   sum <= sum + ($signed(pB) >>> SHV);
    end

    // ---------------- 主状态机 ----------------
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            st   <= S_IDLE;  sc <= 10'd0;  p2 <= 6'd0;
            reqB <= 1'b0;    aB <= 18'sd0; bB <= 18'sd0;
            pu   <= 36'd0;   ph <= 36'd0;  mix <= 24'sd0;
            q_r  <= 46'sd0;  d_r <= 46'sd0;
        end else begin
            case(st)
            S_IDLE: begin
                reqB <= 1'b0;
                if(sample_en) begin
                    st <= S_SCAN;       // 相位更新已并入扫描流水，无需单独的 S_PH
                    sc <= 10'd0;
                end
            end

            S_SCAN: begin
                reqB <= 1'b0;
                if(sc == SCAN_END) begin
                    st <= S_VOICE;
                    p2 <= 6'd0;
                end else begin
                    sc <= sc + 10'd1;
                end
            end

            S_VOICE: begin
                // p2∈[1,32] 发请求；aB/bB 取上一拍寄存的 vw_s/env_s_r（第 p2-1 号声部）
                if((p2 >= 6'd1) && (p2 <= 6'd32)) reqB <= 1'b1;
                else                              reqB <= 1'b0;
                aB <= {{2{vw_s[15]}}, vw_s};
                bB <= {1'b0, env_lv[23:7]};      // 18bit：lvl=128 时与原值逐位一致
                if(p2 == VOICE_END) st <= S_V1;
                else                p2 <= p2 + 6'd1;
            end

            // 总音量两次乘法：reqB 只发单拍脉冲，应答由 reqB 的 3 拍延迟链唯一标记，
            // 避免"保持请求"产生的多余应答被下一个状态误取。
            S_V1:  begin reqB <= 1'b1; aB <= U18; bB <= V18; st <= S_V1W; end
            S_V1W: begin
                reqB <= 1'b0;
                if(ackB_v) begin pu <= pB; st <= S_V2; end
            end
            S_V2:  begin reqB <= 1'b1; aB <= H18; bB <= V18; st <= S_V2W; end
            S_V2W: begin
                reqB <= 1'b0;
                if(ackB_v) begin ph <= pB; st <= S_O1; end
            end

            S_O1: begin                                 // 46bit 加法（q_val）
                reqB <= 1'b0;
                q_r  <= q_val;
                st   <= S_O2;
            end
            S_O2: begin                                 // 46bit 带符号减法
                d_r  <= sum[27] ? (q_r - vc_val) : q_r;
                st   <= S_OUT;
            end
            S_OUT: begin                                // 24bit 硬限幅
                mix <= (mix_v >=  30'sh7FFFFF) ?  24'sh7FFFFF :
                       (mix_v <= -30'sh800000) ? -24'sh800000 : mix_v[23:0];
                st  <= S_IDLE;
            end
            endcase
        end
    end

endmodule