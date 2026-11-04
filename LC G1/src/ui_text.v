// ============================================================================
// ui_text.v - LCD 文本叠加层取字（像素坐标 -> 字形码/属性）
// ----------------------------------------------------------------------------
// 30 列 x 17 行、每格 16x16（480x272 屏），静态文字来自 ui_lines.v（自动生成），
// 本模块在其上叠加动态内容：
//   主菜单/子菜单的光标 ">" 与选中行高亮
//   演奏页/调试页的乐器名、调试页的按键音名
//   调试页 6 路滑轨的实时条（12 格）+ 三位百分比（基准 50% 为静态）
// 属性 attr：0 白 / 1 黄（选中）/ 2 青（标题）/ 3 灰（暗）
// 每行属性放在 (scr,row) 上；调试页"无 D 段"整行置灰。
// ============================================================================
module ui_text (
    input  wire [2:0]  scr,       // 0 主菜单 1 演奏菜单 2 演奏 3 调试菜单 4 调试 5 曲目 6 指引 7 示波
    input  wire [4:0]  row,       // 0..16
    input  wire [4:0]  col,       // 0..29
    input  wire        instr,     // 0 = 竖琴(拨弦), 1 = 小提琴(拉弦)
    input  wire [4:0]  sel_v,     // 调试选中声部
    input  wire [11:0] adc1, adc2, adc3, adc4, adc5, adc6,   // 六路滑轨原码
    input  wire [2:0]  cur,       // 光标位置
    input  wire [1:0]  page,      // 0 波形 / 1 频谱 / 2 李萨如 / 3 纯界面
    output wire [6:0]  code,
    output wire [1:0]  attr
);
    // ---- 字形码（与 ui_font_rom.v 一致）----
    localparam [6:0] G_XIAO = 7'd11, G_TI = 7'd12, G_QIN = 7'd13, G_SHU = 7'd71,
                     G_WU   = 7'd61, G_DUAN = 7'd70, G_D = 7'd92,
                     G_BLOCK= 7'd78, G_ZERO = 7'd79, G_PCT = 7'd115,
                     G_GT   = 7'd119, G_SHARP = 7'd120,
                     // 曲目名用字（码值取自 ui_font_rom 码表）
                     G_YU   = 7'd32, G_JIAN = 7'd33, G_XIA = 7'd36, G_ZAI = 7'd37,
                     G_QU   = 7'd29, G_MU   = 7'd30,
                     // 演奏页叠加提示用字
                     G_CHANG= 7'd48, G_AN = 7'd39, G_FAN = 7'd49, G_HUI = 7'd50;
    // 音名字母 A..G
    localparam [6:0] LET_A = 7'd89, LET_B = 7'd90, LET_C = 7'd91, LET_D = 7'd92,
                     LET_E = 7'd93, LET_F = 7'd94, LET_G = 7'd95;
    // ASCII 字符（'0'=79, 'A'=89）
    localparam [6:0] ASC_P = 7'd104, ASC_N = 7'd102, ASC_M = 7'd101,
                     ASC_6 = 7'd85,  ASC_7 = 7'd86;

    wire [6:0] c0;
    wire [1:0] a0;
    ui_lines u_lines (.scr(scr), .row(row), .col(col), .code(c0), .attr(a0));

    // ---------------- 调试页滑轨：百分比与条长 ----------------
    // pct = (code*25 + 512) >> 10  ->  0..100（四舍五入）
    function [6:0] pct_f;
        input [11:0] v;
        reg [16:0] t;
        begin
            t     = {5'd0, v} * 5'd25 + 17'd512;
            pct_f = t[16:10];
        end
    endfunction

    // 先按行选出一路滑轨码，再做"码值 -> 百分比"（只算 1 次，省 5 组乘法/比较）
    reg [11:0] sraw;
    always @(*) begin
        case (row)
            5'd3:    sraw = adc1;      // 音调
            5'd5:    sraw = adc2;      // 响度
            5'd7:    sraw = adc3;      // 起音 A
            5'd9:    sraw = adc4;      // 衰减 D
            5'd11:   sraw = adc5;      // 释放 R
            5'd13:   sraw = adc6;      // 泛音比（最后一行）
            default: sraw = 12'd0;
        endcase
    end
    wire [6:0] pv = pct_f(sraw);       // 当前行对应百分比
    wire [3:0] fill = pv[6:3];         // 0..12 格

    function [3:0] d10;                // 十位（用比较链，避免除法器）
        input [6:0] v;
        begin
            d10 = (v >= 7'd90) ? 4'd9 : (v >= 7'd80) ? 4'd8 :
                  (v >= 7'd70) ? 4'd7 : (v >= 7'd60) ? 4'd6 :
                  (v >= 7'd50) ? 4'd5 : (v >= 7'd40) ? 4'd4 :
                  (v >= 7'd30) ? 4'd3 : (v >= 7'd20) ? 4'd2 :
                  (v >= 7'd10) ? 4'd1 : 4'd0;
        end
    endfunction
    wire [6:0] p2d = (pv >= 7'd100) ? (pv - 7'd100) : pv;   // 去掉百位后
    wire [3:0] dg_t = d10(p2d);
    wire [8:0] ten_t = {3'd0, dg_t, 3'd0} + {5'd0, dg_t, 1'b0};  // 10 * 十位
    wire [6:0] dg_rem = p2d - ten_t[6:0];                        // 个位（0..9）
    wire [3:0] dg_o = dg_rem[3:0];
    wire       dg_h = (pv >= 7'd100);

    // ---------------- 音名 ----------------
    // 拨弦 32 声部：32 个连续白键（C3 起），音级 = v % 7（0=C ... 6=B），八度 = 3 + v / 7
    // 拉弦 32 声部：4 弦 x 8 段全音递进（G3 起）
    wire [1:0] p_oct = (sel_v >= 5'd28) ? 2'd4 :
                       (sel_v >= 5'd21) ? 2'd3 :
                       (sel_v >= 5'd14) ? 2'd2 :
                       (sel_v >= 5'd7)  ? 2'd1 : 2'd0;
    wire [4:0] p_seven = {2'd0, p_oct, 3'b000} - {3'd0, p_oct};  // 7 * 相对八度层
    wire [2:0] p_nidx  = sel_v - p_seven;                        // v % 7（音级）
    reg  [2:0] nlet;       // 0 C 1 D 2 E 3 F 4 G 5 A 6 B
    reg        nsh;
    reg  [3:0] noct;
    always @(*) begin
        if (!instr) begin
            nlet = p_nidx;                       // 音级：0=C ... 6=B
            nsh  = 1'b0;
            noct = 4'd3 + {2'd0, p_oct};         // 八度 = 3 + v/7
        end else begin
            case (sel_v)
                5'd0:  begin nlet = 3'd4; nsh = 1'b0; noct = 4'd3; end   // G3
                5'd1:  begin nlet = 3'd5; nsh = 1'b0; noct = 4'd3; end   // A3
                5'd2:  begin nlet = 3'd6; nsh = 1'b0; noct = 4'd3; end   // B3
                5'd3:  begin nlet = 3'd0; nsh = 1'b1; noct = 4'd4; end   // C#4
                5'd4:  begin nlet = 3'd1; nsh = 1'b1; noct = 4'd4; end   // D#4
                5'd5:  begin nlet = 3'd3; nsh = 1'b0; noct = 4'd4; end   // F4
                5'd6:  begin nlet = 3'd4; nsh = 1'b0; noct = 4'd4; end   // G4
                5'd7:  begin nlet = 3'd5; nsh = 1'b0; noct = 4'd4; end   // A4
                5'd8:  begin nlet = 3'd1; nsh = 1'b0; noct = 4'd4; end   // D4
                5'd9:  begin nlet = 3'd2; nsh = 1'b0; noct = 4'd4; end   // E4
                5'd10: begin nlet = 3'd3; nsh = 1'b1; noct = 4'd4; end   // F#4
                5'd11: begin nlet = 3'd4; nsh = 1'b1; noct = 4'd4; end   // G#4
                5'd12: begin nlet = 3'd5; nsh = 1'b1; noct = 4'd4; end   // A#4
                5'd13: begin nlet = 3'd0; nsh = 1'b0; noct = 4'd5; end   // C5
                5'd14: begin nlet = 3'd1; nsh = 1'b0; noct = 4'd5; end   // D5
                5'd15: begin nlet = 3'd2; nsh = 1'b0; noct = 4'd5; end   // E5
                5'd16: begin nlet = 3'd5; nsh = 1'b0; noct = 4'd4; end   // A4
                5'd17: begin nlet = 3'd6; nsh = 1'b0; noct = 4'd4; end   // B4
                5'd18: begin nlet = 3'd0; nsh = 1'b1; noct = 4'd5; end   // C#5
                5'd19: begin nlet = 3'd1; nsh = 1'b1; noct = 4'd5; end   // D#5
                5'd20: begin nlet = 3'd3; nsh = 1'b0; noct = 4'd5; end   // F5
                5'd21: begin nlet = 3'd4; nsh = 1'b0; noct = 4'd5; end   // G5
                5'd22: begin nlet = 3'd5; nsh = 1'b0; noct = 4'd5; end   // A5
                5'd23: begin nlet = 3'd6; nsh = 1'b0; noct = 4'd5; end   // B5
                5'd24: begin nlet = 3'd2; nsh = 1'b0; noct = 4'd5; end   // E5
                5'd25: begin nlet = 3'd3; nsh = 1'b1; noct = 4'd5; end   // F#5
                5'd26: begin nlet = 3'd4; nsh = 1'b1; noct = 4'd5; end   // G#5
                5'd27: begin nlet = 3'd5; nsh = 1'b1; noct = 4'd5; end   // A#5
                5'd28: begin nlet = 3'd0; nsh = 1'b0; noct = 4'd6; end   // C6
                5'd29: begin nlet = 3'd1; nsh = 1'b0; noct = 4'd6; end   // D6
                5'd30: begin nlet = 3'd2; nsh = 1'b0; noct = 4'd6; end   // E6
                default: begin nlet = 3'd3; nsh = 1'b1; noct = 4'd6; end // F#6
            endcase
        end
    end

    wire [6:0] nlet_c = (nlet == 3'd0) ? LET_C : (nlet == 3'd1) ? LET_D :
                        (nlet == 3'd2) ? LET_E : (nlet == 3'd3) ? LET_F :
                        (nlet == 3'd4) ? LET_G : (nlet == 3'd5) ? LET_A : LET_B;
    wire [6:0] noct_c = G_ZERO + {3'd0, noct};

    // ---------------- 组合输出 ----------------
    reg [6:0] c;
    reg [1:0] a;
    wire [4:0] sel_row = (scr == 3'd0) ? (5'd3 + {1'b0, cur, 1'b0}) :
                         (scr == 3'd1) ? (5'd4 + {1'b0, cur, 1'b0}) :
                         (scr == 3'd3) ? (5'd4 + {1'b0, cur, 1'b0}) :
                         (scr == 3'd5) ? (5'd5 + {1'b0, cur, 1'b0}) : 5'd31;
    wire [4:0] mk_col  = (scr == 3'd0) ? 5'd5 :
                         (scr == 3'd3) ? 5'd3 : 5'd4;
    wire       menu    = (scr == 3'd0) || (scr == 3'd1) || (scr == 3'd3) || (scr == 3'd5);

    always @(*) begin
        c = c0;
        a = a0;

        // 0) 演奏页叠加在波形/频谱/李萨如之上：只画乐器名和底部提示，
        //    其余格子输出空白（不遮挡图形）
        if (scr == 3'd2 && page != 2'd3) begin
            c = 7'd0;
            a = 2'd1;                       // 黄色，在波形上清晰可见
            // 顶部居中：乐器名（小提琴 3 字 / 竖琴 2 字），避开顶部边框(y<4)
            if (row == 5'd1 && col >= 5'd13 && col <= 5'd15) begin
                if (instr) begin
                    if (col == 5'd13) c = G_XIAO;
                    else if (col == 5'd14) c = G_TI;
                    else c = G_QIN;
                end else begin
                    if (col == 5'd14) c = G_SHU;
                    else if (col == 5'd15) c = G_QIN;
                end
            end
            // 底部提示："P6 N7 长按M7返回"
            if (row == 5'd15) begin
                case (col)
                5'd2:  c = ASC_P;
                5'd3:  c = ASC_6;
                5'd5:  c = ASC_N;
                5'd6:  c = ASC_7;
                5'd8:  c = G_CHANG;
                5'd9:  c = G_AN;
                5'd10: c = ASC_M;
                5'd11: c = ASC_7;
                5'd12: c = G_FAN;
                5'd13: c = G_HUI;
                default: c = 7'd0;
                endcase
            end
        end else begin

        // 1) 菜单光标与选中行
        if (menu) begin
            if (row == sel_row) begin
                a = 2'd1;
                if (col == mk_col) c = G_GT;
            end
        end

        // 2) 乐器名（演奏页大字 / 调试页页眉）
        if (scr == 3'd2 && row == 5'd5 && col >= 5'd13 && col <= 5'd15) begin
            c = (col == 5'd13) ? (instr ? G_XIAO : G_SHU) :
                (col == 5'd14) ? (instr ? G_TI   : G_QIN) :
                                 (instr ? G_QIN  : 7'd0);
            a = 2'd1;
        end

        // 3) 调试页音名（col 7..9："C4" 或 "C#4"）
        if (scr == 3'd4 && row == 5'd1) begin
            if (col == 5'd7) c = nlet_c;
            else if (col == 5'd8) c = nsh ? G_SHARP : noct_c;
            else if (col == 5'd9) c = nsh ? noct_c : 7'd0;
        end

        // 4) 调试页滑轨条与三位百分比（仅 6 条滑轨所在行；拉弦的 D 行不显示）
        //    必须按行门控：否则行间空白行（4/6/8/10/12）会取默认 sraw=0，
        //    在 "050%" 的下一行画出一排多余的 "000"。
        if (scr == 3'd4 && (row == 5'd3 || row == 5'd5 || row == 5'd7 ||
                            row == 5'd9 || row == 5'd11 || row == 5'd13) &&
            !(instr && row == 5'd9)) begin
            if (col >= 5'd5 && col <= 5'd16) begin
                if ({1'b0, col} - 5'd5 < {1'b0, fill}) c = G_BLOCK;
            end else if (col == 5'd18) begin
                c = dg_h ? (G_ZERO + 7'd1) : G_ZERO;
            end else if (col == 5'd19) begin
                c = G_ZERO + {3'd0, dg_t};
            end else if (col == 5'd20) begin
                c = G_ZERO + {3'd0, dg_o};
            end
        end

        // 5) 拉弦无 D 段：整行置灰，标签改"无D段"，不画条
        if (scr == 3'd4 && instr && row == 5'd9) begin
            a = 2'd3;
            if (col == 5'd1) c = G_WU;
            else if (col == 5'd2) c = G_D;
            else if (col == 5'd3) c = G_DUAN;
            else if (col >= 5'd5) c = 7'd0;   // 条、三位百分比、"% 基准50%"整段都不显示
        end

        // 6) 调试页页眉乐器名："调试:<乐器>"（col 5..7）
        if (scr == 3'd4 && row == 5'd0 && col >= 5'd5 && col <= 5'd7) begin
            c = (col == 5'd5) ? (instr ? G_XIAO : G_SHU) :
                (col == 5'd6) ? (instr ? G_TI   : G_QIN) :
                                 (instr ? G_QIN  : 7'd0);
            a = 2'd1;
        end

        // 7) 指引页曲目名（进入指引页时 cur 保留为所选曲目号 0..3）
        if (scr == 3'd6 && row == 5'd4 && col >= 5'd7 && col <= 5'd11) begin
            if (cur == 3'd0) begin
                if (col == 5'd7) c = G_YU;
                else if (col == 5'd8) c = G_JIAN;
            end else begin
                if (col == 5'd7) c = G_XIA;
                else if (col == 5'd8) c = G_ZAI;
                else if (col == 5'd9) c = G_QU;
                else if (col == 5'd10) c = G_MU;
                else c = G_ZERO + {3'd0, cur};   // 曲目 1..3 -> '1'..'3'
            end
            a = 2'd1;
        end
        end  // end else (非演奏页叠加模式)
    end

    assign code = c;
    assign attr = a;

endmodule
