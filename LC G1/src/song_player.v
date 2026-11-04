// ============================================================================
// song_player.v - 预制/下载曲目的 LED 指引音序器（节奏音游：首灯起始 + 按谱自动推进）
// ----------------------------------------------------------------------------
// 只驱动 LED（"下一个该拨哪根弦"），不参与发声——发声仍由按键+ADC 决定。
// 【拉弦模式的指示灯功能已删除，原版完整备份在 src_backup_20261019/，
//   如需恢复拉弦 LED 指引可直接用备份中的 song_player.v 替换本文件】
//
// 玩法（哪里亮了点哪里）：
//   1) 播放开始：事件 0 的目标弦 LED 呼吸渐亮至满后常驻（起始灯塔），等你按下。
//   2) 事件 0 的任一目标弦被按住即【立即跳下一事件】（按下即跳，无静默窗）：
//      - 每个事件在自身时值窗（dur，10ms 单位，随谱子各事件不同）内
//        LED 呼吸渐亮 0->100%：渐亮斜率 = ceil(256/dur) 级/10ms（led_step 输出），
//        亮度由顶层 8b' 节 PWM 实现；窗口末尾（= 下一事件节奏点）恰好达峰，
//        上一灯达峰瞬间下一灯接力渐亮；
//      - 窗口到时后无论你有没有按到，LED 都跳到下一事件
//        （窗口内可按当前目标弦发声，发声不影响推进）；
//      - 【按对即熄灭】渐亮过程中任一目标弦被按住 -> 该灯立即熄灭
//        （不再继续渐亮；按错弦忽略、灯照常渐亮），推进节奏不变。
//   3) 读到曲终标记（时值 0）回到事件 0 起始灯塔循环，等下一次按下。
//
// 命中判定用【按下电平】note_lvl（1 = 目标弦被按住，顶层 key_level 同极性），
// 不用发声脉冲 note_hit —— 拨弦模式发声在松键（key_release），若拿发声脉冲做
// 判定，按下瞬间无脉冲、LED 不跳变；改用按下电平则"按下即跳、按对即灭"。
// song_ram 是同步读 RAM（rdata 反映新地址要 2 拍），地址推进后 need_load 用
// 两拍加载（load_wait 标记第一拍只等地址建立），保证下载曲目的事件不错位。
//
// 事件格式：
//   预制曲目（song_rom，32 位）：
//     [31:30] cnt1：目标音数-1（00=1 音、01=2 音、10=3 音）
//     [29:25] n0 / [24:20] n1 / [19:15] n2：至多 3 个目标弦号（0..31）
//     [14:0]  时值（10ms 单位，0 = 曲终标记）
//   下载曲目（song_ram，新 24 位格式，最多 2 音混音）：
//     [23:22] cnt1：目标音数-1（00=1 音、01=2 音）
//     [21:17] n0 / [16:12] n1：目标弦号（0..31；单音事件 n1 固定 0，按 cnt1 屏蔽）
//     [11:0]  时值（10ms 单位，0 = 曲终标记）
//
// 地址分配：预置曲目 song_rom {preset_sel[1:0], off[7:0]}（每曲 256 槽），
//   下载曲目 song_ram {slot[1:0], off[7:0]}（3 槽 × 256 槽，曲终标记落在槽内最后槽）。
// ============================================================================
module song_player (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        song_load,      // 切曲/选曲单拍脉冲：立即回曲首起始灯塔（不等停止）
    input  wire        play_en,        // 1 = 指引运行中
    input  wire        song_src,       // 0 = 预制 ROM, 1 = 下载 RAM
    input  wire [1:0]  preset_sel,     // 预制曲目号 0..3
    input  wire [1:0]  slot,           // 下载槽号 0..2（song_src=1 时有效）
    input  wire [31:0] ev_data,        // 当前事件（见上格式说明）
    input  wire [31:0] note_lvl,       // 弦 0..31 按下电平（1 = 该弦被按住；命中判定用）
    output wire [9:0]  rom_addr,
    output wire [9:0]  ram_addr,       // 下载 RAM 地址 {槽号[1:0], 槽内序号[7:0]}（3 槽 × 256）
    output reg  [4:0]  guide_key0,     // 目标弦 0..2（和声事件至多 3 根）
    output reg  [4:0]  guide_key1,
    output reg  [4:0]  guide_key2,
    output reg  [1:0]  guide_n,        // 目标弦数 1..3（LED 分时轮转用）
    output reg         guide_vld,      // 1 = 目标弦有效（LED 点亮窗口）
    output reg         lit_off,        // 1 = 本窗口已按对目标弦（顶层呼吸归零判定用）
    output wire [8:0]  led_step        // 呼吸渐亮步进（每 10ms 升的级数，见窗口计时节）
);
    reg [8:0]  off;        // 事件序号（0..255）
    reg        started;    // 1 = 已按下起始键，音序按节奏自动推进
    reg        need_load;  // 1 = 刚推进地址，等加载新事件（RAM 同步读需 2 拍：地址建立 + 输出）
    reg        load_wait;  // need_load 第一拍标记：地址刚变化，RAM rdata 尚未更新，不采样
    reg [15:0] ev_tick;    // 当前窗口已过的 10ms 拍数
    reg [14:0] dur_r;      // 当前窗口总时值（10ms 单位）
    reg [8:0]  step_r;     // 呼吸渐亮步进锁存（启动后 = ceil(256/dur)，灯塔 = 16）
    reg [4:0]  k0, k1, k2; // 目标弦号（寄存，LED 输出稳定）
    reg [1:0]  n;          // 目标弦数 1..3

    // ---- 事件解码（ROM 32 位 / RAM 24 位统一）----
    wire [1:0]  ev_cnt1 = song_src ? ev_data[23:22] : ev_data[31:30];
    wire [4:0]  evk0    = song_src ? ev_data[21:17] : ev_data[29:25];
    wire [4:0]  evk1    = song_src ? ev_data[16:12] : ev_data[24:20];
    wire [4:0]  evk2    = song_src ? 5'd0          : ev_data[19:15];
    wire [14:0] dur     = song_src ? {3'b0, ev_data[11:0]} : ev_data[14:0];
    wire        ev_end  = (dur == 15'd0);
    wire [1:0]  evn     = ev_cnt1 + 2'd1;                 // 目标数 = cnt1+1（1..3）

    assign rom_addr = {preset_sel, off[7:0]};
    assign ram_addr = {slot, off[7:0]};   // 槽内序号只用低 8 位（每槽 256 槽）

    // 目标 one-hot 掩码（未用的 n1/n2 槽位按 evn 屏蔽，避免误指 v0）
    wire [31:0] tgt_oh = (evn >= 2'd1 ? (32'd1 << k0) : 32'd0)
                       | (evn >= 2'd2 ? (32'd1 << k1) : 32'd0)
                       | (evn >= 2'd3 ? (32'd1 << k2) : 32'd0);

    // ---- 起始判定：事件 0 任一目标弦被按住即启动音序（宽松判定）----
    //   用按下电平 note_lvl 累积：按下瞬间即命中，无需等松键发声脉冲。
    //   只要按住过任一目标弦就启动 —— 事件 0 若是多音和声，也无需把全部目标弦
    //   按齐，避免"按了一个弦却不跳"的卡死感；按错弦（非目标）忽略不累积。
    reg [31:0] hit_acc;
    wire hit_ok = (tgt_oh != 32'd0) && (hit_acc != 32'd0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     hit_acc <= 32'd0;
        else if (!play_en || started || need_load) hit_acc <= 32'd0;
        else                            hit_acc <= hit_acc | (note_lvl & tgt_oh);
    end

    // ---- 10ms 节拍（50MHz = 500_000 拍）----
    reg [18:0] tick10m;
    wire tk_10ms = (tick10m == 19'd499_999);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick10m <= 19'd0;
        else        tick10m <= tk_10ms ? 19'd0 : tick10m + 19'd1;
    end

    // ---- 窗口计时：ev_tick 只涨到 dur_r；LED 点亮窗口 = 整个事件时值窗 ----
    // 注意：ev_tick / step_r 只能在本块驱动（唯一驱动源），
    // 复位/切曲/过渡拍清零都在这里做，主状态机只管推进地址。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_tick <= 16'd0;
        end else if (!play_en || song_load || need_load) begin
            // 停止 / 切曲 / 过渡拍（新事件加载）：窗口计时归零
            ev_tick <= 16'd0;
        end else if (tk_10ms) begin
            if (started && !need_load && (ev_tick < dur_r))
                ev_tick <= ev_tick + 16'd1;
        end
    end

    // ---- 主状态机 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            off       <= 9'd0;
            started   <= 1'b0;
            need_load <= 1'b1;         // 上电即请求加载事件 0（起始灯塔）
            load_wait <= 1'b0;
            dur_r     <= 15'd0;
            step_r    <= 9'd16;        // 灯塔固定渐亮 160ms
            k0 <= 5'd0; k1 <= 5'd0; k2 <= 5'd0;
            n  <= 2'd1;
        end else if (!play_en) begin
            // 停止：整曲复位，下次启动回到曲首起始灯塔
            off       <= 9'd0;
            started   <= 1'b0;
            need_load <= 1'b1;
            load_wait <= 1'b0;
            step_r    <= 9'd16;
        end else if (song_load) begin
            // 切曲/选曲：立即回曲首起始灯塔（等加载事件 0）
            off       <= 9'd0;
            started   <= 1'b0;
            need_load <= 1'b1;
            load_wait <= 1'b0;
            step_r    <= 9'd16;
        end else if (!started && need_load) begin
            // 起始灯塔：等 RAM 同步读地址建立后再采样事件 0，然后渐亮常驻等待按下
            if (!load_wait) begin
                load_wait <= 1'b1;     // 第一拍：地址刚变化，rdata 未更新，不采样
            end else begin
                k0 <= evk0; k1 <= evk1; k2 <= evk2;
                n  <= evn;
                dur_r <= dur;
                step_r <= 9'd16;
                need_load <= 1'b0;
                load_wait <= 1'b0;
            end
        end else if (!started) begin
            // 起始灯塔：事件 0 任一目标弦被按住 -> 立即跳下一事件（LED 跳变接力，
            // 不再进入"静默窗"干等事件 0 时值；多音起始也无需按齐全部目标弦）
            if (hit_ok) begin
                started   <= 1'b1;
                off       <= off + 9'd1;
                need_load <= 1'b1;
                load_wait <= 1'b0;
            end
        end else if (need_load) begin
            // 过渡拍：等 RAM 同步读延迟（地址建立 + 输出两拍）后加载新事件
            if (!load_wait) begin
                load_wait <= 1'b1;     // 第一拍：地址刚变化，rdata 未更新，不采样
            end else if (ev_end) begin
                // 曲终：回到起始灯塔（重新加载事件 0）
                started   <= 1'b0;
                off       <= 9'd0;
                step_r    <= 9'd16;
                need_load <= 1'b1;
                load_wait <= 1'b0;
            end else begin
                k0 <= evk0; k1 <= evk1; k2 <= evk2;
                n  <= evn;
                dur_r <= dur;
                // 渐亮斜率匹配窗口：ceil(256/dur) 级/10ms -> 窗口末尾达峰（=下一事件节奏点）
                // dur != 0 已由上方 ev_end 分支排除，直接除法（16bit/15bit，商 9bit 内）
                step_r <= (16'd255 + {1'b0, dur}) / dur;
                need_load <= 1'b0;
                load_wait <= 1'b0;
            end
        end else if (ev_tick >= dur_r) begin
            // 窗口到时：自动跳到下一事件（无论有没有按到）
            off       <= off + 9'd1;
            need_load <= 1'b1;
            load_wait <= 1'b0;
        end
    end

    // ---- 空槽保护：事件 0 时值 0（空槽/未下载/曲终）时起始灯塔不亮灯 ----
    //   避免空槽播放时引导灯亮着 v0、按下又立刻曲终回灯塔的"空转卡死感"
    reg empty;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                empty <= 1'b0;
        else if (!play_en || song_load) empty <= 1'b0;
        else if (!started && need_load && load_wait)
            empty <= ev_end;       // 分支 4 采样拍：事件 0 时值 0 则标记空槽
    end

    // ---- 按对即熄灭：窗口内任一目标弦被按住 -> lit_off 锁存，LED 提前熄灭 ----
    //   只在启动后的普通窗口内生效（灯塔/过渡拍清 0），按错弦（非目标）不触发，
    //   灯继续渐亮提示；熄灭后推进逻辑不变（窗口到时仍跳下一事件）。
    wire hit_any = (note_lvl & tgt_oh) != 32'd0;   // 任一目标弦被按住（按下电平）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    lit_off <= 1'b0;
        else if (!play_en || song_load) lit_off <= 1'b0;
        else if (need_load || !started) lit_off <= 1'b0;
        else if (hit_any && !lit_off)  lit_off <= 1'b1;
    end

    // ---- LED 输出 ----
    // guide_vld = 整个事件时值窗（不再闪 200ms）：亮度由顶层按 led_step 呼吸渐亮，
    // 窗口末尾（= 下一事件开始 = 节奏点）亮度恰好达到最大，下一灯接力渐亮；
    // 按对目标弦（lit_off）后立即熄灭。
    always @(*) begin
        guide_key0 = k0;
        guide_key1 = k1;
        guide_key2 = k2;
        guide_n    = n;
        guide_vld  = play_en &
                     (started ? (!need_load && !lit_off) : (!need_load && !empty));
    end
    assign led_step = step_r;
endmodule
