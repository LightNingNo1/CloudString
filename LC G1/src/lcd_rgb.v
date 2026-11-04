// ============================================================================
// lcd_rgb.v - 板载 40P FPC 屏驱动（480x272 / RGB565 / SYNC-DE）
// ----------------------------------------------------------------------------
// 分页显示（page 由顶层 UI 给出）：
//   page 0 WAVE ：最终合成波形示波器，480 列逐点（窗口 480 采样 = 5ms @96kHz，
//                 过零上升沿触发锁定，音高不变时波形静止，详见 vis_scope.v）
//   page 1 SPEC ：64 柱实时频谱（sign-DFT，188Hz/柱 @96kHz），7px/柱全宽
//   page 2 LISSA：当前按下的两根弦（和音）的李萨如图，128x128 位图放大 2 倍；
//                 仅当至少两根弦按下（lis_valid=1）时显示，否则空白边框
//
// 音频数据来自音频域(clk=120MHz, sample_en=96kHz)，像素侧为顶层 PLL 产生的
// 10MHz pclk，跨时钟域用"帧消隐翻转 + RAM 双时钟"：
//   每帧最后一个消隐 pclk（hcnt,vcnt 末点）翻转 grab_tog，同步到音频域后
//   在下一个 sample_en 产生 gpls：
//     - 示波器冻结环形 RAM 读指针；
//     - 频谱清零并采 512 点（5.3ms）算幅度，幅值双缓冲，屏始终读上一帧；
//     - 李萨如清零 128 行后打 384 个点（4ms）。
//
// 渲染流水：T0 按 (vx,vy) 组合出三块 RAM 地址；T1 拿到示波器/频谱数据；
//   T2 李萨如像素到齐（其内部 2 拍），统一在 T2 组合着色，T3 输出寄存。
//
// 像素时钟 10MHz，刷新率 10MHz/(510×287)≈68.3Hz。
// 【移植说明】原文件内部自带 27MHz->9MHz 的 Gowin_rPLL；本工程 pclk 由顶层
//   50MHz 域的 Gowin_rPLL（50->10MHz）产生后从这里输入，故删除内部 PLL；
//   蓝通道按本板 5bit（原 4bit）输出；lcd_en 由顶层常高。
// ============================================================================
module lcd_rgb (
    input  wire               clk,        // 音频域 120MHz
    input  wire               rst_n,
    input  wire               sample_en,  // 96kHz 音频采样脉冲
    input  wire signed [23:0] mix,        // 最终合成混音（限幅后 24bit）
    input  wire signed [15:0] osc_a,      // 李萨如 X：和音中较低弦
    input  wire signed [15:0] osc_b,      // 李萨如 Y：和音中较高弦
    input  wire [2:0]         pair_a,     // 弦对编号 a（仅标签用）
    input  wire [2:0]         pair_b,     // 弦对编号 b
    input  wire               lis_valid,  // 至少两根弦按下（李萨如页有效）
    input  wire [1:0]         page,       // 显示页 0/1/2；3 = 中文界面（不画图形）
    input  wire               pclk,       // 像素时钟（10MHz，顶层 PLL 产生）
    // ---- 中文界面（50MHz 域，准静态）----
    input  wire [2:0]         ui_scr,     // 屏幕号（0..7，7 为示波页）
    input  wire [2:0]         ui_cur,     // 菜单光标
    input  wire               ui_instr,   // 0 竖琴 / 1 小提琴
    input  wire [4:0]         ui_sel_v,   // 调试选中声部
    input  wire [11:0]        ui_adc1, ui_adc2, ui_adc3,
    input  wire [11:0]        ui_adc4, ui_adc5, ui_adc6,
    output wire               lcd_clk,
    output wire               lcd_de,
    output wire [4:0]         lcd_b,
    output wire [4:0]         lcd_r,
    output wire [5:0]         lcd_g
);
    assign lcd_clk = pclk;

    // 消隐期加长（SYNC-DE 屏对消隐有最低要求，之前压缩过头导致整屏黑屏）
    // 10MHz 下 H_TOTAL=540, V_TOTAL=312 → 帧率 ≈ 59Hz
    localparam [15:0] H_VALID = 16'd480, H_BP = 16'd30, H_FP = 16'd30;
    localparam [15:0] V_VALID = 16'd272, V_BP = 16'd20, V_FP = 16'd20;
    localparam [15:0] H_TOTAL = H_VALID + H_BP + H_FP;   // 540
    localparam [15:0] V_TOTAL = V_VALID + V_BP + V_FP;   // 312

    reg [15:0] hcnt, vcnt;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= 16'd0;
            vcnt <= 16'd0;
        end else if (hcnt == H_TOTAL - 16'd1) begin
            hcnt <= 16'd0;
            vcnt <= (vcnt == V_TOTAL - 16'd1) ? 16'd0 : (vcnt + 16'd1);
        end else begin
            hcnt <= hcnt + 16'd1;
        end
    end

    wire de = (hcnt >= H_BP) && (hcnt < H_BP + H_VALID) &&
              (vcnt >= V_BP) && (vcnt < V_BP + V_VALID);

    // ============================ 跨时钟域采集 ============================
    // pclk 帧末翻转 -> 27MHz 两级同步 -> 下一个 sample_en 发 gpls
    reg grab_tog;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n)
            grab_tog <= 1'b0;
        else if ((hcnt == H_TOTAL - 16'd1) && (vcnt == V_TOTAL - 16'd1))
            grab_tog <= ~grab_tog;
    end

    reg g1, g2, g3, g_seen;
    reg gpls;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g1 <= 1'b0; g2 <= 1'b0; g3 <= 1'b0;
            g_seen <= 1'b0; gpls <= 1'b0;
        end else begin
            g1 <= grab_tog; g2 <= g1; g3 <= g2;
            gpls <= 1'b0;
            if (sample_en && (g3 != g_seen)) begin
                g_seen <= g3;
                gpls   <= 1'b1;
            end
        end
    end

    // 弦对编号 / 有效标志 / 页号同步进像素域（准静态，两级同步即可）
    reg [2:0] pa_s1, pa_s2, pb_s1, pb_s2;
    reg       lv_s1, lv_s2;
    reg [1:0] pg_s1, pg_s2;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pa_s1 <= 3'd0; pa_s2 <= 3'd0;
            pb_s1 <= 3'd0; pb_s2 <= 3'd0;
            lv_s1 <= 1'b0; lv_s2 <= 1'b0;
            pg_s1 <= 2'd0; pg_s2 <= 2'd0;
        end else begin
            pa_s1 <= pair_a;    pa_s2 <= pa_s1;
            pb_s1 <= pair_b;    pb_s2 <= pb_s1;
            lv_s1 <= lis_valid; lv_s2 <= lv_s1;
            pg_s1 <= page;      pg_s2 <= pg_s1;
        end
    end

    wire signed [15:0] mix16 = mix[23:8];   // 24bit 混音截高 16bit

    // ---- 中文界面信号同步进像素域（准静态，2FF）----
    reg [2:0]  uscr1, uscr2;
    reg [2:0]  ucur1, ucur2;
    reg        uins1, uins2;
    reg [4:0]  usel1, usel2;
    reg [11:0] ua1_1, ua1_2, ua2_1, ua2_2, ua3_1, ua3_2;
    reg [11:0] ua4_1, ua4_2, ua5_1, ua5_2, ua6_1, ua6_2;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            uscr1 <= 3'd0; uscr2 <= 3'd0;
            ucur1 <= 3'd0; ucur2 <= 3'd0;
            uins1 <= 1'b0; uins2 <= 1'b0;
            usel1 <= 5'd0; usel2 <= 5'd0;
            ua1_1 <= 12'd0; ua1_2 <= 12'd0; ua2_1 <= 12'd0; ua2_2 <= 12'd0;
            ua3_1 <= 12'd0; ua3_2 <= 12'd0; ua4_1 <= 12'd0; ua4_2 <= 12'd0;
            ua5_1 <= 12'd0; ua5_2 <= 12'd0; ua6_1 <= 12'd0; ua6_2 <= 12'd0;
        end else begin
            uscr1 <= ui_scr;  uscr2 <= uscr1;
            ucur1 <= ui_cur;  ucur2 <= ucur1;
            uins1 <= ui_instr; uins2 <= uins1;
            usel1 <= ui_sel_v; usel2 <= usel1;
            ua1_1 <= ui_adc1; ua1_2 <= ua1_1;
            ua2_1 <= ui_adc2; ua2_2 <= ua2_1;
            ua3_1 <= ui_adc3; ua3_2 <= ua3_1;
            ua4_1 <= ui_adc4; ua4_2 <= ua4_1;
            ua5_1 <= ui_adc5; ua5_2 <= ua5_1;
            ua6_1 <= ui_adc6; ua6_2 <= ua6_1;
        end
    end

    // ============================== 三块 RAM ==============================
    // T0 组合地址
    wire [8:0] vx = hcnt - H_BP;
    wire [8:0] vy = vcnt - V_BP;

    // 示波器：全宽 480 列，x 8..471 -> rcol 0..463
    wire [8:0] scope_col = vx - 9'd8;

    // 频谱：64 柱，7px/柱（6px 柱 + 1px 间隙），x 16..463 -> dx 0..447
    // 常数除法用两级区间比较：dx/56 得高 3 位，余数/7 得低 3 位（无除法器）
    wire [8:0] sdx = vx - 9'd16;
    reg  [2:0] sbin_hi;
    reg  [8:0] srem;
    always @(*) begin
        if      (sdx < 9'd56)  begin sbin_hi = 3'd0; srem = sdx;           end
        else if (sdx < 9'd112) begin sbin_hi = 3'd1; srem = sdx - 9'd56;   end
        else if (sdx < 9'd168) begin sbin_hi = 3'd2; srem = sdx - 9'd112;  end
        else if (sdx < 9'd224) begin sbin_hi = 3'd3; srem = sdx - 9'd168;  end
        else if (sdx < 9'd280) begin sbin_hi = 3'd4; srem = sdx - 9'd224;  end
        else if (sdx < 9'd336) begin sbin_hi = 3'd5; srem = sdx - 9'd280;  end
        else if (sdx < 9'd392) begin sbin_hi = 3'd6; srem = sdx - 9'd336;  end
        else                   begin sbin_hi = 3'd7; srem = sdx - 9'd392;  end
    end
    wire [2:0] sbin_lo = (srem < 9'd7)  ? 3'd0 : (srem < 9'd14) ? 3'd1 :
                         (srem < 9'd21) ? 3'd2 : (srem < 9'd28) ? 3'd3 :
                         (srem < 9'd35) ? 3'd4 : (srem < 9'd42) ? 3'd5 :
                         (srem < 9'd49) ? 3'd6 : 3'd7;
    wire [5:0] spec_bin = {sbin_hi, sbin_lo[2:0]};

    // 李萨如：256x256 位图 1:1 显示在 x112..367 / y8..263（不再放大，无台阶）。
    // 越界时强制 0（否则负坐标回绕会读出位图远端，在区外叠出假边框）
    wire [8:0]  lis_dx   = vx - 9'd112;
    wire [8:0]  lis_dy   = vy - 9'd8;
    wire        lis_in_a = (vx >= 9'd112 && vx <= 9'd367 &&
                            vy >= 9'd8   && vy <= 9'd263);
    wire [7:0]  lis_px = lis_in_a ? lis_dx[7:0] : 8'd0;
    wire [7:0]  lis_py = lis_in_a ? lis_dy[7:0] : 8'd0;

    wire signed [15:0] scope_q;
    wire [7:0]         mag_q;
    wire               lis_q;

    vis_scope u_scope (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en), .snap(gpls),
        .s16(mix16), .pclk(pclk), .rcol(scope_col), .rdata(scope_q));

    vis_spectrum u_spec (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en), .start(gpls),
        .s16(mix16), .pclk(pclk), .rbin(spec_bin), .rmag(mag_q));

    vis_lissajous u_lis (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en), .start(gpls),
        .a(osc_a), .b(osc_b), .pclk(pclk), .px(lis_px), .py(lis_py),
        .pixel(lis_q));

    // ======================= 中文界面：字符格 + 字库 =======================
    // 30 列 x 17 行、每格 16x16。T0 由像素坐标取 (行,列) -> 字形码 -> 字库地址；
    // 字库同步读，T1 得到该行 16bit 点阵，T2 与图形流水一起组合着色。
    wire [4:0] tcol = vx[8:4];
    wire [4:0] trow = vy[8:4];
    wire [6:0] tcode;
    wire [1:0] tattr;
    ui_text u_ui_text (
        .scr(uscr2), .row(trow), .col(tcol),
        .instr(uins2), .sel_v(usel2),
        .adc1(ua1_2), .adc2(ua2_2), .adc3(ua3_2),
        .adc4(ua4_2), .adc5(ua5_2), .adc6(ua6_2),
        .cur(ucur2), .page(pg_s2), .code(tcode), .attr(tattr));

    wire [15:0] font_q;
    ui_font_rom u_font (
        .clk(pclk), .code(tcode), .row(vy[3:0]), .q(font_q));

    // =========================== 渲染流水 T0->T2 ===========================
    // T1：示波器/频谱（1 拍 RAM）、字库输出（1 拍 BSRAM）与坐标
    reg        de1;
    reg [8:0]  vx1, vy1;
    reg signed [15:0] scp1;
    reg [7:0]  mag1;
    reg [3:0]  sx1;          // 格内列号（取字库点阵位用）
    reg [1:0]  attr1;
    reg        txtz1;        // 该格第 0 行 / 空白码（字库已省掉第 0 行，需屏蔽）
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            de1 <= 1'b0; vx1 <= 9'd0; vy1 <= 9'd0;
            scp1 <= 16'sd0; mag1 <= 8'd0;
            sx1 <= 4'd0; attr1 <= 2'd0; txtz1 <= 1'b0;
        end else begin
            de1 <= de; vx1 <= vx; vy1 <= vy;
            scp1 <= scope_q; mag1 <= mag_q;
            sx1 <= vx[3:0]; attr1 <= tattr;
            txtz1 <= (tcode == 7'd0) || (vy[3:0] == 4'd0);
        end
    end

    // T2：再延一拍，与李萨如的 2 拍流水对齐；同时取出字库点阵位
    reg        de2;
    reg [8:0]  vx2, vy2;
    reg signed [15:0] scp2;
    reg [7:0]  mag2;
    reg        tpx2;
    reg [1:0]  tattr2;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            de2 <= 1'b0; vx2 <= 9'd0; vy2 <= 9'd0;
            scp2 <= 16'sd0; mag2 <= 8'd0;
            tpx2 <= 1'b0; tattr2 <= 2'd0;
        end else begin
            de2 <= de1; vx2 <= vx1; vy2 <= vy1;
            scp2 <= scp1; mag2 <= mag1;
            tpx2 <= txtz1 ? 1'b0 : font_q[15 - sx1];   // q[15] = 最左像素（空白/首行屏蔽）
            tattr2 <= attr1;
        end
    end

    // ---------------- 几何判定（坐标为 T2 延迟后的坐标，按页选通） ----------------
    wire pg_wave = (pg_s2 == 2'd0);
    wire pg_spec = (pg_s2 == 2'd1);
    wire pg_lis  = (pg_s2 == 2'd2);
    wire pg_ui   = (pg_s2 == 2'd3);      // 中文界面页（不画图形/边框/页号）

    // 边框：每页一个满屏框 x4..475 / y4..267（界面页不要边框）
    wire border = !pg_ui &&
                  (((vx2 == 9'd4) || (vx2 == 9'd475)) &&
                   (vy2 >= 9'd4) && (vy2 <= 9'd267) ||
                   ((vy2 == 9'd4) || (vy2 == 9'd267)) &&
                   (vx2 >= 9'd4) && (vx2 <= 9'd475));

    // 页 0 示波器：波形区 x8..471 / y24..247，零轴 y=136
    wire scope_zone = pg_wave &&
                      (vx2 >= 9'd8 && vx2 <= 9'd471 && vy2 >= 9'd24 && vy2 <= 9'd247);
    wire zero_line  = scope_zone && (vy2 == 9'd136);

    wire signed [9:0] sv  = scp2 >>> 7;                 // ±256 满幅，增益×2
    wire signed [9:0] svc = (sv > 10'sd112)  ? 10'sd112  :
                            (sv < -10'sd112) ? -10'sd112 : sv;
    wire [8:0] wave_y = 9'd136 - svc[8:0];
    wire wave_dot = scope_zone && (vy2 == wave_y);

    // 页 1 频谱：柱区 x16..463 / y48..248，基线 y=248；柱高 = mag×2（≤208）
    // 着色用的"柱内列号"须用 T2 坐标重算（与 mag2 流水对齐），地址仍用 T0
    wire [8:0] sdx2 = vx2 - 9'd16;
    reg  [2:0] shi2;
    reg  [8:0] srem2;
    always @(*) begin
        if      (sdx2 < 9'd56)  begin shi2 = 3'd0; srem2 = sdx2;           end
        else if (sdx2 < 9'd112) begin shi2 = 3'd1; srem2 = sdx2 - 9'd56;   end
        else if (sdx2 < 9'd168) begin shi2 = 3'd2; srem2 = sdx2 - 9'd112;  end
        else if (sdx2 < 9'd224) begin shi2 = 3'd3; srem2 = sdx2 - 9'd168;  end
        else if (sdx2 < 9'd280) begin shi2 = 3'd4; srem2 = sdx2 - 9'd224;  end
        else if (sdx2 < 9'd336) begin shi2 = 3'd5; srem2 = sdx2 - 9'd280;  end
        else if (sdx2 < 9'd392) begin shi2 = 3'd6; srem2 = sdx2 - 9'd336;  end
        else                    begin shi2 = 3'd7; srem2 = sdx2 - 9'd392;  end
    end
    wire [2:0] slo2 = (srem2 < 9'd7)  ? 3'd0 : (srem2 < 9'd14) ? 3'd1 :
                      (srem2 < 9'd21) ? 3'd2 : (srem2 < 9'd28) ? 3'd3 :
                      (srem2 < 9'd35) ? 3'd4 : (srem2 < 9'd42) ? 3'd5 :
                      (srem2 < 9'd49) ? 3'd6 : 3'd7;
    wire [2:0] scol7_2 = srem2[5:0] - {slo2, 3'b000} + slo2;   // 柱内列 0..6

    wire spec_zone = pg_spec &&
                     (vx2 >= 9'd16 && vx2 <= 9'd463 && vy2 >= 9'd48 && vy2 <= 9'd248);
    wire [8:0] bar_h = {1'b0, mag2} << 1;             // mag≤104 -> ≤208
    wire bar_on   = spec_zone && (scol7_2 != 3'd6) && (bar_h != 9'd0) &&
                    (vy2 >= (9'd248 - bar_h));
    wire bar_top  = bar_on && (vy2 < (9'd248 - bar_h + 9'd3));  // 顶端 3px 黄色
    wire spec_base = pg_spec && (vx2 >= 9'd16 && vx2 <= 9'd463 && vy2 == 9'd248);

    // 页 2 李萨如：显示区 x112..367 / y8..263（位图 1:1）
    wire lis_zone = pg_lis &&
                    (vx2 >= 9'd112 && vx2 <= 9'd367 && vy2 >= 9'd8 && vy2 <= 9'd263);
    wire lis_on   = lis_zone && lv_s2 && lis_q;

    // ---------------- 5x7 点阵字库（放大倍数 1，字距 6px） ----------------
    // 编码：0..7 = 数字 0..7；16='-'；17=W 18=A 19=V 20=E 21=S 22=P 23=C
    function [34:0] glyph;
        input [5:0] id;
        begin
            case (id)
            6'd0:  glyph = 35'b01110_10001_10011_10101_11001_10001_01110; // 0
            6'd1:  glyph = 35'b00100_01100_00100_00100_00100_00100_01110; // 1
            6'd2:  glyph = 35'b01110_10001_00001_00010_00100_01000_11111; // 2
            6'd3:  glyph = 35'b11110_00001_00001_01110_00001_00001_11110; // 3
            6'd4:  glyph = 35'b00010_00110_01010_10010_11111_00010_00010; // 4
            6'd5:  glyph = 35'b11111_10000_11110_00001_00001_10001_01110; // 5
            6'd6:  glyph = 35'b00110_01000_10000_11110_10001_10001_01110; // 6
            6'd7:  glyph = 35'b11111_00001_00010_00100_01000_01000_01000; // 7
            6'd16: glyph = 35'b00000_00000_00000_11111_00000_00000_00000; // -
            6'd17: glyph = 35'b10001_10001_10001_10101_10101_11011_01110; // W
            6'd18: glyph = 35'b01110_10001_10001_11111_10001_10001_10001; // A
            6'd19: glyph = 35'b10001_10001_10001_10101_10101_01010_00100; // V
            6'd20: glyph = 35'b11111_10000_10000_11110_10000_10000_11111; // E
            6'd21: glyph = 35'b01111_10000_10000_01110_00001_00001_11110; // S
            6'd22: glyph = 35'b11110_10001_10001_11110_10000_10000_10000; // P
            6'd23: glyph = 35'b01110_10001_10000_10000_10000_10001_01110; // C
            default: glyph = 35'b00000_00000_00000_00000_00000_00000_00000;
            endcase
        end
    endfunction

    function char_bit;
        input [5:0] id;
        input [2:0] cc;
        input [2:0] rr;
        reg [34:0] g;
        begin
            g = glyph(id);
            char_bit = (cc < 3'd5) ? g[34 - (rr * 6'd5 + cc)] : 1'b0;
        end
    endfunction

    // 单行小标题：原点 (ox,oy)，4 个字符（宽 5+间距1，共 23px）
    // 用区间比较代替除法，避免综合出真除法器
    function title4;
        input [8:0] ox, oy;
        input [8:0] x, y;
        input [5:0] c0, c1, c2, c3;
        reg [8:0] dx, dy;
        reg [2:0] cc, rr;
        reg [5:0] id;
        begin
            dx = x - ox;
            dy = y - oy;
            if (dx < 9'd6)       begin id = c0; cc = dx[2:0];        end
            else if (dx < 9'd12) begin id = c1; cc = dx - 9'd6;      end
            else if (dx < 9'd18) begin id = c2; cc = dx - 9'd12;     end
            else                begin id = c3; cc = dx - 9'd18;      end
            rr = dy[2:0];
            title4 = (dx < 9'd23) && (dy < 9'd7) &&
                     char_bit(id, cc, rr);
        end
    endfunction

    // 页标题（左上角，随页切换）
    wire txt_wave = pg_wave && title4(9'd12, 9'd10, vx2, vy2,
                           6'd17, 6'd18, 6'd19, 6'd20);   // W,A,V,E
    wire txt_spec = pg_spec && title4(9'd12, 9'd10, vx2, vy2,
                           6'd21, 6'd22, 6'd20, 6'd23);   // S,P,E,C

    // 页号指示 "Pn"（右上角）：P + 数字 1..3
    wire [8:0] pnx = vx2 - 9'd452, pny = vy2 - 9'd10;
    wire [2:0] pncc = (pnx < 9'd6) ? pnx[2:0] : (pnx - 9'd6);
    wire [5:0] pnid = (pnx < 9'd6) ? 6'd22 : {4'd0, pg_s2} + 6'd1;
    wire txt_pgno = !pg_ui && (pnx < 9'd11) && (pny < 9'd7) &&
                    char_bit(pnid, pncc, pny[2:0]);

    // 李萨如页弦对标签 "a-b"（左上角，仅和音有效时显示）
    wire [8:0] ldx = vx2 - 9'd12;
    wire [8:0] ldy = vy2 - 9'd10;
    wire [2:0] lcc = (ldx < 9'd6)  ? ldx[2:0]      :
                     (ldx < 9'd12) ? ldx - 9'd6    :
                                     ldx - 9'd12;
    wire [2:0] lrr = ldy[2:0];
    wire [5:0] lid = (ldx < 9'd6)  ? {3'd0, pa_s2} :
                     (ldx < 9'd12) ? 6'd16 :
                                     {3'd0, pb_s2};
    wire txt_pair = pg_lis && lv_s2 &&
                    (ldx < 9'd17) && (ldy < 9'd7) &&
                    char_bit(lid, lcc, lrr);

    wire text_on = txt_wave || txt_spec || txt_pgno || txt_pair;

    // ---------------- 颜色（RGB565，蓝 bit2 物理缺失） ----------------
    localparam [15:0] C_BG     = 16'h0842;
    localparam [15:0] C_BORDER = 16'h8410;
    localparam [15:0] C_GRID   = 16'h3186;
    localparam [15:0] C_WAVE   = 16'h07FF;   // 青
    localparam [15:0] C_BAR    = 16'h07E0;   // 绿
    localparam [15:0] C_BARTOP = 16'hFFE0;   // 黄
    localparam [15:0] C_LIS    = 16'hF81F;   // 品红
    localparam [15:0] C_TEXT   = 16'hFFFF;   // 白
    localparam [15:0] C_UI_BG  = 16'h10A2;   // 中文界面深蓝底
    localparam [15:0] C_HL     = 16'hFFE0;   // 黄（光标/选中）
    localparam [15:0] C_TITLE  = 16'h07FF;   // 青（标题）
    localparam [15:0] C_DIM    = 16'h7BEF;   // 灰（暗）

    // 字库点阵前景色（attr：0 白 / 1 黄 / 2 青 / 3 灰）
    wire [15:0] ui_fg = (tattr2 == 2'd2) ? C_TITLE :
                        (tattr2 == 2'd3) ? C_DIM   :
                        (tattr2 == 2'd1) ? C_HL    : C_TEXT;

    wire [15:0] pix =
        (~de2)            ? C_BG     :
        tpx2              ? ui_fg    :   // UI 文字（演奏页乐器名/提示 叠加在波形上；界面页在蓝底上）
        pg_ui             ? C_UI_BG  :
        text_on           ? C_TEXT   :
        wave_dot          ? C_WAVE   :
        lis_on            ? C_LIS    :
        bar_on            ? (bar_top ? C_BARTOP : C_BAR) :
        (zero_line || spec_base) ? C_GRID :
        border            ? C_BORDER :
                              C_BG;

    reg [15:0] pix_r;
    reg        de_r;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pix_r <= C_BG;
            de_r  <= 1'b0;
        end else begin
            pix_r <= pix;
            de_r  <= de2;
        end
    end

    assign lcd_de = de_r;
    assign lcd_r  = pix_r[15:11];
    assign lcd_g  = pix_r[10:5];
    assign lcd_b  = pix_r[4:0];

endmodule
