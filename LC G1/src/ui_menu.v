// ============================================================================
// ui_menu.v - LCD 菜单状态机（50MHz 外设域）
// ----------------------------------------------------------------------------
// 按键：P6 上移 / N7 下移 / M7 短按确定 / M7 长按 1s 任意分支立刻回主菜单
//
// 界面树（scr 即状态号，同时也是屏幕编号，交给 ui_lines/ui_text 取字）：
//   0 主菜单      演奏模式 / 调试模式 / LED指引模式
//   1 演奏菜单    小提琴模式 / 竖琴模式      -> 2 演奏页（边演奏边显示波形/频谱/李萨如）
//   3 调试菜单    小提琴调试 / 竖琴调试      -> 4 调试页（乐器名+音名+6 路滑轨）
//   5 曲目目录    遇见(预制) / 下载曲目1~3   -> 6 指引页（选中即开始）
//   7 示波页      （已并入演奏页，不再单独进入）
//
// 输出：
//   mode_en  : UI 接管音色模式（演奏/调试/指引页）——此时 instr 就是乐器
//   dbg_req  : 进入调试模式（覆盖 D11 的 dbg_en）
//   page     : 0 波形 / 1 频谱 / 2 李萨如；3 = 纯中文界面（不画图形）
//              演奏页固定用 page 0/1/2，P6/N7 切换
//   song_idx/song_start/song_stop : 选曲（song_ctl 走 cmd_song_vld/cmd_stop）
// ============================================================================
module ui_menu (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       up_p,         // P6 单拍
    input  wire       dn_p,         // N7 单拍
    input  wire       ok_short,     // M7 短按（确定）
    input  wire       ok_long,      // M7 长按 1s（返回主菜单）
    input  wire       instr_tgl,    // 页面内 F10 单击：翻转当前乐器（0<->1）
    output reg  [2:0] scr,
    output reg  [2:0] cur,
    output wire       instr,        // 0 竖琴(拨弦) / 1 小提琴(拉弦)
    output reg  [1:0] page,
    output wire       mode_en,
    output wire       dbg_req,
    output reg  [1:0] song_idx,
    output reg        song_start,
    output reg        song_stop
);
    localparam [2:0] S_ROOT = 3'd0, S_PMENU = 3'd1, S_PLAY = 3'd2, S_DMENU = 3'd3,
                     S_DEBUG = 3'd4, S_SONGL = 3'd5, S_GUIDE = 3'd6, S_SCOPE = 3'd7;

    reg instr_r;                       // 已选乐器（0 竖琴 1 小提琴）
    assign instr = (scr == S_GUIDE) ? 1'b0 : instr_r;   // 指引只有拨弦版编曲

    assign mode_en = (scr == S_PLAY) || (scr == S_DEBUG) || (scr == S_GUIDE);
    assign dbg_req = (scr == S_DEBUG);

    // 当前界面的光标上限
    wire [2:0] nmax = (scr == S_ROOT)              ? 3'd2 :
                      (scr == S_PMENU || scr == S_DMENU) ? 3'd1 :
                      (scr == S_SONGL)             ? 3'd3 : 3'd2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scr        <= S_ROOT;
            cur        <= 3'd0;
            instr_r    <= 1'b0;
            page       <= 2'd3;
            song_idx   <= 2'd0;
            song_start <= 1'b0;
            song_stop  <= 1'b0;
        end else begin
            song_start <= 1'b0;
            song_stop  <= 1'b0;

            if (ok_long) begin                       // 任意分支：立刻回主菜单
                if (scr == S_GUIDE) song_stop <= 1'b1;
                scr  <= S_ROOT;
                cur  <= 3'd0;
                page <= 2'd3;
            end else begin
                if (instr_tgl) instr_r <= ~instr_r;   // 页面内 F10 单击：翻转乐器（下方确定键可覆盖）
                if (scr == S_PLAY) begin             // 演奏页：P6/N7 切波形/频谱/李萨如
                    if (up_p)      page <= (page == 2'd0) ? 2'd2 : (page - 2'd1);
                    else if (dn_p) page <= (page == 2'd2) ? 2'd0 : (page + 2'd1);
                end else if (scr != S_GUIDE) begin   // 指引页冻结光标（cur 即曲目号）
                    if (up_p)      cur <= (cur == 3'd0)  ? nmax : (cur - 3'd1);
                    else if (dn_p) cur <= (cur == nmax) ? 3'd0 : (cur + 3'd1);
                end

                if (ok_short) begin
                    case (scr)
                    S_ROOT: begin
                        cur <= 3'd0;                 // 进入子界面后光标复位
                        if (cur == 3'd0)      scr <= S_PMENU;
                        else if (cur == 3'd1) scr <= S_DMENU;
                        else begin
                            scr      <= S_SONGL;
                            song_idx <= 2'd0;
                        end
                    end
                    S_PMENU: begin
                        instr_r <= (cur == 3'd0);    // 光标 0 = 小提琴(1)，1 = 竖琴(0)
                        scr     <= S_PLAY;
                        page    <= 2'd0;            // 演奏页默认显示波形
                    end
                    S_DMENU: begin
                        instr_r <= (cur == 3'd0);    // 光标 0 = 小提琴调试(1)，1 = 竖琴调试(0)
                        scr     <= S_DEBUG;
                    end
                    S_SONGL: begin
                        song_idx   <= cur[1:0];
                        song_start <= 1'b1;          // 单拍：通知 song_ctl 选曲并开始
                        scr        <= S_GUIDE;
                    end
                    default: ;
                    endcase
                end
            end
        end
    end

endmodule
