// ============================================================================
// song_ctl.v - 曲目播放控制（4 首循环：1 预制 + 3 下载槽）
// ----------------------------------------------------------------------------
// 曲目号 0..3：
//   0   = 预制 ROM 曲目（preset_sel 固定 0，即 ROM 第 0 首）
//   1/2/3 = 下载 RAM 槽 0/1/2（song_src=1，slot_sel = 曲目号-1）
// 面板（F10 三手势，由 f10_ctl 检测产生）：
//   长按 1s~2.5s（key_press）-> 开始 / 停止指引（toggle）
//   long_press（F10 长按 >=2.5s）-> 切到下一首（0..3 循环）并立即开始
// 蓝牙（来自 ble_link）：
//   cmd_song_vld + cmd_song_id -> 选曲并开始（id 0..6）
//   cmd_stop -> 停止
// 下载期间（dl_busy=1）强制停止指引，保证 RAM 单口读写不冲突。
// 注：指引只在拨弦模式生效（顶层 play_en_guide = play_en & ~mode 已处理），
//     本模块不再按 mode 换算编曲（拉弦模式的指示灯功能已删除）。
// ============================================================================
module song_ctl (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       key_press,      // F10 长按 1s~2.5s：指引开/停（单周期）
    input  wire       song_next,      // F10 长按 >=2.5s：切下一首曲目（单周期）
    input  wire       cmd_song_vld,   // 蓝牙：选曲有效（单周期）
    input  wire [2:0] cmd_song_id,    // 蓝牙：曲目号 0..3
    input  wire       cmd_stop,       // 蓝牙：停止（单周期）
    input  wire       dl_busy,        // 正在下载
    output reg        play_en,
    output reg        song_src,       // 0 = 预制, 1 = 下载 RAM
    output reg  [1:0] preset_sel,     // 预制曲目号 0..3
    output reg  [1:0] slot_sel,       // 下载槽号 0..2（song_src=1 时有效）
    output reg        song_load       // 切曲/选曲单拍脉冲：song_player 立即重载（曲首）
);
    reg [1:0] song_idx;    // 曲目号 0..3

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            play_en    <= 1'b0;
            song_src   <= 1'b0;
            preset_sel <= 2'd0;
            slot_sel   <= 2'd0;
            song_load  <= 1'b0;
            song_idx   <= 2'd0;
        end else begin
            song_load <= 1'b0;

            if (dl_busy) begin
                play_en   <= 1'b0;                       // 下载期间必须停
            end else if (song_next) begin
                song_idx   <= (song_idx == 2'd3) ? 2'd0 : song_idx + 2'd1;
                play_en    <= 1'b1;
                song_load  <= 1'b1;                      // 通知 song_player 立即重载曲首
            end else if (cmd_song_vld) begin
                if (cmd_song_id <= 3'd3)
                    song_idx <= cmd_song_id[1:0];
                play_en   <= 1'b1;
                song_load <= 1'b1;
            end else if (cmd_stop) begin
                play_en   <= 1'b0;
            end else if (key_press) begin
                play_en   <= ~play_en;
            end

            // 输出随曲目号每拍刷新：0=预制，下载槽 1/2/3 -> 槽 0/1/2
            song_src   <= (song_idx >= 2'd1);
            preset_sel <= 2'd0;
            slot_sel   <= (song_idx >= 2'd1) ? (song_idx - 2'd1) : 2'd0;
        end
    end
endmodule
