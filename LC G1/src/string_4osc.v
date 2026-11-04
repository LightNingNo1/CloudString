// ============================================================================
// string_4osc.v - 单弦"四分音"合成器（24 振荡器共享 1 个 pROM 版本）
// ----------------------------------------------------------------------------
// 每根弦有 4 个独立 DDS 相位累加器，频率比为 1:2:3:4（基波 + 2/3/4 次分音）。
// 本模块不自带 pROM，只对外暴露"地址输出 + 数据输入"两组引脚：
//
//   rom_addr   : 本弦当前分音的 LUT 地址。在 slot_begin 那一拍由 scan_part
//                从 4 路相位累加器里选出并锁存，整个扫描槽内保持稳定，
//                顶层用 6 选 1 组合逻辑把 6 根弦的 rom_addr 汇到共享 pROM。
//   接收侧     : scan_str / scan_part / slot_begin / scan_valid / rom_dout
//                顶层扫描器广播"现在轮到哪根弦的哪个分音"，本弦只在
//                scan_valid && scan_str==IDX 时把 rom_dout 存进 part[scan_part]。
//   分音包络   : 4 个分音各有独立幅值包络 env_p[n]（24bit 泄漏累加器）：
//                拉弦(小提琴)：4 个分音恒满幅（持续音，所有泛音一起延续）；
//                拨弦(竖琴)  ：note_on 起音瞬间 4 个分音同时满幅（亮起音），
//                              随后 2/3/4 次分音按 τ=194/97/49ms 指数衰减，
//                              基波不额外衰减（交给主 ADSR），音色由亮转暖，
//                              即竖琴拨弦的典型特征。
//                分音权重（分子/32）折进包络满幅值，满幅时合成结果与
//                "纯加权和"逐位一致（拨弦 16/4/2/1、拉弦 16/8/4/2）。
//                每采样周期做 4 次乘累加，8 根弦 + 8 路混音共用全工程唯一一个
//                18x18 乘法器（见 mul18_arb.v / mul18_shared.v）：4 个分音采样在
//                各自扫描槽到齐后由小状态机依次向共享乘法器请求，收到应答再累加。
//
// 顶层扫描时序（见 prom_scan24.v，每槽 5 拍，24 槽共 120 拍 < 采样周期 1152 拍）：
//   拍0 slot_begin（本弦锁存地址） -> 拍1~3 地址稳定（供 pROM 内部锁存/输出）
//   -> 拍3 末顶层取回 rom_dout 并置 scan_valid -> 拍4 广播给本弦取数
// 地址在 pROM 前稳定 3 拍，与旧"每弦独占 pROM"方案的时序余量完全一致。
//
// inc_base 为运行时输入（不再编译期固定）：第一根弦由模拟电压经 pitch_map 驱动，
// 其余弦由顶层直接接常量。分音 2/3/4 的步长用移位相加实时算出（×2、×3、×4），
// 不占乘法器；相位累加器连续累加，所以步长变化时音高连续弯折、不会爆音。
// ============================================================================
module string_4partial #(
    parameter [2:0]  IDX    = 3'd0,        // 本弦编号 0..5，用于识别扫描广播是否轮到自己
    // 四个分音的幅度权重（分子/32），依次作用于 1、2、3、4 次分音；
    // 同时就是各分音独立包络的满幅值（满幅时合成波 = 纯加权和）
    // 拨弦(竖琴)：16/4/2/1 = 1/n² 衰减（0/-12/-18/-24dB）。
    // 手指拨弦时弦的初始位移是三角形，分音包络本就按 1/n² 收。旧值 16/6/3/2
    // （0/-8.5/-14.6/-18dB）高次分音比 1/n² 强 3.5~6dB，叠上 1.5ms 硬起振与
    // τ=777ms 长驻的 2 次分音，会听成钢琴的"击弦+木质余韵"，故压到 1/n²。
    parameter [5:0]  PN0    = 6'd16,
    parameter [5:0]  PN1    = 6'd4,
    parameter [5:0]  PN2    = 6'd2,
    parameter [5:0]  PN3    = 6'd1,
    // 拉弦(小提琴)：16/8/4/2 —— 每高一次分音低 6dB 的等比收尾（0/-6/-12/-18dB）。
    // 2 次分音保持强劲（琴体共鸣的厚度），但 3/4 次分音要压下去：只有 4 条谱线时，
    // 顶端若按 1/n 硬截断（旧值 16/8/5/4 -> -10/-12dB），0.8~1.8kHz 这一小段
    // "谱线棱角"会被听成蜂鸣器式的电子味；等比收尾让顶端平顺收掉，音色暖而不刺。
    parameter [5:0]  BN0    = 6'd16,
    parameter [5:0]  BN1    = 6'd8,
    parameter [5:0]  BN2    = 6'd4,
    parameter [5:0]  BN3    = 6'd2
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              sample_en,
    input  wire              enable,
    input  wire              mode,         // 0=拨弦(竖琴), 1=拉弦(小提琴)
    input  wire              note_on,      // 本弦触发脉冲（拨弦=松开触发）：复位分音包络
    input  wire [31:0]       inc_base,     // 基波相位步长（运行时可变）
    // ---------------- 共享 pROM 接口 ----------------
    input  wire [2:0]        scan_str,     // 顶层当前扫描的弦号（0..5）
    input  wire [1:0]        scan_part,    // 顶层当前扫描的分音号（0..3）
    input  wire              slot_begin,   // 扫描槽起始，本弦在此拍锁存地址
    input  wire              scan_valid,   // rom_dout 有效，本弦在此拍取数
    input  wire [15:0]       rom_dout,     // 共享 pROM 数据（顶层广播）
    output wire [11:0]       rom_addr,     // 本弦当前分音地址（送顶层 6 选 1）
    output reg signed [15:0] osc_out,
    // ---------------- 全工程共享乘法器接口（见 mul18_arb.v） ----------------
    output reg  [17:0]       mul_a,        // 乘数：本分音采样（16bit 有符号扩 18）
    output reg  [17:0]       mul_b,        // 被乘数：本分音包络高16bit（扩 18）
    output reg               mul_req,      // 请求共享乘法器
    input  wire              mul_ack,      // 共享乘法器应答（单拍）
    input  wire signed [35:0] mul_p,       // 共享乘法器乘积
    output reg               osc_valid     // 本采样点 osc_out 就绪（单拍脉冲）
);
// 四个分音的相位步长：基波 ×1/×2/×3/×4（纯移位相加，无乘法器）
wire [31:0] INC1 = inc_base;
wire [31:0] INC2 = inc_base << 1;
wire [31:0] INC3 = inc_base + (inc_base << 1);
wire [31:0] INC4 = inc_base << 2;

// ---------------- 4 路独立相位累加器 ----------------
reg [31:0] phase [0:3];
integer n;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        phase[0] <= 32'd0;
        phase[1] <= 32'd0;
        phase[2] <= 32'd0;
        phase[3] <= 32'd0;
    end else if(sample_en && enable) begin
        phase[0] <= phase[0] + INC1;
        phase[1] <= phase[1] + INC2;
        phase[2] <= phase[2] + INC3;
        phase[3] <= phase[3] + INC4;
    end
end

// ---------------- 地址输出：槽起始时锁存当前分音的地址 ----------------
reg [11:0] addr_r;
wire [11:0] phase_addr = (scan_part == 2'd0) ? phase[0][31:20] :
                         (scan_part == 2'd1) ? phase[1][31:20] :
                         (scan_part == 2'd2) ? phase[2][31:20] :
                                               phase[3][31:20];
assign rom_addr = addr_r;

// ---------------- 分音独立包络 ----------------
// 24bit 泄漏累加器，每采样点自乘 (1 - 2^-SH)： env <= env - ((env>>>SH) | 1)
// 满幅值 = 权重(分子/32) × 2^19；取高 16bit（= 权重 × 2^11）送乘法器，于是满幅时
//   osc = Σ(sample × 权重 × 2^11) >>> 16 = Σ(sample × 权重) >>> 5
// 与原来"纯加权和"的结果逐位相同。余韵里 2/3/4 次分音的 τ 依次减半（SH 减 1）：
//   τ = 2^14 / 2^13 / 2^12 拍 = 341 / 171 / 85 ms（fs=48kHz，比 21.7kHz 时代整体加倍）。
localparam SH1 = 5'd14, SH2 = 5'd13, SH3 = 5'd12;
localparam [23:0] EP0 = PN0 << 19, EP1 = PN1 << 19, EP2 = PN2 << 19, EP3 = PN3 << 19;
localparam [23:0] EB0 = BN0 << 19, EB1 = BN1 << 19, EB2 = BN2 << 19, EB3 = BN3 << 19;

wire [23:0] e0i = mode ? EB0 : EP0;
wire [23:0] e1i = mode ? EB1 : EP1;
wire [23:0] e2i = mode ? EB2 : EP2;
wire [23:0] e3i = mode ? EB3 : EP3;

reg  [23:0] env_p [0:3];
reg         note_lat;      // note_on 可能落在两个采样点之间，锁存到本采样点处理
reg  [15:0] part  [0:3];   // 4 个分音取回的 LUT 采样

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        for(n=0;n<4;n=n+1) env_p[n] <= 24'd0;
        note_lat <= 1'b0;
    end else begin
        note_lat <= (note_lat | note_on) & ~sample_en;
        if(sample_en) begin
            if(mode || note_on || note_lat) begin
                // 拉弦持续音 / 拨弦起音：4 个分音同时满幅（亮起音）
                env_p[0] <= e0i;
                env_p[1] <= e1i;
                env_p[2] <= e2i;
                env_p[3] <= e3i;
            end else begin
                // 拨弦余韵：高次分音逐个更快衰减（τ 随分音号减半）
                // 减值末位用 |env_p[n]（而非常量 1）：包络已归零时减值也为 0，
                // 保持 0 不动；否则 0-1 会把 24bit 累加器下溢翻成近满幅大数，
                // 静音弦会在余韵结束后反而冒出很响的衰减噪声。
                env_p[0] <= e0i;
                env_p[1] <= env_p[1] - ((env_p[1] >>> SH1) | {23'd0, |env_p[1]});
                env_p[2] <= env_p[2] - ((env_p[2] >>> SH2) | {23'd0, |env_p[2]});
                env_p[3] <= env_p[3] - ((env_p[3] >>> SH3) | {23'd0, |env_p[3]});
            end
        end
    end
end

// ---------------- 每采样周期 4 次乘累加（乘法器为全工程共享，见 mul18_arb.v） ----------------
// 本弦第 4 个分音到齐后启动：依次把 (分音采样, 该分音包络高16bit) 送给共享乘法器，
// 发出请求后保持操作数不变，直到收到 mul_ack（单拍脉冲），取回乘积累加。
localparam [1:0] M_IDLE = 2'd0, M_REQ = 2'd1, M_WAIT = 2'd2, M_OUT = 2'd3;

reg  [1:0]         mst;
reg  [1:0]         midx;
reg  signed [33:0] macc;

wire [23:0] env_m = env_p[midx];

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        addr_r    <= 12'd0;
        osc_out   <= 16'sd0;
        mst       <= M_IDLE;
        midx      <= 2'd0;
        macc      <= 34'sd0;
        mul_a     <= 18'sd0;
        mul_b     <= 18'sd0;
        mul_req   <= 1'b0;
        osc_valid <= 1'b0;
        for(n=0;n<4;n=n+1) part[n] <= 16'd0;
    end else begin
        osc_valid <= 1'b0;                                  // 默认清零，仅 M_OUT 输出一拍
        if(slot_begin && (scan_str == IDX))
            addr_r <= phase_addr;
        if(scan_valid && (scan_str == IDX))
            part[scan_part] <= rom_dout;

        case(mst)
        M_IDLE: if(scan_valid && (scan_str == IDX) && (scan_part == 2'd3)) begin
                    macc <= 34'sd0;
                    midx <= 2'd0;
                    mst  <= M_REQ;
                end
        M_REQ:  begin                                        // 送出本分音操作数并请求乘法器
                    mul_a   <= {{2{part[midx][15]}}, part[midx]};   // 16bit 有符号 -> 18bit
                    mul_b   <= {2'b00, env_m[23:8]};               // 16bit 无符号 -> 18bit
                    mul_req <= 1'b1;
                    mst     <= M_WAIT;
                end
        M_WAIT: if(mul_ack) begin                            // 收到乘积
                    macc    <= macc + $signed(mul_p[32:0]);
                    mul_req <= 1'b0;
                    if(midx == 2'd3) mst  <= M_OUT;
                    else begin midx <= midx + 1'b1; mst <= M_REQ; end
                end
        default: begin                                       // M_OUT：4 个分音累加完毕
                    osc_out   <= enable ? (macc >>> 16) : 16'sd0;
                    osc_valid <= 1'b1;
                    mst       <= M_IDLE;
                end
        endcase
    end
end
endmodule