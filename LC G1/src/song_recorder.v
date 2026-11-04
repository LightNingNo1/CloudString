// ============================================================================
// song_recorder.v - 用户弹奏录制引擎（记录按键事件到录制 RAM）
// ----------------------------------------------------------------------------
// 录制格式（24 位事件，与下载曲目 song_ram 完全一致）：
//   [23:22] cnt1 = 0/1 : 按下事件，目标音数-1（00=1 音、01=2 音）
//                = 2   : 释放事件（仅拉弦模式），n0=弦号、n1=0
//   [21:17] n0、[16:12] n1：目标弦号 0..31（单音事件 n1=0）
//   [11:0]  时值（10ms 单位）：
//           按下事件 = 本事件距上一按下事件的时间差（0 = 曲终标记）
//           释放事件 = 该弦从按下到松手的按住时长
//
// 录制行为：
//   1) rec_start 单拍脉冲 -> 开始录制：写指针归 0，时间差计数器归零，
//      等待第一个按键上升沿。
//   2) 检测 32 弦按键上升沿（按下瞬间）：
//      - 同一 10ms 拍内按下的多根弦合并为一个多音事件（最多 2 音）；
//      - 弦号扫描：5 位扫描计数器逐弦检查，32 拍扫完一轮（640ns），
//        远小于 10ms 节拍，避免大组合逻辑优先级编码器，省 LUT、减布线压力；
//      - 时间差 = 从上次按下事件（或开始录制）到本拍的 10ms 拍数；
//      - 事件写入 rec_ram，写指针 +1。
//   3) 【仅拉弦模式】检测下降沿（松手瞬间）：追加一条释放事件
//      cnt1=2, n0=弦号, n1=0, 时值 = 该弦按住时长。APP 回放时按"按下->松手"
//      配对，用按住时长决定发声长度，精确复刻实际弹奏的断奏/连奏。
//      拨弦模式不记录释放事件（拨弦是衰减音，松手不影响音长，保持原格式）。
//   4) rec_stop 单拍脉冲 -> 停止录制：在写指针处写曲终标记（24'h000000）。
//   5) 写满 255 事件后自动停止（第 256 槽留给曲终标记）。
//      注意：拉弦模式每音占 2 个事件（按下+释放），实际最多约 127 个音。
//
// 时间基准：内部 10ms 节拍（与 song_player 同精度），保证录制与时值单位一致。
// 输入 note_lvl 为 32 位按下电平（1 = 该弦被按住），与顶层 key_level_eff 同极性。
// ============================================================================
module song_recorder (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rec_start,     // 开始录制（单周期脉冲）
    input  wire        rec_stop,      // 停止录制（单周期脉冲）
    input  wire [31:0] note_lvl,      // 弦 0..31 按下电平（1 = 按住）
    input  wire        mode_sel,      // 当前音色模式（0=拨弦/竖琴, 1=拉弦/小提琴）
    output reg         rec_busy,      // 1 = 正在录制
    output reg  [7:0]  rec_cnt,       // 已录制事件数（0..255）
    output reg         rec_mode,      // 录制固化的音色模式（rec_start 时锁存）
    // ---- 录制 RAM 写口 ----
    output reg         ram_we,
    output reg  [7:0]  ram_waddr,
    output reg  [23:0] ram_wdata,
    // ---- 录制 RAM 读口（供 ble_link 上传用）----
    input  wire [7:0]  ram_raddr,
    output wire [23:0] ram_rdata
);

    // ---- 10ms 节拍 ----
    reg [18:0] tick10m;
    wire tk_10ms = (tick10m == 19'd499_999);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick10m <= 19'd0;
        else        tick10m <= tk_10ms ? 19'd0 : tick10m + 19'd1;
    end

    // ---- 10ms 拍时间戳（0..4095 循环，最大 40.95s）----
    reg [11:0] tick_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick_cnt <= 12'd0;
        else if (tk_10ms) tick_cnt <= tick_cnt + 12'd1;
    end

    // ---- 按键沿检测（逐弦扫描，省组合逻辑）----
    reg [4:0]  scan_cnt;        // 当前扫描的弦号 0..31
    reg [31:0] lvl_d1;          // 各弦上一拍电平（打一拍）
    reg [11:0] press_t [0:31];  // 各弦按下时刻的时间戳（供松手时长计算）
    integer    pi;

    reg [1:0]  ev_n;            // 本 10ms 拍已检测到的按下数（0/1/2）
    reg [4:0]  ev_k0, ev_k1;    // 本拍检测到的弦号（前 2 根）

    // ---- 本拍检测到的松手（仅拉弦模式记录）----
    reg [1:0]  rel_n;           // 本拍待写释放事件数（0/1/2）
    reg [4:0]  rel_k0, rel_k1;
    reg [11:0] rel_d0, rel_d1;

    // 被扫描到的弦的上升/下降沿脉冲（当拍有效）
    wire cur_rise = note_lvl[scan_cnt] & ~lvl_d1[scan_cnt];
    wire cur_fall = lvl_d1[scan_cnt] & ~note_lvl[scan_cnt];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_cnt <= 5'd0;
            lvl_d1   <= 32'd0;
            for (pi = 0; pi < 32; pi = pi + 1) press_t[pi] <= 12'd0;
        end else begin
            scan_cnt <= scan_cnt + 5'd1;                  // 每拍扫下一根
            lvl_d1[scan_cnt] <= note_lvl[scan_cnt];       // 打一拍
            if (cur_rise) press_t[scan_cnt] <= tick_cnt;  // 记录按下时刻
        end
    end

    // ---- 录制状态机 ----
    localparam [1:0] S_IDLE = 2'd0,   // 空闲（未录制）
                     S_WAIT = 2'd1,   // 录制中，等待按键
                     S_EV   = 2'd2,   // 有待写事件，写 RAM
                     S_ADV  = 2'd3;   // 写生效后推进写指针
    reg [1:0]  st;

    reg [11:0] gap_cnt;     // 距上一按下事件的 10ms 拍数（时值，最大 4095 = 40.95s）
    reg        tk_seen;     // 本 10ms 拍内是否已检测到上升沿

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            rec_busy  <= 1'b0;
            rec_cnt   <= 8'd0;
            rec_mode  <= 1'b0;
            ram_we    <= 1'b0;
            ram_waddr <= 8'd0;
            ram_wdata <= 24'd0;
            gap_cnt   <= 12'd0;
            ev_n      <= 2'd0;
            ev_k0     <= 5'd0;
            ev_k1     <= 5'd0;
            tk_seen   <= 1'b0;
            rel_n     <= 2'd0;
            rel_k0    <= 5'd0;
            rel_k1    <= 5'd0;
            rel_d0    <= 12'd0;
            rel_d1    <= 12'd0;
        end else begin
            ram_we <= 1'b0;

            // 逐弦扫描：检测到按下沿且本拍还没凑齐 2 音 -> 记录
            if (cur_rise && ev_n < 2'd2) begin
                ev_n  <= ev_n + 2'd1;
                if (ev_n == 2'd0) ev_k0 <= scan_cnt;
                else              ev_k1 <= scan_cnt;
            end

            // 逐弦扫描：检测到松手沿且拉弦模式 -> 记录释放事件（弦号 + 按住时长）
            if (cur_fall && rec_mode && rel_n < 2'd2) begin
                if (rel_n == 2'd0) begin
                    rel_k0 <= scan_cnt;
                    rel_d0 <= tick_cnt - press_t[scan_cnt];
                end else begin
                    rel_k1 <= scan_cnt;
                    rel_d1 <= tick_cnt - press_t[scan_cnt];
                end
                rel_n <= rel_n + 2'd1;
            end

            case (st)
            S_IDLE: begin
                if (rec_start) begin
                    st        <= S_WAIT;
                    rec_busy  <= 1'b1;
                    rec_mode  <= mode_sel;
                    rec_cnt   <= 8'd0;
                    ram_waddr <= 8'd0;
                    gap_cnt   <= 12'd0;
                    ev_n      <= 2'd0;
                    tk_seen   <= 1'b0;
                    rel_n     <= 2'd0;
                end
            end

            S_WAIT: begin
                if (rec_stop) begin
                    // 停止：写曲终标记（写指针当前位置）
                    st        <= S_IDLE;
                    rec_busy  <= 1'b0;
                    ram_we    <= 1'b1;
                    ram_wdata <= 24'h000000;
                end else if (rec_cnt >= 8'd255) begin
                    // 写满 255 事件自动停：写曲终标记
                    st        <= S_IDLE;
                    rec_busy  <= 1'b0;
                    ram_we    <= 1'b1;
                    ram_wdata <= 24'h000000;
                end else if (tk_10ms) begin
                    // 每个 10ms 拍末检查：有待写事件则写，无则 gap+1
                    if (ev_n != 2'd0 || rel_n != 2'd0) begin
                        st <= S_EV;
                    end else begin
                        gap_cnt <= gap_cnt + 12'd1;
                    end
                end else if (rel_n != 2'd0 && ev_n == 2'd0) begin
                    // 仅有释放事件时立即写，避免等下一拍阻塞后续松手记录；
                    // 有按下事件时必须等 10ms 拍末，保证同拍多弦仍合并为一个多音事件。
                    st <= S_EV;
                end
            end

            S_EV: begin
                // 写事件：[cnt1, n0, n1, 时值]。写地址保持当前 ram_waddr（即本事件序号），
                // 不在本拍递增，避免与 ram_we 同时更新导致 rec_ram 写到 waddr+1（地址 0 落空曲终）。
                ram_we <= 1'b1;
                if (ev_n != 2'd0) begin
                    // 按下事件优先：时值 = 距上一按下事件的间隔
                    ram_wdata <= {(ev_n - 2'd1), ev_k0, ev_k1, gap_cnt};
                    rec_cnt   <= rec_cnt + 8'd1;
                    gap_cnt   <= 12'd0;
                    ev_n      <= 2'd0;
                end else begin
                    // 释放事件：cnt1=2, n0=弦号, n1=0, 时值 = 按住时长
                    ram_wdata <= {2'b10, rel_k0, 5'd0, rel_d0};
                    rec_cnt   <= rec_cnt + 8'd1;
                    rel_k0    <= rel_k1;
                    rel_d0    <= rel_d1;
                    rel_n     <= rel_n - 2'd1;
                end
                st <= S_ADV;
            end

            S_ADV: begin
                // 上一拍 ram_we 已被 rec_ram 采样并写入 mem[ram_waddr]，这里才推进写指针。
                ram_waddr <= ram_waddr + 8'd1;
                st        <= S_WAIT;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

    // ---- 录制 RAM 实例 ----
    rec_ram u_rec_ram (
        .clk(clk), .we(ram_we),
        .waddr(ram_waddr), .wdata(ram_wdata),
        .raddr(ram_raddr), .rdata(ram_rdata)
    );

endmodule
