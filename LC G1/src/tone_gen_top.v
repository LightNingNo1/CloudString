// tone_gen_top.v - 顶层模块（拨弦/拉弦双模式 / 32 声部 16 泛音加法合成 / 74HC4051D 32 通道弦音触发扫描 / RGB LCD / 32 灯曲目指引）
module tone_gen_top(
    input  wire       clk,
    input  wire       key_mode,    // F10 模式键（IO 内部上拉，按下=0）：单击(<1s)=切音色，长按1s~2.5s=指引开/停，长按2.5s=切曲
                                    // 三区间手势判定见文件末尾内联的 f10_ctl 与第 4 节
    input  wire       key_slide,   // 【已弃用】原滑音使能键 PIN 88；滑音现由模式决定，此引脚不再使用
    input  wire       enc_a, enc_b, enc_sw,   // EC11 编码器：A/B 相 + 轴按开关；公共端接 GND（内部上拉，空闲=1、按下=0）
    input  wire       key_song,    // 【已弃用】曲目键已取消：指引开/停由 F10 长按 1s~2.5s 负责
    input  wire       key_test,    // D11 测试音键（IO 内部上拉，按下=0）：触发模式对应弦（拨弦=C5弦、拉弦=第2弦）
    // ---- LCD 人机界面按键（IO 内部上拉，按下=0）----
    input  wire       key_up,      // P6：光标上移 / 示波模式上一页
    input  wire       key_down,    // N7：光标下移 / 示波模式下一页
    input  wire       key_ok,      // M7：确定 / 长按 1s 立刻退回初始界面
    input  wire       bt_rx,       // 蓝牙模块 VG6328A 的 UART TX -> FPGA（引脚 H11）
    output wire       bt_tx,       // FPGA -> 蓝牙模块 VG6328A 的 UART RX（引脚 F15）
    output wire       pc_rx,       // G16 硬件验证输出：1kHz 方波（原 PC 调试输入，调试已结束）
    output wire       pc_tx,       // FPGA -> USB-TTL RX（引脚 L9，暂留备用）
    output wire       hp_bck, hp_ws, hp_din,   // MAX98357A I2S 三线
    // ---- 74HC4051D 两级 32 通道弦音触发扫描
    output wire [2:0] key_s,       // 一级 74HC4051D 地址 S0/S1/S2（只用 Y0~Y3，S2 恒 0）
    input  wire       key_z,       // 一级 74HC4051D 公共端 Z（低电平 = 该通道触发）
    output wire       key_inh,     // 一级 74HC4051D 使能 INH（低有效：0=使能）
    // ---- 二级 4 片 74HC4051D 共用地址线
    output wire       mux_a0,      // 二级 S0
    output wire       mux_a1,      // 二级 S1
    output wire       mux_a2,      // 二级 S2
    // ---- 外置 8 路红外管扫描：74HC238D 3-8 译码器 ----
    output wire       ir_a0,       // 74HC238D A0
    output wire       ir_a1,       // 74HC238D A1
    output wire       ir_a2,       // 74HC238D A2
    output wire       ir_e3,       // 74HC238D E3（高电平使能；另两根使能脚硬件已固定使能）
    // ---- ADC088S022 八通道 12bit SPI ADC（内置 8 选 1，无需外置 74HC4051）----
    output wire       adc_cs_n,    // CS#（低有效，帧起始）
    output wire       adc_sclk,    // SCLK
    output wire       adc_din,     // DIN（FPGA -> ADC，通道地址在 bit5:3）
    input  wire       adc_dout,    // DOUT（ADC -> FPGA，MSB first）
    // ---- 板载 40P FPC RGB565 LCD（480x272，SYNC-DE，无 HS/VS） ----
    output wire       lcd_clk,     // 10MHz 像素时钟
    output wire       lcd_de,      // 数据使能
    output wire [4:0] lcd_b,
    output wire [4:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire       lcd_en,
    // ---- 曲目指引 LED：32 颗 = 两级 74HC238D 矩阵（一级选片/二级选灯，扫描点亮）----
    output wire       led_en1,     // 一级 238 使能（A11；高电平有效，同红外 238 的 E3 接法）
    output wire [2:0] led_ad1,     // 一级地址 A0/A1/A2 = A15/B11/C12（只用 Y0~Y3，bit2 恒 0）
    output wire [2:0] led_ad2      // 二级地址 A0'/A1'/A2' = A14/E14/D15（二级使能硬件常开）
);

// ============================================================================
// ADC 模拟前端说明
// ----------------------------------------------------------------------------
// 模拟前端为 ADC128S102（8 通道 12bit SPI ADC，内置 8 选 1 多路开关），
// 取代了旧的 74HC4051 + MCP3201（adc_mux8.v 仍在工程内但已不再例化）。
// 通道分工（ch0 与 ch6 已对调，音量改由 ch0 控制）：
//   ch0      -> 六弦总音量（0V = 静音，VA ≈ 满幅，线性）
//   ch1..ch6 -> 弦0..弦5 的滑音压控（各自定弦基频 × ratio = 2^(code/1346)，只升不降）
//   ch7      -> 数据无效，丢弃
// 例化见第 5b 节；总音量 master_vol 供第 10 节混音使用。
// ============================================================================

// 1. 上电复位（50MHz 外设域）
wire rst_n;
por_rst u_por (.clk(clk), .rst_n(rst_n));

// 1b. 音频域时钟：50MHz -> 120MHz（参数与频率依据见 gowin_rpll_audio.v）
//     CLKOUT=120MHz / PFD=10MHz / VCO=960MHz，三项均在 DS102 表 4-19 规内。
//     96kHz 采样率下每帧 1250 拍。音频合成链（混音 + I2S，后续的 TDM 振荡器引擎、
//     32 声部 ADSR、512 泛音包络）都跑在这个域；外设（ADC、4051 扫描、按键、EC11、
//     UART、BLE、LCD、调试串口）继续跑 50MHz，分频常量一律不动，互不影响。
wire clk_audio;
wire pll_audio_lock;
Gowin_rPLL_audio u_rpll_aud (.clkin(clk), .clkout(clk_audio), .lock(pll_audio_lock));

// 音频域复位：PLL 未锁定期间保持复位，锁定后同步释放两拍
wire rst_aud_n = pll_audio_lock & rst_n;
reg  [1:0] aud_rst_sync;
always @(posedge clk_audio or negedge rst_aud_n) begin
    if (!rst_aud_n) aud_rst_sync <= 2'b00;
    else            aud_rst_sync <= {aud_rst_sync[0], 1'b1};
end
wire rst_n_aud = aud_rst_sync[1];

// 2. 采样脉冲
//   sample_en : 音频域(120MHz)帧脉冲，由 i2s_tx 每帧(1250 拍)产生，供音频合成链使用
//   （song_player 已改为逐拍判定，不再需要外设域 96kHz 脉冲，原 sample_en_50 分频已删除）
wire sample_en;

// 3. 弦音触发：由 3d 节的两级 74HC4051D 32 通道扫描产生（见下），共 32 个声部。
//    8 根弦的 press/release/level 全部来自扫描结果 —— 扫描是唯一的弦音触发源；
//    原直连弦键（key_d0/key_d1）与 key_scan8 模块已删除。
reg  [31:0] key_press;   // 触发脉冲（单周期，1=该声部本轮判定为触发）
reg  [31:0] key_release; // 松开脉冲（单周期，1=该声部本轮判定为松开）
reg  [31:0] key_level;   // 消抖后电平（1 = 触发）；位序 = 声部号 v = sub*8 + grp
reg  [31:0] key_level_raw; // 未消抖采样电平（sub_end 逐通道锁存，1ms 级；拉弦松手沿判定用：
                          // 移开手 <=1ms 即恢复 0，不依赖消抖"连续 2 次一致"的恢复确认）

// 3c. 外置 8 路红外管扫描：74HC238D 3-8 译码器，A0/A1/A2 选通 Y0..Y7
//     E3 恒为高使能（另两根使能脚硬件已固定使能）。
//     【红外顺序重映射】组扫描顺序对应红外通道：1 5 2 6 3 7 4 8。
//       grp=0..7 时，红外地址依次为 0 4 1 5 2 6 3 7，
//       地址位映射为 ir = {grp[0], grp[2], grp[1]}。
//     红外译码与二级 4051 使用同一组红外序号，再由选通端做反向匹配。
//     grp 在第 3d 节声明，Verilog 模块内声明顺序不影响引用。
wire [2:0] scan_grp = {grp[0], grp[2], grp[1]};
assign ir_a0 = scan_grp[0];      // 红外通道号 bit0
assign ir_a1 = scan_grp[1];      // 红外通道号 bit1
assign ir_a2 = scan_grp[2];      // 红外通道号 bit2
assign ir_e3 = 1'b1;             // 译码器使能保持有效

// 3d. 两级 74HC4051D 级联 = 32 通道选通（一级 4 选 1 × 二级 8 选 1）
//     【拓扑】
//       一级 = 上面这片 4051（端口沿用 key_s / key_inh / key_z）：
//         只用 Y0~Y3，S0/S1 选"二级八路片号"，S2 恒 0；INH 恒使能；Z 送回 FPGA。
//       二级 4 片：地址线共用 mux_a2..a0；各片 Z 分别接一级的 Y0/Y1/Y2/Y3；
//         4 片 INH 硬件直接固定使能 —— 一级同一时刻只导通一路，不会抢总线。
//     【通道标定】第一个二级八路(片0)的 8 路 = ch0~ch7，片1 = ch8~ch15，以此类推：
//         ch = 片号×8 + 片内序号；片号 = 一级地址 sub，片内序号 = 二级地址 grp。
//     【分组】把 4 片二级八路中"同一序号"的通道归为一组：
//         组 g = {ch g, ch g+8, ch g+16, ch g+24}（即 4 片的第 g 路），共 8 组。
//         组 g 的 4 路恰好由"二级地址固定为 g、一级地址步进 0→3"选通。
//     【声部映射】32 路全部参与发声，声部号 v = 片号 sub×8 + 片内序号 grp = ch：
//         拨弦 32 声部全开（v0..v31 = 竖琴 C3~F7 的连续白键音，组间不重复）；
//         拉弦仅片0 前 6 路的可变声部 v0..v5（见第 6 节 BOW_MASK）。
//
//     【时序】红外与组周期同拍切换：进入第 g 组周期 = 点亮该组对应的红外通道（映射见 3c）。
//       组周期 125us = 6250 拍 @50MHz，8 组 = 1ms 一整轮，32 路各 1kHz 刷新。
//       每个组周期开头先等 60us（3000 拍）建立电平，此间 key_z 不采集；
//       随后对该组 4 路依次扫描，4 段共 3250 拍 = 812/813/812/813
//       （3250/4 = 812.5 非整数，故偶段 812 拍、奇段 813 拍），每段末采样一次。
//       60us 建立 + 3250 拍扫描 = 6250 拍 = 125us：组周期/1kHz 每路刷新率保持不变。
reg  [2:0]  grp;                 // 组号 0..7 = 红外通道号 = 二级地址
reg  [1:0]  sub;                 // 组内子槽 0..3 = 一级地址（二级八路片号）
reg  [12:0] gp_d;                // 组周期内计数 0..6249
reg  [11:0] sc_d;                // 组内子槽计数

localparam [12:0] GP_MAX   = 13'd6249;   // 125us - 1
localparam [12:0] SETTLE_N = 13'd3000;   // 60us 建立期（此间不采样；组周期仍 125us，靠缩短子槽补偿）
wire         settling = (gp_d < SETTLE_N);
wire  [11:0] sc_max   = sub[0] ? 12'd812 : 12'd811;    // 偶段 812 拍 / 奇段 813 拍
wire         sub_end  = (!settling) && (sc_d == sc_max);

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        grp  <= 3'd0;
        sub  <= 2'd0;
        gp_d <= 13'd0;
        sc_d <= 12'd0;
    end else begin
        if(gp_d == GP_MAX) gp_d <= 13'd0;          // 组周期计数
        else               gp_d <= gp_d + 1'b1;

        if(settling)          sc_d <= 12'd0;       // 建立期不计子槽
        else if(sub_end)      sc_d <= 12'd0;
        else                  sc_d <= sc_d + 1'b1;

        if(gp_d == GP_MAX) begin                   // 组周期结束 -> 换下一组
            sub <= 2'd0;
            grp <= grp + 1'b1;                     // 3bit 自然回卷 7->0
        end else if(sub_end) begin
            sub <= sub + 1'b1;
        end
    end
end

assign key_s[0] = sub[0];        // 一级 S0 <- 二级八路片号 bit0
assign key_s[1] = sub[1];        // 一级 S1 <- 二级八路片号 bit1
assign key_s[2] = 1'b0;          // 一级 S2 不用（只用到 Y0~Y3）
assign key_inh  = 1'b0;          // 一级 INH 恒使能（低有效）
assign mux_a0   = ~scan_grp[0];  // 选通通道与红外编号反向：红外1对应选通8
assign mux_a1   = ~scan_grp[1];
assign mux_a2   = ~scan_grp[2];

// key_z 两级同步（外部器件输入）+ 每个通道 2 次采样消抖 + 边沿脉冲
//   采样口径：读到低电平(key_z=0) = 红外【遮挡】。
//   每个子槽末（sub_end）都采样：子槽 sub 选通的正是"二级片 sub 的 grp 路"，
//   即通道 v = sub*8 + grp —— 与 32 声部的位序完全一致。
//   每个通道每 1ms 采样一次（一组 8 组周期 = 1ms，各组内 4 个子槽恰好覆盖 4 个片）。
//   连续 2 次采样（2ms）一致才确认翻转（DB_N，见下：3ms 会吞掉快速拨弦）。
//   确认后输出单周期边沿脉冲：ch_trig 0->1 = key_press（对应红外高→低，即【遮挡】），
//                               ch_trig 1->0 = key_release（对应红外低→高，即【恢复】）。
reg        z_s0, z_s1;
wire       ch_trig = ~z_s1;          // 本子槽采样值（1 = 遮挡）
localparam [4:0] DB_N = 5'd2;        // 连续 2 次一致即确认（1kHz 采样 -> 2ms）
                                     // 3ms 时快速拨弦（红外遮挡 2~5ms）整段被吞、key_level
                                     // 从未确认 -> 拉弦短按松手沿永远不出现；2ms 确认后
                                     // 遮挡 >=2ms 必被捕捉（2ms 窗口必覆盖 2 个采样点），
                                     // 仍保留对边缘抖动/噪声的 2 次一致滤除。
reg [4:0]  db_cnt [0:31];            // 每通道"与当前电平连续不一致"的采样计数
wire [4:0] v_idx = {sub, ~scan_grp}; // 声部号对应当前实际选通的二级通道地址
integer    i;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        z_s0        <= 1'b1;
        z_s1        <= 1'b1;
        key_press   <= 32'h0000_0000;
        key_release <= 32'h0000_0000;
        key_level   <= 32'h0000_0000;
        key_level_raw <= 32'h0000_0000;
        for(i = 0; i < 32; i = i + 1) db_cnt[i] <= 5'd0;
    end else begin
        z_s0 <= key_z;
        z_s1 <= z_s0;
        key_press   <= 32'h0000_0000;   // 脉冲默认清零，仅翻转那一拍置位
        key_release <= 32'h0000_0000;
        if(sub_end) begin                   // 每个子槽末采样通道 v = sub*8 + grp
            key_level_raw[v_idx] <= ch_trig;   // 原始采样值直接锁存（1ms 级，不做消抖确认）
            if(ch_trig != key_level[v_idx]) begin
                if(db_cnt[v_idx] == DB_N - 1'b1) begin
                    db_cnt[v_idx]    <= 5'd0;
                    key_level[v_idx] <= ch_trig;
                    if(ch_trig) key_press[v_idx]   <= 1'b1;
                    else        key_release[v_idx] <= 1'b1;
                end else begin
                    db_cnt[v_idx] <= db_cnt[v_idx] + 1'b1;
                end
            end else begin
                db_cnt[v_idx] <= 5'd0;
            end
        end
    end
end

// 4. 模式键（F10 引脚，IO 内部上拉，按下=0）【三手势控制三种功能，互不冲突】：
//    单击（按下 <1s 松开）      -> single_click：拨弦/拉弦切换
//    长按 1s~2.5s（松开时判定） -> hold_guide  ：曲目指引开/停
//    长按 >=2.5s（到点当拍触发）-> long_press  ：切下一首预制曲目
//    冲突避免（判定规则见文件末尾内联的 f10_ctl）：一次按压只按"松开时的按住
//    时长"落一个区间——<1s 切音色、1s~2.5s 指引、>=2.5s 切曲（切曲在 2.5s 到点
//    即触发并锁定，松开不再补发其他手势），故长按 1s 开关指引与长按切曲不冲突。
wire mode_f10;                 // F10 单击选择的音色（界面未接管时生效）
wire mode;                     // 实际生效音色：0=拨弦(竖琴), 1=拉弦(小提琴)
wire mode_db;                  // 消抖后电平：1=松开, 0=按下
debounce u_kmode (.clk(clk), .rst_n(rst_n), .key_in(key_mode), .key_out(mode_db), .key_press());
wire f10_single, f10_hold, f10_long;      // F10 单击 / 长按1s指引 / 长按2.5s切曲 单拍脉冲
f10_ctl u_f10 (.clk(clk), .rst_n(rst_n), .key_down(~mode_db),
               .single_click(f10_single), .hold_guide(f10_hold), .long_press(f10_long));
mode_switch #(.DEFAULT_MODE(1'b0)) u_mode (.clk(clk), .rst_n(rst_n), .mode_press(f10_single), .mode(mode_f10));

// 滑音【已取消】：六路滑轨（ADC ch1~ch6）全部改作调试模式用（见第 4b / 9b 节）。
//   音高只由 pitch_32v 的基准表 + 调试比例决定；key_slide 端口保留但不再使用。

// 4b. D11 测试音键（IO 内部上拉，按下=0）：按下即触发指定声部发声，用于验证音频通路。
//     【按模式选弦，不改音高】不再覆写音高，而是触发音高表中该声部自身的自然音高：
//       拨弦模式 -> 触发 C5 所在的弦（v14）
//       拉弦模式 -> 触发 v0（G3，4 弦 8 段表的第 1 格）
//       【调试模式】D11 短按 = 试听当前选中声部（sel_v）；长按 1s 进/出调试模式。
//     触发沿与弦触发一致：按下给 note_on 脉冲起振；松开拉低 key_level，
//     拉弦模式下立即进入释放，拨弦模式下按 ADR 自然衰减。
//     注意：与 4051 扫描触发同名弦互斥 —— 按住本键时该声部一律按其音高表音发声。
wire test_press, test_db;                 // test_db: 1=松开, 0=按下（debounce 低有效）
wire test_held = ~test_db;                // 1=按下（与 key_level 的"1=触发"同极性）
debounce u_ktest (.clk(clk), .rst_n(rst_n), .key_in(key_test),
                  .key_out(test_db), .key_press(test_press));
localparam [4:0] TEST_V_PLK = 5'd14;      // 拨弦：C5 所在的弦
localparam [4:0] TEST_V_BOW = 5'd0;       // 拉弦：v0 = G3（4 弦 x 8 段的起点）

// 调试模式人机控制（D11 长按 1s 进/出；LCD 调试页强制开启；音键长按 800ms 选音）
//   例化放在 4e 节（需先有界面的 dbg_req），此处只声明信号。
wire        dbg_en;                       // D11 调试模式电平（50MHz 域）
wire [4:0]  sel_v;                        // 当前调音声部
wire        dbg_blink;                    // 1Hz 闪烁

// 4c. LCD 人机界面按键（P6 上移 / N7 下移 / M7 确定，IO 内部上拉，按下=0）
//     P6/N7 直接用消抖后的"按下"单拍脉冲；M7 区分短按（=确定）与长按 1s
//     （=无论在哪个分支都立刻退回初始界面）。
wire ui_up_db, ui_dn_db, ui_ok_db;
wire ui_up_p,  ui_dn_p;
debounce u_kup (.clk(clk), .rst_n(rst_n), .key_in(key_up),
                .key_out(ui_up_db), .key_press(ui_up_p), .key_release());
debounce u_kdn (.clk(clk), .rst_n(rst_n), .key_in(key_down),
                .key_out(ui_dn_db), .key_press(ui_dn_p), .key_release());
debounce u_kok (.clk(clk), .rst_n(rst_n), .key_in(key_ok),
                .key_out(ui_ok_db), .key_press(), .key_release());
wire ui_ok_short, ui_ok_long;             // 短按单拍 / 长按 1s 到点单拍
ui_ok_ctl u_uok (.clk(clk), .rst_n(rst_n), .key_down(~ui_ok_db),
                 .short_press(ui_ok_short), .long_press(ui_ok_long));

// 4d. LCD 菜单状态机：初始界面 = 主菜单（演奏/调试/LED指引/示波），
//     P6 上移 / N7 下移 / M7 短按确定，M7 长按 1s 任意分支回主菜单。
//     scr 同时是屏幕号，交给 lcd_rgb 的 ui_text/ui_lines 取字。
wire [2:0] ui_scr, ui_cur;
wire       ui_instr;                     // 界面选择的乐器（0 竖琴 / 1 小提琴）
wire [1:0] ui_page;                      // 示波页号 0/1/2；3 = 非示波界面
wire       ui_mode_en;                   // 演奏/调试/指引页：界面接管音色模式
wire       ui_dbg_req;                   // 调试页：强制调试模式
wire [1:0] ui_song_idx;
wire       ui_song_start, ui_song_stop;
ui_menu u_ui (
    .clk(clk), .rst_n(rst_n),
    .up_p(ui_up_p), .dn_p(ui_dn_p),
    .ok_short(ui_ok_short), .ok_long(ui_ok_long),
    .scr(ui_scr), .cur(ui_cur), .instr(ui_instr), .page(ui_page),
    .instr_tgl(f10_single & ui_mode_en),
    .mode_en(ui_mode_en), .dbg_req(ui_dbg_req),
    .song_idx(ui_song_idx), .song_start(ui_song_start), .song_stop(ui_song_stop));

// 乐器模式：演奏/调试/指引页由 LCD 菜单选择的乐器接管（instr 0 竖琴 / 1 小提琴），
//   页面内 F10 单击仍可翻转当前乐器（见 ui_menu 的 instr_tgl）；
//   不在上述页面时由 F10 单击切换（mode_f10）。
assign mode = ui_mode_en ? ui_instr : mode_f10;

// 4e. 调试模式人机控制（D11 长按 1s 进/出；进入 LCD 调试页时强制开启）
//     dbg_en_eff = D11 开关 或 界面调试页 —— 后续所有"调试模式"门控统一用它。
dbg_tune_ctl u_dbg_ctl (
    .clk(clk), .rst_n(rst_n),
    .test_db(test_db), .key_level(key_level),
    .dbg_force(ui_dbg_req),
    .dbg_en(dbg_en), .sel_v(sel_v), .blink(dbg_blink));
wire dbg_en_eff = dbg_en | ui_dbg_req;

// 跨到 120MHz 音频域的慢速电平（2FF）
reg        dbgen_s0, dbgen_s1;
reg  [4:0] selv_s0, selv_s1;
always @(posedge clk_audio) begin
    dbgen_s0 <= dbg_en_eff; dbgen_s1 <= dbgen_s0;
    selv_s0  <= sel_v;    selv_s1  <= selv_s0;
end
wire        dbg_en_a = dbgen_s1;
wire [4:0]  sel_v_a  = selv_s1;

// 滑音使能：拉弦演奏模式（非调试）。此时 1 号滑轨 = 全局滑音：底端 = 本键基准音，
// 顶端 = 上行一个全音（滑到相邻下一段音，如 A3->B3、B3->C#4）；
// 其余状态（拨弦/调试）pitch_32v 内部自动回到底端比例，ch1 滑轨归 dbg_tune 调音调用。
wire        slide_act_a = mode_a & ~dbg_en_a;

// 5. 定弦音高表已移入 pitch_32v.v（见第 8a 节）：
//    拨弦 = 32 声部固定音（C3~F7 连续白键，音级 = v%7、八度 = 3 + v/7）；
//    拉弦 = 4 弦（G3 D4 A4 E5）x 每弦 8 段全音递进，铺满 v0..v31。
//    音高常量按 fs = 96kHz 的十二平均律计算（A4=440Hz）：inc = f × 2^32 / 96000。
//    fs 由 120MHz 音频域 + i2s_tx 小数分频决定：120MHz / 1250 拍 = 96000.00 Hz（精确）。

// 5b. ADC128S102 八通道 12bit SPI 模拟前端
//     六路滑轨 = 调试参数（ch1 音调 / ch2 响度 / ch3 A / ch4 D / ch5 R / ch6 泛音比例），
//     在 adc_cap 时刻快照给 dbg_tune；ch0/ch7 未使用。
//     注：ch1 复用——拉弦演奏模式（非调试）下兼作全局滑音（见 pitch_32v.v），
//     调试/拨弦时滑音自动回中，ch1 归调试专用。
wire [11:0] adc_c0, adc_c1, adc_c2, adc_c3, adc_c4, adc_c5, adc_c6, adc_c7;
wire [2:0]  adc_ch;
wire        adc_upd, adc_scan_done;
wire [95:0] adc_code_all;

adc128s102 u_adc (.clk(clk), .rst_n(rst_n),
    .adc_cs_n(adc_cs_n), .adc_sclk(adc_sclk), .adc_din(adc_din), .adc_dout(adc_dout),
    .adc_ch0(adc_c0), .adc_ch1(adc_c1), .adc_ch2(adc_c2), .adc_ch3(adc_c3),
    .adc_ch4(adc_c4), .adc_ch5(adc_c5), .adc_ch6(adc_c6), .adc_ch7(adc_c7),
    .cur_ch(adc_ch), .adc_upd(adc_upd), .scan_done(adc_scan_done));

// 码字打包：槽 k 的码值（已不参与音高，保留给面板/扩展用）。
// 槽 6 放 ch0 的码值，但 32 声部中不使用该槽；槽 7（ch7）数据无效。
assign adc_code_all = {adc_c7, adc_c0, adc_c6, adc_c5, adc_c4, adc_c3, adc_c2, adc_c1};
// 注：ch0 = 音量电位器（见下方 master_vol），ch1 = 拉弦滑音，ch2~ch7 未用。

// 总音量（Q15）：ADC088S022 CH0 电位器控制（VA=5V，8bit 数据左对齐 ×16 = 12bit 码，
//   码值 = V/VA×4096，满幅 3.3V ≈ 码 2703）。
//   音量电位器有效行程 0.6V~0.96V：
//     0.6V  -> 码 0.6/5×4096 ≈ 492（以下判静音死区）
//     0.96V -> 码 0.96/5×4096 ≈ 786（满幅 0dB = 32767）
//   行程内 span(0..294) ×7>>5（≈ /4.57）线性拉伸铺满 64 档，再查 64 档对数表
//   VOL_LOG：档 i -> -60dB×(1-i/63)，档 0=静音、档 63=0dB
//   （B 类线性电位器 -> 对数音频锥度：响度变化与拧动角度近似线性）。
localparam [11:0] VOL_ZERO = 12'd492;   // 0.6V 静音死区阈值
localparam [1023:0] VOL_LOG =
    1024'h7FFF72B466CB5C1E528D49FA424C3B69353E2FB62AC2265122561EC61B9318B6162513D911C90FF00E480CCD0B780A4709360841076606A105F1055304C5044703D5036F031402C20279023701FC01C70198016E01480126010700EC00D300BD00AA00980088007A006D00620058004F0047003F00390033002E002900250000;
wire [11:0] vol_span = (adc_c0 > VOL_ZERO) ? (adc_c0 - VOL_ZERO) : 12'd0;  // 0..294
wire [11:0] vol_sc   = vol_span * 3'd7;          // ×7 -> 0..2058
wire [6:0]  vol_idx7 = vol_sc[11:5];             // >>5 -> 0..64（64 钳到 63）
wire [5:0]  vol_idx  = (vol_idx7 > 7'd63) ? 6'd63 : vol_idx7[5:0];
wire [9:0]  vol_base = {vol_idx, 4'b0000};
wire [15:0] vol_log  = VOL_LOG[vol_base +: 16];
wire [15:0] master_vol = (adc_c0 < VOL_ZERO) ? 16'd0 : vol_log;

// 6. 弦音触发（32 声部）
// 触发源：3d 节两级 74HC4051D 32 通道扫描（边沿脉冲），外加 4b 节 D11 测试音键。
// 红外口径：遮挡 = 高→低 = key_press；恢复 = 低→高 = key_release。
// 触发沿（拨弦/拉弦相反）：
//   拨弦(mode=0)：只在【恢复】(低→高 = key_release) 发声，32 声部全开；
//   拉弦(mode=1)：只在【遮挡】(高→低 = key_press) 发声，【恢复】时停止
//                 （key_level 被拉低 -> ADSR 进 Release）；4 弦 x 8 段占满 v0..v31。
// 位序：note_on[v] / key_level[v] 对应声部 v = sub*8 + grp。
// 【调试模式】只放行当前选中声部的按键（其余静音）：短按选中键 = 试音（走正常触发
//   通路，拨弦=松开发声 / 拉弦=按住发声），长按其他键选音时不响，选音过程安静。
//   选中新键的瞬间旧选中键若还按住，其电平被同步截断 -> 拉弦会立即进 Release，无残留音。
wire [31:0] dbg_sel_bit  = 32'd1 << sel_v;
wire [31:0] trig_scan    = (mode ? key_press : key_release) &
                           (dbg_en_eff ? dbg_sel_bit : 32'hFFFF_FFFF);
// 【4 弦 x 8 段】拉弦 32 声部全部启用（BOW_MASK 全 1）；硬件 32 路扫描全接。
localparam [31:0] BOW_MASK = 32'hFFFF_FFFF;
wire [4:0]  test_v        = dbg_en_eff ? sel_v : (mode ? TEST_V_BOW : TEST_V_PLK);
wire [31:0] test_bit      = 32'd1 << test_v;
// note_on 必须是单拍脉冲（起振）；key_level 才是电平（拉弦保持/松键释放）。
wire [31:0] test_on_bit   = test_press ? test_bit : 32'd0;
wire [31:0] test_lvl_bit  = test_held  ? test_bit : 32'd0;
wire [31:0] note_on      = (mode ? (trig_scan & BOW_MASK) : trig_scan) | test_on_bit;
// ADSR 的 key_level：D11 按住时目标声部电平强制为"按下"（拉弦模式松键即进释放）；
//   调试模式下未选中声部的电平一并截断（与上面的触发门控一致）。
wire [31:0] key_level_eff = (dbg_en_eff ? (key_level & dbg_sel_bit) : key_level) | test_lvl_bit;

// 6b. 50MHz(外设) -> 120MHz(音频) 慢速控制信号同步
//   【必须放在第 7 节之前】本节产出的 mode_a / key_lvl_a /
//   note_on_a / master_vol_a / adc_cap 会被 ADSR / 引擎直接引用；
//   Verilog 的隐式网络规则要求"先声明后使用"，否则它们会被当成 1bit 无驱动线
//   （综合告警 EX1998），导致相关模块被优化掉。
//   音频合成链（ADSR / pitch_32v / vibrato / additive_engine）已统一到 120MHz 域，
//   原先"1024 位音高 + 512 位包络跨域握手快照"整块消失，只剩下外设域产生的慢速量：
//   · 开关/电位器类（mode / key_level / vib_en / vib_depth /
//     master_vol）：变化率远低于 1kHz，直接用 2FF 逐位同步即可。
//   · adc_code_all：ADC 八通道码字，一轮（约 139us）才更新一次，是"准静态总线"；
//     采样时刻由下面的 adc_cap 决定（往往比数据稳定点晚数十 ns，见下）。
//   · adc_scan_done 是 50MHz 单拍脉冲（20ns），若直接 2FF 同步有极小概率被漏采，
//     故改成"50MHz 域翻转位 + 120MHz 域 3FF + 边沿检测"，既不漏也不重。
wire [3:0] vib_depth;    // EC11 颤音深度（驱动实例在 8a 节，此处先声明供同步器使用）
wire       vib_en;       // EC11 轴按开关

reg [1:0] mode_s, viben_s;
always @(posedge clk_audio) begin
    mode_s  <= {mode_s[0],  mode};
    viben_s <= {viben_s[0], vib_en};
end
wire        mode_a      = mode_s [1];
wire        vib_en_a    = viben_s[1];

reg [3:0] depth_s;
always @(posedge clk_audio) depth_s <= {depth_s[2:0], vib_depth};
wire [3:0] vib_depth_a = depth_s[3:1];

reg [15:0] vol_s1, vol_s2;
always @(posedge clk_audio) begin
    vol_s1 <= master_vol;
    vol_s2 <= vol_s1;
end
wire [15:0] master_vol_a = vol_s2;

reg [31:0] klv_s1, klv_s2;
always @(posedge clk_audio) begin
    klv_s1 <= key_level_eff;
    klv_s2 <= klv_s1;
end
wire [31:0] key_lvl_a = klv_s2;

// note_on 是 50MHz 单周期脉冲（20ns），宽于 120MHz 周期（8.33ns），2FF 同步不会漏采。
// 引擎内部有 pend 锁存、ADSR 内部有 no_pend 锁存，1 拍有效即足够触发该声部重装。
reg [31:0] no_s0, no_s1;
always @(posedge clk_audio) begin
    no_s0 <= note_on;
    no_s1 <= no_s0;
end
wire [31:0] note_on_a = no_s1;

// ADC 一轮扫描完成：50MHz 域翻转位 -> 120MHz 域 3FF -> 取边沿
reg        adc_tog;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)             adc_tog <= 1'b0;
    else if(adc_scan_done) adc_tog <= ~adc_tog;
end
reg adc_t1, adc_t2, adc_t3;
always @(posedge clk_audio) begin
    adc_t1 <= adc_tog;
    adc_t2 <= adc_t1;
    adc_t3 <= adc_t2;
end
wire adc_cap = adc_t2 ^ adc_t3;      // 单拍脉冲：新一组 ADC 码字已稳定

// 【调试用滑轨】六路滑轨在 adc_cap 时刻一次性快照到 120MHz 域（数据在此刻稳定，
//   多 bit 采样安全），供 dbg_tune 计算参数偏移。码字中位 2048。
reg [11:0] dbg_adc1, dbg_adc2, dbg_adc3, dbg_adc4, dbg_adc5, dbg_adc6;
always @(posedge clk_audio) begin
    if(adc_cap) begin
        dbg_adc1 <= adc_c1;  dbg_adc2 <= adc_c2;  dbg_adc3 <= adc_c3;
        dbg_adc4 <= adc_c4;  dbg_adc5 <= adc_c5;  dbg_adc6 <= adc_c6;
    end
end

// 7. ADSR 包络（双模式：拨弦ADR / 拉弦ASR），32 路独立
//    【统一时钟】与音频引擎同在 120MHz 域，包络经串行写口直连引擎，不再有跨域快照。
//    帧脉冲改用音频域的 sample_en（120MHz/1250 拍 = 96kHz）。
wire [15:0] env_wdata;
wire [4:0]  env_waddr;
wire        env_we;
// 调试参数写口（dbg_tune 驱动）
wire [4:0]  dbg_prm_wa;
wire [19:0] dbg_prm_wd;
wire        dbg_prm_we;
wire        dbg_wrt_en;
wire [4:0]  dbg_wrt_v;
wire [17:0] dbg_wrt_ratio;
wire [8:0]  dbg_wgt_wa;
wire [15:0] dbg_wgt_wd;
wire        dbg_wgt_we;
wire [4:0]  dbg_lvl_wa;
wire [7:0]  dbg_lvl_wd;
wire        dbg_lvl_we;

adsr_32ch u_adsr (.clk(clk_audio), .rst_n(rst_n_aud), .sample_en(sample_en),
    .mode(mode_a), .ch_note_on(note_on_a), .ch_key_level(key_lvl_a),
    .prm_wa(dbg_prm_wa), .prm_wd(dbg_prm_wd), .prm_we(dbg_prm_we),
    .env_wdata(env_wdata), .env_waddr(env_waddr), .env_we(env_we));

// 【调试试音锁定】试音发声期间冻结滑轨参数载入（见 dbg_tune 的 Q_IDLE 门控）。
//   旁路 ADSR 串行写口取"选中声部"的包络幅度（每帧在 SC_WR 拍写一次，同域无跨域）；
//   幅度低于 -38dB（≈400，与 ADSR 内部噪声门 GATE_AMP 一致）即视为本次发声已结束
//   （含释放尾音，尾音衰减到该门限时 ADSR 正好回 IDLE 写 0），
//   此时才允许滑轨新值写入该声部参数槽。
localparam [15:0] DBG_HOLD_LVL = 16'd400;
reg  [15:0] dbg_amp_sel;
always @(posedge clk_audio or negedge rst_n_aud) begin
    if(!rst_n_aud) dbg_amp_sel <= 16'd0;
    else if(env_we && (env_waddr == sel_v_a)) dbg_amp_sel <= env_wdata;
end
wire dbg_sounding = (dbg_amp_sel > DBG_HOLD_LVL);

// 8a. EC11 旋转编码器 + 颤音调制
//    A/B 公共端 C 接 GND，轴按开关 E 接 GND、D 端外部 3V3 上拉。
//    三路均为"空闲=高、动作（转动/按下）=低"，与 ec11 内部假设一致，直接接入。
ec11 u_ec11 (.clk(clk), .rst_n(rst_n),
    .enc_a(enc_a), .enc_b(enc_b), .enc_sw(enc_sw),
    .depth(vib_depth), .vib_en(vib_en));

// 各声部基波步长（拨弦 32 固定音 / 拉弦 4 弦 x 8 段）：音高表与调试比例都在 pitch_32v.v。
//   调试模式：ch1 滑轨调选中声部的音调；拉弦演奏模式：ch1 滑轨 = 全局滑音
//   （底端 = 本键基准音，顶端 = 上行一个全音到相邻段音）；拨弦演奏不使用。
wire [1023:0] inc_pitch;
pitch_32v u_pitch (.clk(clk_audio), .rst_n(rst_n_aud),
    .mode(mode_a),
    .wrt_en(dbg_wrt_en), .wrt_v(dbg_wrt_v), .wrt_ratio(dbg_wrt_ratio),
    .slide_act(slide_act_a), .slide_code(dbg_adc1),
    .inc_all(inc_pitch));

// 颤音：inc_mod = inc_base × (1 ± dsig/65536)，32 声部共用同一相对频偏，音高百分比一致。
// 不按住开关 / 深度为 0 时 dsig=0，inc_mod 逐位等于 inc_pitch（纯直通）。
wire [1023:0] inc_mod;
vibrato u_vib (.clk(clk_audio), .rst_n(rst_n_aud), .sample_en(sample_en),
    .vib_en(vib_en_a), .depth(vib_depth_a), .inc_in(inc_pitch), .inc_out(inc_mod));

// 8b. 曲目指引 + 蓝牙（VG6328A 透传模块）在线下载
//   【节奏音游指引】只有拨弦模式有 LED 指引（拉弦模式的指示灯功能已按需求删除，
//   原版备份在 src_backup_20261019/）：进入指引后事件 0 的目标弦渐亮常驻（起始灯塔），
//   按下起始键后音序按谱时值自动推进——每个事件在点亮窗口内呼吸渐亮 0->100%
//   （上一灯到最大后自动跳下一事件，下一灯接力渐亮；时间到后无论是否按到正确键
//   都跳下一事件），曲终回到首灯循环等下一次按下。
//   指引只提示"该拨哪根弦"，不参与发声；发声仍由按键+ADC 决定。
//   预制 ROM 曲目 0/1 = 拨弦编曲（三和弦）、2/3 = 拉弦编曲（单音旋律，已无指引）。
//   注：旧板 6 颗 LED 已移除；新板改用 32 颗两级 74HC238D 矩阵 LED（见第 8b' 节），
//       song_player 的 guide_key0/1/2 + guide_n/guide_vld 已引出给 LED 直驱，跟随指引状态自动点亮。
//   面板曲目键已取消（key_song 引脚不再使用）：开/停指引由 F10 长按 1s~2.5s 负责，
//   切曲目由 F10 长按 2.5s 触发（见第 4 节）。
//   蓝牙：115200 8N1，手机 App 通过 GATT 写特征下发曲目事件帧，见 ble_link.v 头注释。
//   下载曲目事件为 24 位（至多 2 音混音、每槽最多 255 事件），FPGA 可存 3 首：
//   下载槽 0/1/2（BEGIN 帧指定槽号，第 4 首起由 App 端循环覆盖槽 0），见 song_ram.v / ble_link.v。
//   【透传桥模式】PC 调试 UART（G16/L9）经 FPGA 中转直连蓝牙模块（F15/H11）：
//     电脑串口助手发的字节 -> FPGA 原样转发给蓝牙模块；蓝牙模块的响应原样转发回电脑。
//     目的：不用拆线即可用电脑调试模块（发 AT 指令查名称/ROLE/波特率等）。
//     ble_link 曲目协议暂停（模块调通、手机能连上后再恢复手机控制）。
//   乒乓转发：收一字节即启动发送；两路同波特率(115200)，一收一发时序天然不冲突。

// ---- 正式方案：ble_link 曲目控制（模块接 F15/H11）----
// 透传桥调试已结束：G16 为硬件坏点（量到 0.27V，被外部拉低），PC 调试口放弃。
// H11 收模块串口字节 -> ble_link 收帧；ble_link 应答 -> u_bt_tx 发 F15。
// pc_tx 端口与约束保留备用；pc_rx（G16）改为输出 1kHz 方波验证硬件：
//   正常时万用表 Hz 档应读 ~1kHz；DC 档约 1.6V（3.3V 方波 50% 平均）。
//   若读数异常低或恒定不变，说明 G16 被外部电路拉低（板载占用/虚焊/断线）。
//   G16 方波与蓝牙链路（F15/H11）完全独立，不影响手机 App 验证。
reg [14:0] sq_cnt;
reg        sq_out;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sq_cnt <= 15'd0;
        sq_out <= 1'b0;
    end else if (sq_cnt == 15'd24999) begin   // 25000 拍 @50MHz = 0.5ms 半周期
        sq_cnt <= 15'd0;
        sq_out <= ~sq_out;                    // 翻转得 1kHz 方波
    end else begin
        sq_cnt <= sq_cnt + 15'd1;
    end
end
assign pc_rx = sq_out;
assign pc_tx = sq_out;   // L9 对照组：已知正常引脚与 G16 同输出方波，用于区分固件/测量与 G16 硬件问题

wire [7:0] bt_rx_data;
wire       bt_rx_valid;
wire [7:0] bt_tx_data;
wire       bt_tx_start;
wire       bt_tx_busy;
uart_rx u_bt_rx (.clk(clk), .rst_n(rst_n), .rx(bt_rx), .data(bt_rx_data), .valid(bt_rx_valid));
uart_tx u_bt_tx (.clk(clk), .rst_n(rst_n), .data(bt_tx_data), .start(bt_tx_start),
                 .tx(bt_tx), .busy(bt_tx_busy));

wire        ram_we;
wire [9:0]  ram_waddr;             // {下载槽[1:0], 槽内地址[7:0]}（3 槽 × 256）
wire        bl_song_vld, bl_stop, dl_busy;   // ble_link 的选曲/停止命令
wire [23:0] ram_wdata;
wire [2:0]  bl_song_id;
wire        cmd_song_vld, cmd_stop;          // 合并后送 song_ctl
wire [2:0]  cmd_song_id;
wire [2:0]  dl_ok;                 // 下载槽 0/1/2 的已成功下载占用位

// ---- 录制相关信号 ----
wire        rec_start, rec_stop;    // 蓝牙命令：开始/停止录制
wire        rec_busy;               // 录制中
wire [7:0]  rec_cnt;                // 已录事件数
wire        rec_mode;               // 录制固化的音色模式（rec_start 时锁存）
wire [23:0] rec_rdata;              // 录制 RAM 读数据（song_recorder 输出）
wire [7:0]  rec_ram_raddr;          // 录制 RAM 读地址（rec_reader 驱动）
// rec_reader：录制回读帧组装（独立模块，减轻 ble_link 布线压力）
wire [7:0]  rec_rd_b0, rec_rd_b1, rec_rd_b2,
            rec_rd_b3, rec_rd_b4, rec_rd_b5,
            rec_rd_b6, rec_rd_b7, rec_rd_b8;
wire [3:0]  rec_rd_len;
wire        rec_rd_valid;
wire        rec_rd_req;
wire [7:0]  rec_rd_idx;

wire        play_en, song_src;
wire [1:0]  preset_sel;
wire [1:0]  slot_sel;              // 下载槽号 0..2（曲目 4/5/6 -> 槽 0/1/2）
wire        song_load;

ble_link u_link (.clk(clk), .rst_n(rst_n),
    .rx_data(bt_rx_data), .rx_valid(bt_rx_valid),
    .tx_data(bt_tx_data), .tx_start(bt_tx_start), .tx_busy(bt_tx_busy),
    .ram_we(ram_we), .ram_waddr(ram_waddr), .ram_wdata(ram_wdata),
    .cmd_song_vld(bl_song_vld), .cmd_song_id(bl_song_id), .cmd_stop(bl_stop),
    .dl_ok(dl_ok), .dl_busy(dl_busy), .play_en(play_en),
    .rec_start(rec_start), .rec_stop(rec_stop),
    .rec_busy(rec_busy), .rec_cnt(rec_cnt), .rec_mode(rec_mode),
    .rec_rd_req(rec_rd_req), .rec_rd_idx(rec_rd_idx),
    .rec_rd_b0(rec_rd_b0), .rec_rd_b1(rec_rd_b1), .rec_rd_b2(rec_rd_b2),
    .rec_rd_b3(rec_rd_b3), .rec_rd_b4(rec_rd_b4), .rec_rd_b5(rec_rd_b5),
    .rec_rd_b6(rec_rd_b6), .rec_rd_b7(rec_rd_b7), .rec_rd_b8(rec_rd_b8),
    .rec_rd_len(rec_rd_len), .rec_rd_valid(rec_rd_valid));

// 选曲命令二选一：蓝牙 App 下发 或 LCD 曲目目录（song_start/song_stop）
//   两路都是单拍脉冲，实际不会同时出现；蓝牙优先。
assign cmd_song_vld = bl_song_vld | ui_song_start;
assign cmd_song_id  = bl_song_vld ? bl_song_id : {1'b0, ui_song_idx};
assign cmd_stop     = bl_stop | ui_song_stop;

song_ctl u_song_ctl (.clk(clk), .rst_n(rst_n),
    .key_press(f10_hold), .song_next(f10_long),
    .cmd_song_vld(cmd_song_vld), .cmd_song_id(cmd_song_id), .cmd_stop(cmd_stop),
    .dl_busy(dl_busy),
    .play_en(play_en), .song_src(song_src), .preset_sel(preset_sel),
    .slot_sel(slot_sel), .song_load(song_load));

wire [9:0]  rom_addr;
wire [9:0]  ram_addr;               // 下载 RAM 地址 {槽号[1:0], 槽内序号[7:0]}（3 槽 × 256）
wire [31:0] rom_dout, ev_data;   // 预制 ROM 新格式：32 位事件（至多 3 音和声）
wire [23:0] ram_dout;            // 下载 RAM：24 位事件（至多 2 音混音，255 槽）
wire [4:0]  guide_key0, guide_key1, guide_key2;  // 指引目标弦 0..2（和声事件至多 3 根）
wire [1:0]  guide_n;             // 指引目标弦数 1..3
wire        guide_vld;           // 指引有效：1 = 目标弦待弹（LED 点亮窗口）
//   这两个是纯组合的叶子模块，若不保留层次，Gowin 优化时会把它们展开并报
//   WARN (NL0002) "is swept in optimizing"（逻辑其实还在，只是丢了模块名）。
//   用 syn_noprune 属性要求保留这两个例化，消除该告警。
(* syn_noprune = 1 *) song_rom u_song_rom (.addr(rom_addr), .data(rom_dout));
song_ram u_song_ram (.clk(clk), .we(ram_we), .waddr(ram_waddr), .wdata(ram_wdata),
                     .raddr(ram_addr), .rdata(ram_dout));
assign ev_data = song_src ? {8'h00, ram_dout} : rom_dout;   // 下载曲目高位补零（24 位事件）

// 【节奏音游指引（实际接线）】只有拨弦模式有 LED 指引：
//   play_en_guide 在拉弦模式下强制关断（拉弦模式的指示灯功能已按需求删除，
//   原版备份在 src_backup_20261019/）。播放行为见 song_player.v 头注释：
//   事件窗口内指引灯立刻切到目标弦（最多 3 个和声），按 3 相轮转固定 33% 亮度；
//   按下正确键或时间到都跳下一事件；曲终回到首灯循环。
wire play_en_guide = play_en & ~mode;

song_player u_song_pl (.clk(clk), .rst_n(rst_n), .song_load(song_load),
    .play_en(play_en_guide), .song_src(song_src), .preset_sel(preset_sel),
    .slot(slot_sel), .ev_data(ev_data), .note_lvl(key_level_eff),
    .rom_addr(rom_addr), .ram_addr(ram_addr),
    .guide_key0(guide_key0), .guide_key1(guide_key1), .guide_key2(guide_key2),
    .guide_n(guide_n), .guide_vld(guide_vld));

// 8b''. 录制引擎：记录用户弹奏的按键事件（时间差 + 弦号）到录制 RAM
//   由 APP 通过蓝牙 REC_START/REC_STOP 控制启停，REC_QUERY 查询事件数，
//   REC_READ 上传数据（格式与下载曲目一致，可直接当乐谱回放）。
song_recorder u_song_rec (.clk(clk), .rst_n(rst_n),
    .rec_start(rec_start), .rec_stop(rec_stop),
    .note_lvl(key_level_eff),
    .mode_sel(mode),
    .rec_busy(rec_busy), .rec_cnt(rec_cnt), .rec_mode(rec_mode),
    .ram_we(), .ram_waddr(), .ram_wdata(),     // 写口内部用，顶层不接
    .ram_raddr(rec_ram_raddr), .ram_rdata(rec_rdata));

// 录制回读引擎：独立模块做 RAM 读 + 帧组装，减轻 ble_link 布线压力
rec_reader u_rec_reader (.clk(clk), .rst_n(rst_n),
    .rd_req(rec_rd_req), .rd_idx(rec_rd_idx),
    .ram_rdata(rec_rdata), .ram_raddr(rec_ram_raddr),
    .rd_byte0(rec_rd_b0), .rd_byte1(rec_rd_b1), .rd_byte2(rec_rd_b2),
    .rd_byte3(rec_rd_b3), .rd_byte4(rec_rd_b4), .rd_byte5(rec_rd_b5),
    .rd_byte6(rec_rd_b6), .rd_byte7(rec_rd_b7), .rd_byte8(rec_rd_b8),
    .rd_len(rec_rd_len), .rd_valid(rec_rd_valid));

// 8b'. 曲目指引 LED / 演奏跟随：32 颗 = 两级 74HC238D 矩阵（一级选列/二级选行）
//   硬件限制：同刻只能亮 1 颗，靠 3 相轮转实现"多颗同时亮"的人眼暂留效果。
//   统一策略：所有场景任何时刻每颗有效灯固定 ~33% 亮度 —— 单音不增亮、三音不减暗。
//   三种行为模式（优先级自上而下）：
//     ① 调试模式：选中声部 1Hz 闪烁（dbg_en_eff=1 时）
//     ② 指引模式（play_en_guide=1）：song_player 给出的 1~3 个目标弦立刻切换点亮，
//       无任何呼吸/延迟/渐亮，窗口 (guide_vld=1) 结束立即熄灭并跳转下一事件。
//     ③ 演奏跟随（默认）：从 note_on（触发脉冲）入队 FIFO，最多保留最近 3 根；
//       第 4 根触发自动顶掉最早的（FIFO 出队）；key_level=0（松键/声音结束）立即释放对应槽。
//   引脚：一级使能 A11、一级地址 A15/B11/C12（选列）、二级地址 A14/E14/D15（选行，常开）。
//   灯位编号：灯 v = 列号×8 + 行号（与 32 弦通道编号一致）；指引覆盖 v0~v31 全部 32 弦。
//   【组内反序】每组 8 颗灯的实际接线是 Y7..Y0 反向，二级地址取反（见 led_ad2）。
//   【F10 总开关】指引只在 play_en_guide（拨弦模式）点亮；拉弦/指引外状态走演奏跟随。
localparam  LED_E1_ACT = 1'b1;   // 一级使能高有效【用户实测确认：A11 接 E3】
// 注：早前"32 颗全微亮"并非 A11 低有效，勿再改回 0——静态直驱下 E1_ACT=0 会使
//   A11 在有指引时恒 0，一级被禁、Y 无输出，二级失去使能而全灭。
// ---- 统一 3 相轮转：每相固定 ~33% 占空，所有时刻所有灯亮度一致 ----
//   硬件限制：两级 74HC238 矩阵同刻只能亮 1 颗；最多同时有效 3 颗，每颗 33% 亮度。
//   四相计数器只用 0/1/2 三相（第 4 相空转 = 全灭，不影响亮度统计）。
reg [9:0]  led_ph_cnt;              // 50MHz 自由计数
wire [1:0] led_ph = led_ph_cnt[9:8];// 每相 256 拍 = 5.12us，三相有效周期 ≈ 15.36us / 65kHz
always @(posedge clk) led_ph_cnt <= led_ph_cnt + 10'd1;

// ===================== 指引模式（立刻切换，无呼吸）=====================
wire [4:0] guide_key_f = (led_ph == 2'd0) ? guide_key0 :
                         (led_ph == 2'd1) ? guide_key1 : guide_key2;
wire       guide_on_f  = (led_ph == 2'd0) ? (guide_n >= 2'd1) :
                         (led_ph == 2'd1) ? (guide_n >= 2'd2) : (guide_n >= 2'd3);

// ===================== 演奏跟随 FIFO（最多 3 根，按触发顺序排队）=====================
//   - note_on[v]（单拍触发脉冲）入队；新触发若已在队列则移到最新槽，不在则进最新槽。
//   - 槽满（3 个都 valid）时最早的（槽 0）自动出队丢弃。
//   - 释放策略（两种模式）：
//       · 拉弦 mode=1 ：key_level[v]=0（松键/声音结束）立即释放；加 2s 超时双保险
//       · 拨弦 mode=0 ：key_level 松键后立即归零（松键触发发声），忽略；靠 2s 超时释放
//     每个槽带 11bit 超时计数器（1ms tick, 2047ms 上限），满 2000ms 自动清 valid。
//   - 扫描写：3 相轮转，每相对应一个槽，valid=1 才亮 → 每颗灯固定 33% 占空。
wire       follow_en = ~dbg_en_eff & ~play_en_guide;
reg [4:0]  fifo_k0, fifo_k1, fifo_k2;   // 3 个槽存弦号
reg        fifo_v0, fifo_v1, fifo_v2;   // 槽 valid（1=有效）
reg [10:0] fifo_t0, fifo_t1, fifo_t2;   // 槽超时计数（ms），0 刚入队，≥2000 清 valid

// 1ms tick 发生器（50MHz）
reg [18:0] ft_tick;
wire       ft_1ms = (ft_tick == 19'd49_999);
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) ft_tick <= 19'd0;
    else if (ft_1ms) ft_tick <= 19'd0;
    else             ft_tick <= ft_tick + 19'd1;
end

// 扫描 note_on 找最低位触发的弦（单拍最多处理 1 根，多根下一拍依次入队）
wire [4:0] trg_v =
    note_on [0]  ? 5'd0  : note_on [1]  ? 5'd1  : note_on [2]  ? 5'd2  : note_on [3]  ? 5'd3  :
    note_on [4]  ? 5'd4  : note_on [5]  ? 5'd5  : note_on [6]  ? 5'd6  : note_on [7]  ? 5'd7  :
    note_on [8]  ? 5'd8  : note_on [9]  ? 5'd9  : note_on [10] ? 5'd10 : note_on [11] ? 5'd11 :
    note_on [12] ? 5'd12 : note_on [13] ? 5'd13 : note_on [14] ? 5'd14 : note_on [15] ? 5'd15 :
    note_on [16] ? 5'd16 : note_on [17] ? 5'd17 : note_on [18] ? 5'd18 : note_on [19] ? 5'd19 :
    note_on [20] ? 5'd20 : note_on [21] ? 5'd21 : note_on [22] ? 5'd22 : note_on [23] ? 5'd23 :
    note_on [24] ? 5'd24 : note_on [25] ? 5'd25 : note_on [26] ? 5'd26 : note_on [27] ? 5'd27 :
    note_on [28] ? 5'd28 : note_on [29] ? 5'd29 : note_on [30] ? 5'd30 : note_on [31] ? 5'd31 : 5'd0;
wire       trg_found = |note_on;

// FIFO 更新：入队（note_on） + 释放 + 压缩前移 + 超时计数
// —— 第 1 段：k/v 组合更新。释放策略直接门控（与上一版已验证形式一致）：
//       · 拉弦 mode=1 ：valid = fifo_v & key_level[k]  （按住亮、松键灭）
//       · 拨弦 mode=0 ：valid = fifo_v & (t < 2000)      （2s 超时自动灭，忽略 key_level）
reg [4:0]  nk0, nk1, nk2;
reg        nv0, nv1, nv2;
always @(*) begin
    nk0 = fifo_k0; nv0 = fifo_v0 & (mode ? key_level[fifo_k0] : (fifo_t0 < 11'd2000));
    nk1 = fifo_k1; nv1 = fifo_v1 & (mode ? key_level[fifo_k1] : (fifo_t1 < 11'd2000));
    nk2 = fifo_k2; nv2 = fifo_v2 & (mode ? key_level[fifo_k2] : (fifo_t2 < 11'd2000));

    // 压缩前移：把 valid 槽挪到最前，空位留末尾
    if (nv0 && !nv1) begin nk1 = nk2; nv1 = nv2; nk2 = 5'd0; nv2 = 1'b0; end
    if (!nv0 && nv1) begin nk0 = nk1; nv0 = 1'b1;
                          nk1 = nv2 ? nk2 : 5'd0; nv1 = nv2;
                          nk2 = 5'd0; nv2 = 1'b0; end
    if (!nv0 && !nv1 && nv2) begin nk0 = nk2; nv0 = 1'b1; nk2 = 5'd0; nv2 = 1'b0; end

    // 入队：trg_v 不在队列则进最新槽；已在队列则移到槽 2（刷新为最新）
    if (trg_found) begin
        if ((trg_v == nk0 && nv0) || (trg_v == nk1 && nv1) || (trg_v == nk2 && nv2)) begin
            if (trg_v == nk0 && nv0) begin
                nv0 = nv1; nk0 = nk1; nv1 = nv2; nk1 = nk2;
                nv2 = 1'b1; nk2 = trg_v;
            end else if (trg_v == nk1 && nv1) begin
                nv1 = nv2; nk1 = nk2;
                nv2 = 1'b1; nk2 = trg_v;
            end else begin
                nv2 = 1'b1; nk2 = trg_v;
            end
        end else begin
            if (nv0 && nv1 && nv2) begin
                nv0 = nv1; nk0 = nk1; nv1 = nv2; nk1 = nk2; nv2 = 1'b1; nk2 = trg_v;
            end else if (nv0 && nv1) begin
                nv2 = 1'b1; nk2 = trg_v;
            end else if (nv0) begin
                nv1 = 1'b1; nk1 = trg_v;
            end else begin
                nv0 = 1'b1; nk0 = trg_v;
            end
        end
    end
end

// —— 第 2 段：超时计数器更新（跟随压缩后的 v/k）
//   每 1ms tick 加 1；被释放的槽计数回 0；入队/刷新为最新的槽强制清零。
reg [10:0] nt0, nt1, nt2;
always @(*) begin
    nt0 = nv0 ? (ft_1ms ? fifo_t0 + 11'd1 : fifo_t0) : 11'd0;
    nt1 = nv1 ? (ft_1ms ? fifo_t1 + 11'd1 : fifo_t1) : 11'd0;
    nt2 = nv2 ? (ft_1ms ? fifo_t2 + 11'd1 : fifo_t2) : 11'd0;
    if (trg_found) begin
        if (nv2 && nk2 == trg_v) nt2 = 11'd0;
        else if (nv1 && nk1 == trg_v) nt1 = 11'd0;
        else if (nv0 && nk0 == trg_v) nt0 = 11'd0;
    end
end

// —— 第 3 段：时序写回
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fifo_k0 <= 5'd0; fifo_k1 <= 5'd0; fifo_k2 <= 5'd0;
        fifo_v0 <= 1'b0; fifo_v1 <= 1'b0; fifo_v2 <= 1'b0;
        fifo_t0 <= 11'd0; fifo_t1 <= 11'd0; fifo_t2 <= 11'd0;
    end else begin
        fifo_k0 <= nk0; fifo_k1 <= nk1; fifo_k2 <= nk2;
        fifo_v0 <= nv0; fifo_v1 <= nv1; fifo_v2 <= nv2;
        fifo_t0 <= nt0; fifo_t1 <= nt1; fifo_t2 <= nt2;
    end
end

wire [4:0] follow_key = (led_ph == 2'd0) ? fifo_k0 :
                        (led_ph == 2'd1) ? fifo_k1 : fifo_k2;
wire       follow_on  = (led_ph == 2'd0) ? fifo_v0 :
                        (led_ph == 2'd1) ? fifo_v1 : fifo_v2;

// ===================== 最终灯号选择 =====================
wire [4:0] led_key_f = dbg_en_eff ? sel_v :
                       play_en_guide ? guide_key_f :
                       follow_en    ? follow_key : 5'd0;
wire       led_on_f  = dbg_en_eff ? 1'b1 :
                       play_en_guide ? guide_on_f :
                       follow_en    ? follow_on : 1'b0;
assign led_ad1 = {1'b0, led_key_f[4:3]};  // 列号 = 弦号高2位(0..3)
assign led_ad2 = 3'b111 - led_key_f[2:0]; // 组内颠倒：v0→行7, v7→行0（每 8 弦一组）

// ===================== LED 使能 =====================
// 优先级：dbg(1Hz闪烁) > guide(指引) > follow(演奏跟随)；其余全灭。
// 指引需同时满足 play_en_guide + guide_vld 窗口内（过渡拍自动不亮）。
wire led_glow = dbg_en_eff ? dbg_blink :
                play_en_guide ? (guide_vld & led_on_f) :
                follow_en    ? led_on_f : 1'b0;
assign led_en1 = LED_E1_ACT ? led_glow : ~led_glow;

// 9. 32 声部 x 16 泛音加法合成引擎（120MHz 音频域）
//    每帧 1250 拍（96kHz），引擎实际约 570 拍，余量充裕，无需并行硬件振荡器。
//    2 个共享 18x18 DSP：DSP-A 做 512 次（正弦 × 泛音包络），
//    DSP-B 做 32 次（声部波形 × 主 ADSR 包络）+ 总音量 2 次乘法。
wire signed [23:0] mix;
additive_engine #(.SHV(5'd9)) u_engine (   // SHV=9：单声部约 2.0M，3 键≈6.1M < 24bit 满幅 8.39M，
                                           // 保证 3 键同时发声不削顶（此前 SHV=8 两键即削波爆音）
    .clk(clk_audio), .rst_n(rst_n_aud), .sample_en(sample_en),
    .mode(mode_a), .inc_all(inc_mod), .note_on(note_on_a),
    .env_wdata(env_wdata), .env_waddr(env_waddr), .env_we(env_we),
    .wgt_wa(dbg_wgt_wa), .wgt_wd(dbg_wgt_wd), .wgt_we(dbg_wgt_we),
    .lvl_wa(dbg_lvl_wa), .lvl_wd(dbg_lvl_wd), .lvl_we(dbg_lvl_we),
    .master_vol(master_vol_a), .mix(mix));

// 9b. 音色调试参数派生（120MHz）：六路滑轨 -> 选中声部的音调/响度/A/D/R/泛音比例
dbg_tune u_dbg_tune (
    .clk(clk_audio), .rst_n(rst_n_aud),
    .mode(mode_a), .dbg_en(dbg_en_a), .sel_v(sel_v_a), .dbg_hold(dbg_sounding),
    .adc1(dbg_adc1), .adc2(dbg_adc2), .adc3(dbg_adc3),
    .adc4(dbg_adc4), .adc5(dbg_adc5), .adc6(dbg_adc6),
    .wrt_en(dbg_wrt_en), .wrt_v(dbg_wrt_v), .wrt_ratio(dbg_wrt_ratio),
    .prm_wa(dbg_prm_wa), .prm_wd(dbg_prm_wd), .prm_we(dbg_prm_we),
    .wgt_wa(dbg_wgt_wa), .wgt_wd(dbg_wgt_wd), .wgt_we(dbg_wgt_we),
    .lvl_wa(dbg_lvl_wa), .lvl_wd(dbg_lvl_wd), .lvl_we(dbg_lvl_we));

// 10. 旧的 pROM/prom_scan32/mul18_arb/8×string_4partial/audio_mixer 已整体删除，
//     由第 9 节的 additive_engine（32 声部 x 16 泛音）取代。

// 11. I2S 发送器（音频域 120MHz，小数分频精确输出 96kHz）
//     混音结果已在 120MHz 域产生（第 9 节引擎），直接送 I2S，无需跨域同步。
//     i2s_tx 每帧末（右声道发完）产生 sample_en —— 它同时是引擎的帧起始脉冲；
//     引擎在下一帧 sample_en 之前（约 570 拍 << 1250 拍）更新 mix，时序充裕。
wire bclk, lrclk, dout;
i2s_tx u_i2s (.clk(clk_audio), .rst_n(rst_n_aud), .sample_l(mix), .sample_r(mix),
    .bclk(bclk), .lrclk(lrclk), .dout(dout), .sample_en(sample_en));
assign hp_bck = bclk;
assign hp_ws  = lrclk;
assign hp_din = dout;
// assign pa_en  = 1'b1;    // MAX98357A SD 脚不接，pa_en 端口已移除

// 12. 板载 40P FPC RGB565 LCD（480x272 / SYNC-DE）
//     pclk：50MHz -> 10MHz（gowin_rpll.v：IDIV=4 / FBDIV=0 / ODIV=64），
//     帧率 10MHz/(510 x 287) ≈ 68.3Hz。lcd_rgb 内部不再自带 PLL。
wire pclk;
Gowin_rPLL u_lcdpll (.clkin(clk), .clkout(pclk));
assign lcd_en = 1'b1;

// 李萨如 X/Y 信号源（音频域）：取当前按下的最小/次小两个声部，
// 用 pitch_32v 的同一条基波步长 inc_mod 推进相位，保证图形频率与真实发声一致。
wire signed [15:0] lis_a, lis_b;
wire [2:0]         lis_pa, lis_pb;
wire               lis_vld;
vis_pair_src u_vps (
    .clk(clk_audio), .rst_n(rst_n_aud), .sample_en(sample_en),
    .key_lvl(key_lvl_a), .inc_all(inc_mod),
    .osc_a(lis_a), .osc_b(lis_b),
    .pair_a(lis_pa), .pair_b(lis_pb), .lis_valid(lis_vld));

lcd_rgb u_lcd (
    .clk(clk_audio), .rst_n(rst_n), .sample_en(sample_en), .mix(mix),
    .osc_a(lis_a), .osc_b(lis_b),
    .pair_a(lis_pa), .pair_b(lis_pb), .lis_valid(lis_vld),
    .page(ui_page), .pclk(pclk),
    // 中文界面（50MHz 域准静态）：屏幕号/光标/乐器/选中声部/六路滑轨原码
    .ui_scr(ui_scr), .ui_cur(ui_cur), .ui_instr(mode), .ui_sel_v(sel_v),
    .ui_adc1(adc_c1), .ui_adc2(adc_c2), .ui_adc3(adc_c3),
    .ui_adc4(adc_c4), .ui_adc5(adc_c5), .ui_adc6(adc_c6),
    .lcd_clk(lcd_clk), .lcd_de(lcd_de),
    .lcd_b(lcd_b), .lcd_r(lcd_r), .lcd_g(lcd_g));

endmodule

// ============================================================================
// ui_ok_ctl - M7（确定键）短按 / 长按判定
//   按住 <1s 松开   -> short_press（确定）
//   按住 >=1s 到点  -> long_press（立刻退回初始界面），本按次内锁定，
//                      此后松开不再补发 short_press。
// ============================================================================
module ui_ok_ctl (
    input  wire clk,
    input  wire rst_n,
    input  wire key_down,      // 1 = 按住
    output reg  short_press,
    output reg  long_press
);
    localparam [25:0] LONG_CNT = 26'd50_000_000;   // 1.0s @50MHz

    reg key_q;                  // 上一拍电平（松沿检测）
    reg [25:0] press_timer;     // 本次按住时长（到 LONG_CNT 即停计）
    reg        fired_long;      // 长按已触发（本按次内锁定，松开即复位）

    wire release_edge = key_q & ~key_down;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_q       <= 1'b0;
            press_timer <= 26'd0;
            fired_long  <= 1'b0;
            short_press <= 1'b0;
            long_press  <= 1'b0;
        end else begin
            key_q       <= key_down;
            short_press <= 1'b0;
            long_press  <= 1'b0;

            if (!key_down) begin
                press_timer <= 26'd0;
                fired_long  <= 1'b0;
            end else if (press_timer < LONG_CNT) begin
                press_timer <= press_timer + 26'd1;
            end

            if (key_down && !fired_long && (press_timer == LONG_CNT)) begin
                long_press <= 1'b1;
                fired_long <= 1'b1;
            end

            if (release_edge && !fired_long && (press_timer < LONG_CNT))
                short_press <= 1'b1;
        end
    end
endmodule

// ============================================================================
// f10_ctl - F10 三手势控制（单击 / 长按1s指引 / 长按2.5s切曲，区间互斥）
// 内联于顶层末尾：独立文件版本需 IDE 手动维护工程文件列表，综合时不会被自动
// 收录（实测 EX3937 未知模块），故直接并入 tone_gen_top.v，保证任何工具链下
// 都能被综合。
//   松开时按"按住时长"落区间，一次按压只落一个：
//     时长 < 1s            -> single_click：拨弦/拉弦切换
//     1s <= 时长 < 2.5s    -> hold_guide  ：曲目指引开/停
//     时长 >= 2.5s         -> long_press  ：切下一首预制曲目
// 判定互斥规则：
//   1) 按住满 2.5s 当拍触发 long_press 并锁定（fired_long），此后松开不再产生
//      任何手势（不会在松开时补发 hold_guide）；
//   2) 未锁定前松开，按按住时长落前两个区间（<1s 切音色、1s~2.5s 指引开/停）。
//   长按 1s 开指引与长按 2.5s 切曲分属不同区间，天然不冲突，无需额外互斥。
// 输入 key_down = 消抖后电平（1 = 按住）。三个输出均为 50MHz 单拍脉冲。
// ============================================================================
module f10_ctl (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       key_down,
    output reg        single_click,
    output reg        hold_guide,
    output reg        long_press
);
    localparam [26:0] LONG_CNT = 27'd125_000_000;   // 2.5s @50MHz（切曲阈值）
    localparam [25:0] HOLD_CNT = 26'd50_000_000;    // 1.0s @50MHz（指引阈值）

    reg key_q;                  // 上一拍电平（松沿检测）
    reg [26:0] press_timer;     // 本次按住时长（到 LONG_CNT 即停计）
    reg        fired_long;      // 长按已触发（本按次内锁定，松开即复位）

    wire release_edge = key_q & ~key_down;   // 松开沿

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_q        <= 1'b0;
            press_timer  <= 27'd0;
            fired_long   <= 1'b0;
            single_click <= 1'b0;
            hold_guide   <= 1'b0;
            long_press   <= 1'b0;
        end else begin
            key_q <= key_down;
            single_click <= 1'b0;
            hold_guide   <= 1'b0;
            long_press   <= 1'b0;

            // ---- 按住计时（到 2.5s 停计）----
            if (!key_down) begin
                press_timer <= 27'd0;
                fired_long  <= 1'b0;
            end else if (press_timer < LONG_CNT) begin
                press_timer <= press_timer + 27'd1;
            end

            // ---- 长按 2.5s 到点：切曲并锁定，此后松开不落其他手势 ----
            if (key_down && !fired_long && (press_timer == LONG_CNT)) begin
                long_press <= 1'b1;
                fired_long <= 1'b1;
            end

            // ---- 松开沿：按按住时长落区间（长按锁定后不参与）----
            if (release_edge && !fired_long) begin
                if (press_timer < HOLD_CNT) single_click <= 1'b1;   // <1s    ：切音色
                else                        hold_guide   <= 1'b1;   // 1s~2.5s：指引开/停
            end
        end
    end
endmodule
