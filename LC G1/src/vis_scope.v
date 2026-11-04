// ============================================================================
// vis_scope.v - 波形采样环形 RAM（音频域写、像素域读双口）+ 过零触发
// ----------------------------------------------------------------------------
// 音频域(clk)：每个 sample_en 把一个 16bit 有符号采样写进深度 2048 的环形 RAM，
//   wptr 始终指向下一个待写位置（= 最老采样的位置）。
//
// 【触发机制（示波器原理，让波形静止）】
//   无触发时 snap 随机冻结 wptr，每帧波形起点相位随缘 -> 波形在屏上漂移。
//   这里做过零上升沿触发：prev < 0 && cur >= 0 时记下写指针 trig_now，
//   同时把原 trig_now 转存 trig_prev（双缓存），并各自维护"年龄"计数器
//   age_now/age_prev（自该触发点起经过的采样数，14bit 饱和）。
//   snap 到来时选点（优先级自上而下）：
//     1. age_now  >= TMO(8192)      -> 静音超时，自由滚动（冻结 wptr，同旧行为）
//     2. WIN <= age_prev < DEPTH    -> 用 trig_prev（上一次触发点：数据未回绕
//                                      且其后已写满一窗口，最稳）
//     3. age_now  >= WIN            -> 用 trig_now（极低频长周期，等不到 prev）
//     4. 都不满足                   -> 保持 snapptr 不动（触发刚建立的几帧）
//   锁定后每帧都从同一相位（上升过零点）起画，音高不变则波形完全静止。
//
// 【RAM 深度 1024、窗口 480 的依据（BSRAM 资源受限）】
//   原方案 2048x16 会多占 2 块 BSRAM，导致整板 BSRAM 用尽、P&R 卡在 80%。
//   现缩到 1024 深 + 窗口 480：候选起点 trig 距今需在 [480, 1024) 采样区间
//   内才有效（窗口已写满且数据未回绕）。对周期 < 10.7ms（>93Hz）的音可
//   每周期稳定锁定；对 <93Hz 的低音，age 超出 1024 时冻结上一次画面、
//   下一周期触发后再更新，视觉上仍基本静止。
//
// 像素域(pclk)：snapptr 经两级同步后在整帧内保持不变，显示侧按
//   raddr = snapptr + rcol 逐点取 480 列（每列 1 个采样，一屏覆盖
//   480 个采样 = 5ms @96kHz）。
//
// RAM 推断：写口 clk、读口 pclk 的简单双口 RAM -> 推断 BSRAM(SDP)。
// 跨时钟读单口数据无需握手：冻结的只是基址，RAM 单元本身双时钟隔离，
// 即使读到某一正在写的地址也只会得到旧/新值之一，不会出现亚稳数据。
// ============================================================================
module vis_scope (
    input  wire               clk,       // 音频域
    input  wire               rst_n,
    input  wire               sample_en, // 96kHz 采样脉冲
    input  wire               snap,      // 采集脉冲（落在 sample_en 上）
    input  wire signed [15:0] s16,       // mix 截高 16bit
    input  wire               pclk,      // 像素时钟
    input  wire [8:0]         rcol,      // 屏上列号 0..479
    output reg  signed [15:0] rdata      // 对应采样（1 拍 pclk 流水）
);
    localparam WIN    = 14'd480;    // 显示窗口采样数（480 列 x 1）
    localparam DEPTH  = 14'd1024;   // RAM 深度
    localparam TMO    = 14'd8192;   // 无触发超时（85ms @96kHz），超时自由滚动

    reg signed [15:0] mem [0:1023];
    reg [9:0]  wptr;
    reg [9:0]  snapptr;             // clk 域冻结指针

    // ---- 过零上升沿触发：双触发点 + 年龄计数 ----
    reg signed [15:0] prev_s16;
    reg [9:0]  trig_now, trig_prev; // 最近/上一次触发点写指针
    reg [13:0] age_now, age_prev;   // 距各触发点的采样数（饱和 16383）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr     <= 10'd0;
            snapptr  <= 10'd0;
            prev_s16 <= 16'sd0;
            trig_now <= 10'd0;
            trig_prev<= 10'd0;
            age_now  <= 14'd16383;  // 上电视为"从未触发"，先自由滚动
            age_prev <= 14'd16383;
        end else begin
            if (sample_en) begin
                mem[wptr] <= s16;
                wptr      <= wptr + 10'd1;
                prev_s16  <= s16;
                if ((prev_s16 < 16'sd0) && (s16 >= 16'sd0)) begin
                    // 上升过零：当前采样写入 wptr，即触发点 = wptr
                    trig_prev <= trig_now;
                    trig_now  <= wptr;
                    age_prev  <= age_now;
                    age_now   <= 14'd0;
                end else begin
                    if (age_now  != 14'd16383) age_now  <= age_now  + 14'd1;
                    if (age_prev != 14'd16383) age_prev <= age_prev + 14'd1;
                end
            end
            if (snap) begin
                if (age_now >= TMO)
                    snapptr <= wptr;                    // 静音：自由滚动
                else if ((age_prev >= WIN) && (age_prev < DEPTH))
                    snapptr <= trig_prev;               // 常规锁定：上一触发点
                else if (age_now >= WIN)
                    snapptr <= trig_now;                // 极低频兜底：最近触发点
                // else 保持不动（触发刚建立、窗口未写满的短暂瞬间）
            end
        end
    end

    // 冻结指针同步到 pclk（整帧稳定，直接两级同步即可）
    reg [9:0]  snap_s1, snap_s2;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            snap_s1 <= 10'd0;
            snap_s2 <= 10'd0;
        end else begin
            snap_s1 <= snapptr;
            snap_s2 <= snap_s1;
        end
    end

    // 每列 1 个采样：raddr = snapptr + rcol，模 1024 回绕
    wire [9:0] raddr = snap_s2 + rcol;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) rdata <= 16'sd0;
        else        rdata <= mem[raddr];
    end
endmodule
