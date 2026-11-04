// ============================================================================
// ble_link.v - 蓝牙（VG6328A 透传模块）曲目下载与播放控制协议
// ----------------------------------------------------------------------------
// 手机 App 通过 VG6328A 的 GATT 写特征(0xFFE1) 把字节流送到模块串口，
// FPGA 侧就是一路 115200 8N1 UART。本模块负责收帧、校验、写曲目 RAM、回 ACK。
//
// 帧格式（定长字段、大端）：
//   AA 55 | LEN | CMD | PAYLOAD[LEN] | SUM
//   LEN = 负载字节数；SUM = (LEN + CMD + ΣPAYLOAD) & 0xFF
//
// 命令表：
//   0x01 BEGIN   LEN=1   负载 = 下载槽号（0..2）：写指针归 0，进入下载态（dl_busy=1）
//   0x02 DATA    LEN=1+3n  负载 = 起始事件序号 IDX(1 字节) + n 个事件(每个 3 字节，
//                          高字节在前：[23:16][15:8][7:0]，24 位双音事件)
//                          事件写到当前槽 RAM[IDX+k]，校验通过后写指针推进到 IDX+n
//   0x03 END     LEN=0   结束下载：在当前槽写指针处补 24'h000000 曲终标记，
//                         置当前槽 dl_ok（写指针可到 255：曲终标记落在槽内 slot 255）
//   0x10 PLAY    LEN=1   负载为曲目号（0 预制，1/2/3 = 下载槽 0/1/2），选曲并开始指引
//   0x11 STOP    LEN=0   停止指引
//   0x12 QUERY   LEN=0   查询状态
//   0x13 ERASE   LEN=0   清空当前下载槽（写指针归 0，清当前槽 dl_ok）
//   0x20 REC_START  LEN=0   开始录制：录制引擎清 0 并开始记录按键事件
//   0x21 REC_STOP   LEN=0   停止录制：补曲终标记，结束录制态
//   0x22 REC_QUERY  LEN=0   查询录制状态：回 2 字节 [CNT, MODE]：
//                           CNT bit7=1 正在录制、bit6..0=事件数(0..127)；MODE bit0=音色(0拨弦/1拉弦)
//   0x23 REC_READ   LEN=1   读取录制数据：负载 = 起始事件序号(0..255)，
//                          回传最多 8 个事件（与 DATA 帧同格式，便于 APP 直接复用解析）：
//                          ACK 负载 = IDX(1字节) + n*3字节事件数据
//   LEN 与命令不匹配、或未知命令，一律拒收（回到空闲，不应答）
//
// 事件格式（24 位，最多 2 音混音，与 song_ram.v / song_player.v 一致）：
//   [23:22] cnt1 = 目标音数-1（00=1 音、01=2 音）
//   [21:17] n0、[16:12] n1：目标弦号 0..31
//   [11:0]  时值（10ms 单位；0 = 曲终标记，由 END 帧自动补）
//
// 可靠性设计：
//   1) DATA 帧自带起始序号 IDX，重传同一帧 = 覆写同一段地址，天然幂等，
//      不会因为丢 ACK 重传而重复追加音符。
//   2) 写指针只在校验通过的帧末尾推进；校验错的帧不改写指针，其越界落盘
//      的字节会被后续重传覆盖（地址相同），或落在曲终标记之后无人读取。
//   3) 应答请求用"粘滞"标志，不会因为上一帧 ACK 还在发送中而被丢掉。
//
// 应答帧：
//   ACK    AA 55 01 | (CMD|0x80) | 01 | SUM      （01 = 正常）
//   STATUS AA 55 04 | 92 | STAT | CNT | OCC | SLOT | SUM
//          STAT: bit0 = 指引运行中, bit1 = 当前槽已成功下载
//          CNT : 当前槽写指针（= 已存入的事件数，0..255）
//          OCC : bit0/1/2 = 下载槽 0/1/2 是否已成功下载（占用位）
//          SLOT: 当前下载/回读槽号（0..2）
// ============================================================================
module ble_link (
    input  wire        clk,
    input  wire        rst_n,
    // ---- UART 字节流 ----
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output reg  [7:0]  tx_data,
    output reg         tx_start,
    input  wire        tx_busy,
    // ---- 曲目 RAM 写口 ----
    output reg         ram_we,
    output reg  [9:0]  ram_waddr,    // {下载槽[1:0], 槽内地址[7:0]}（3 槽 × 256）
    output reg  [23:0] ram_wdata,
    // ---- 播放控制 ----
    output reg         cmd_song_vld,
    output reg  [2:0]  cmd_song_id,
    output reg         cmd_stop,
    // ---- 状态 ----
    output reg  [2:0]  dl_ok,        // 每下载槽一位（0/1/2 = 已成功下载）
    output wire        dl_busy,
    input  wire        play_en,
    // ---- 录制控制 ----
    output reg         rec_start,     // 开始录制（单周期脉冲）
    output reg         rec_stop,      // 停止录制（单周期脉冲）
    input  wire        rec_busy,      // 正在录制中
    input  wire [7:0]  rec_cnt,       // 已录制事件数
    input  wire        rec_mode,      // 录制固化的音色模式（0=拨弦/竖琴, 1=拉弦/小提琴）
    output wire        rec_rd_req,    // 触发 rec_reader 读
    output wire [7:0]  rec_rd_idx,    // 读起始序号
    // REC_READ 应答数据（来自 rec_reader）
    input  wire [7:0]  rec_rd_b0, rec_rd_b1, rec_rd_b2,
                      rec_rd_b3, rec_rd_b4, rec_rd_b5,
                      rec_rd_b6, rec_rd_b7, rec_rd_b8,
    input  wire [3:0]  rec_rd_len,
    input  wire        rec_rd_valid
);
    // ---------------- 收帧状态机 ----------------
    localparam [2:0] S_H0 = 3'd0, S_H1 = 3'd1, S_LEN = 3'd2,
                     S_CMD = 3'd3, S_PAY = 3'd4, S_SUM = 3'd5;

    reg  [2:0]  st;
    reg  [7:0]  flen;      // 本帧负载长度
    reg  [7:0]  fcmd;      // 本帧命令
    reg  [7:0]  pidx;      // 负载字节索引
    reg  [7:0]  sum_calc;  // 累加校验
    reg  [7:0]  ev_hi;     // 事件字节 1 暂存 [23:16]
    reg  [7:0]  ev_mi;     // 事件字节 2 暂存 [15:8]
    reg  [1:0]  evb;       // 当前事件内字节计数 0..2（3 字节成组落盘）
    reg  [8:0]  fidx;      // 本帧 DATA 的起始事件序号（9 位，配合 9 位写指针）
    reg  [8:0]  pcnt;      // 本帧已写入的事件数
    wire [8:0]  waddr_calc = fidx + pcnt;   // 本帧当前事件的槽内地址（具名 wire，供位选）

    // ---------------- 曲目 RAM 写指针 ----------------
    reg  [8:0]  wptr;      // 槽内下一个待写地址（也等于当前槽已成功写入的事件数）；9 位以容纳 255
    reg  [1:0]  dlslot;    // 当前下载槽号 0..2（BEGIN 帧锁存，写地址高 2 位）
    reg         dl_busy_r;

    assign dl_busy = dl_busy_r;
    assign rec_rd_req = rdr_req;    // rec_reader 触发：rdr_req 有效即请求
    assign rec_rd_idx = rd_idx;     // 读起始序号

    // ---------------- 应答帧组装 / 发送 ----------------
    reg  [7:0]  rbuf [0:11];   // ACK 6B / STATUS 9B / REC_READ 12B（2 事件/帧）
    reg  [3:0]  rlen, ridx;    // 4bit 足够（最大 12）
    reg         rsend;
    reg         ack_req, stat_req, recq_req, rdr_req;   // 粘滞：被发送状态机取走才清
    reg  [7:0]  rd_idx;      // REC_READ 起始序号
    reg         rd_ack;      // REC_READ 数据已取走应答（通知 rec_reader 清 rd_valid）

    localparam [1:0] T_IDLE = 2'd0, T_SEND = 2'd1, T_WAIT = 2'd2;
    reg  [1:0]  tst;

    wire [7:0] ack_cmd  = fcmd | 8'h80;
    wire [7:0] ack_chk  = 8'd1 + ack_cmd + 8'h01;
    wire [7:0] sts_cmd  = 8'h92;
    wire [7:0] sts_stat = {6'b000000, dl_ok[dlslot], play_en};
    wire [7:0] sts_cnt  = wptr[7:0];
    wire [7:0] sts_occ  = {5'b00000, dl_ok[2:0]};
    wire [7:0] sts_slot = {6'b000000, dlslot};
    wire [7:0] sts_chk  = 8'd4 + sts_cmd + sts_stat + sts_cnt + sts_occ + sts_slot;
    // REC_QUERY 应答：AA 55 02 | A2 | CNT | MODE | SUM
    //   CNT : bit7 = rec_busy（正在录制），bit6..0 = 事件数（0..127，够用）
    //   MODE: bit0 = rec_mode（0=拨弦/竖琴，1=拉弦/小提琴）
    wire [7:0] recq_cmd  = 8'hA2;
    wire [7:0] recq_cnt  = {rec_busy, rec_cnt[6:0]};
    wire [7:0] recq_mode = {7'b0000000, rec_mode};
    wire [7:0] recq_chk  = 8'd2 + recq_cmd + recq_cnt + recq_mode;

    // 命令与负载长度的合法性（用当拍输入的字节判断，而非寄存后的 fcmd）
    wire [7:0] cin = rx_data;
    wire len_ok = (cin == 8'h01) ? (flen == 8'd1) :                 // BEGIN：1 字节槽号
                  (cin == 8'h03 || cin == 8'h11 || cin == 8'h12 || cin == 8'h13) ? (flen == 8'd0) :
                  (cin == 8'h20 || cin == 8'h21 || cin == 8'h22) ? (flen == 8'd0) :  // REC_START/STOP/QUERY
                  (cin == 8'h02) ? (flen >= 8'd1) :
                  (cin == 8'h10 || cin == 8'h23) ? (flen == 8'd1) : 1'b0;             // PLAY / REC_READ

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= S_H0;
            flen       <= 8'd0;
            fcmd       <= 8'd0;
            pidx       <= 8'd0;
            sum_calc   <= 8'd0;
            ev_hi      <= 8'd0;
            ev_mi      <= 8'd0;
            evb        <= 2'd0;
            fidx       <= 9'd0;
            pcnt       <= 9'd0;
            wptr       <= 9'd0;
            dlslot     <= 2'd0;
            dl_busy_r  <= 1'b0;
            dl_ok      <= 3'b000;
            ram_we     <= 1'b0;
            ram_waddr  <= 10'd0;
            ram_wdata  <= 24'd0;
            cmd_song_vld <= 1'b0;
            cmd_song_id  <= 3'd0;
            cmd_stop     <= 1'b0;
            rec_start    <= 1'b0;
            rec_stop     <= 1'b0;
            ack_req    <= 1'b0;
            stat_req   <= 1'b0;
            recq_req   <= 1'b0;
            rdr_req    <= 1'b0;
            rd_ack     <= 1'b0;
            rsend      <= 1'b0;
            tst        <= T_IDLE;
            tx_data    <= 8'd0;
            tx_start   <= 1'b0;
        end else begin
            ram_we       <= 1'b0;
            cmd_song_vld <= 1'b0;
            cmd_stop     <= 1'b0;
            rec_start    <= 1'b0;
            rec_stop     <= 1'b0;
            tx_start     <= 1'b0;

            // ================= 发送状态机（先执行，便于收帧侧覆盖请求标志） =================
            case (tst)
            T_IDLE: begin
                if (!rsend) begin
                    if (ack_req) begin
                        rbuf[0] <= 8'hAA; rbuf[1] <= 8'h55; rbuf[2] <= 8'd1;
                        rbuf[3] <= ack_cmd; rbuf[4] <= 8'h01; rbuf[5] <= ack_chk;
                        rlen    <= 5'd6;
                        ridx    <= 5'd0;
                        rsend   <= 1'b1;
                        ack_req <= 1'b0;
                    end else if (stat_req) begin
                        rbuf[0] <= 8'hAA; rbuf[1] <= 8'h55; rbuf[2] <= 8'd4;
                        rbuf[3] <= sts_cmd; rbuf[4] <= sts_stat;
                        rbuf[5] <= sts_cnt; rbuf[6] <= sts_occ;
                        rbuf[7] <= sts_slot; rbuf[8] <= sts_chk;
                        rlen    <= 5'd9;
                        ridx    <= 5'd0;
                        rsend   <= 1'b1;
                        stat_req <= 1'b0;
                    end else if (recq_req) begin
                        rbuf[0] <= 8'hAA; rbuf[1] <= 8'h55; rbuf[2] <= 8'd2;
                        rbuf[3] <= recq_cmd; rbuf[4] <= recq_cnt;
                        rbuf[5] <= recq_mode; rbuf[6] <= recq_chk;
                        rlen    <= 5'd7;
                        ridx    <= 5'd0;
                        rsend   <= 1'b1;
                        recq_req <= 1'b0;
                    end else if (rdr_req && rec_rd_valid) begin
                        // REC_READ 应答：数据已由 rec_reader 模块准备好
                        rbuf[0] <= rec_rd_b0;
                        rbuf[1] <= rec_rd_b1;
                        rbuf[2] <= rec_rd_b2;
                        rbuf[3] <= rec_rd_b3;
                        rbuf[4] <= rec_rd_b4;
                        rbuf[5] <= rec_rd_b5;
                        rbuf[6] <= rec_rd_b6;
                        rbuf[7] <= rec_rd_b7;
                        rbuf[8] <= rec_rd_b8;
                        rlen    <= rec_rd_len;
                        ridx    <= 4'd0;
                        rsend   <= 1'b1;
                        rdr_req <= 1'b0;
                        rd_ack  <= 1'b1;   // 通知 rec_reader 数据已取走
                    end
                end else begin
                    tx_data  <= rbuf[0];
                    tx_start <= 1'b1;
                    ridx     <= 4'd1;
                    tst      <= T_SEND;
                end
            end
            T_SEND: begin
                tx_start <= 1'b0;
                if (tx_busy) tst <= T_WAIT;
            end
            T_WAIT: begin
                if (!tx_busy) begin
                    if (ridx == rlen) begin
                        rsend <= 1'b0;
                        tst   <= T_IDLE;
                    end else begin
                        tx_data  <= rbuf[ridx];
                        tx_start <= 1'b1;
                        ridx     <= ridx + 4'd1;
                        tst      <= T_SEND;
                    end
                end
            end
            default: tst <= T_IDLE;
            endcase

            // ================= 收帧状态机 =================
            if (rx_valid) begin
                case (st)
                S_H0: begin
                    if (rx_data == 8'hAA) st <= S_H1;
                end
                S_H1: begin
                    if (rx_data == 8'h55)      st <= S_LEN;
                    else if (rx_data != 8'hAA) st <= S_H0;
                end
                S_LEN: begin
                    flen     <= rx_data;
                    sum_calc <= rx_data;
                    pidx     <= 8'd0;
                    pcnt     <= 9'd0;
                    evb      <= 2'd0;
                    st       <= S_CMD;
                end
                S_CMD: begin
                    fcmd     <= cin;
                    sum_calc <= sum_calc + cin;
                    if (!len_ok)               st <= S_H0;   // 命令/长度不合法，拒收
                    else if (flen == 8'd0)     st <= S_SUM;
                    else                       st <= S_PAY;
                end
                S_PAY: begin
                    if (fcmd == 8'h01) begin
                        if (pidx == 8'd0) dlslot <= rx_data[1:0];   // BEGIN：锁存下载槽号
                    end else if (fcmd == 8'h02) begin
                        if (pidx == 8'd0) begin
                            fidx <= {1'b0, rx_data};   // 起始事件序号（8 位 -> 9 位）
                            evb  <= 2'd0;
                        end else begin
                            case (evb)
                            2'd0:    ev_hi <= rx_data;              // 事件第 1 字节 [23:16]
                            2'd1:    ev_mi <= rx_data;              // 事件第 2 字节 [15:8]
                            default: begin                         // 事件第 3 字节 [7:0] -> 成组落盘
                                ram_wdata <= {ev_hi, ev_mi, rx_data};
                                ram_waddr <= {dlslot, waddr_calc[7:0]};
                                ram_we    <= (waddr_calc < 9'd256);  // 槽内越界拒写
                                pcnt      <= pcnt + 9'd1;
                            end
                            endcase
                            evb <= (evb == 2'd2) ? 2'd0 : evb + 2'd1;
                        end
                    end else if (fcmd == 8'h10) begin
                        if (pidx == 8'd0) cmd_song_id <= rx_data[2:0];
                    end else if (fcmd == 8'h23) begin
                        if (pidx == 8'd0) rd_idx <= rx_data;   // REC_READ：锁存起始序号
                    end
                    sum_calc <= sum_calc + rx_data;
                    pidx     <= pidx + 8'd1;
                    if (pidx + 8'd1 == flen) st <= S_SUM;
                end
                S_SUM: begin
                    if (rx_data == sum_calc) begin
                        case (fcmd)
                        8'h01: begin                       // BEGIN：开始下载（槽号已在 PAY 阶段锁存）
                            wptr      <= 9'd0;
                            dl_ok[dlslot] <= 1'b0;
                            dl_busy_r <= 1'b1;
                            ack_req   <= 1'b1;
                        end
                        8'h02: begin                       // DATA（校验通过才推进写指针）
                            wptr    <= fidx + pcnt;
                            ack_req <= 1'b1;
                        end
                        8'h03: begin                       // END
                            ram_wdata <= 24'h000000;       // 补曲终标记
                            ram_we    <= 1'b1;
                            ram_waddr <= {dlslot, wptr[7:0]};
                            dl_ok[dlslot] <= 1'b1;
                            dl_busy_r <= 1'b0;
                            ack_req   <= 1'b1;
                        end
                        8'h10: begin                       // PLAY
                            cmd_song_vld <= 1'b1;
                            ack_req      <= 1'b1;
                        end
                        8'h11: begin                       // STOP
                            cmd_stop <= 1'b1;
                            ack_req  <= 1'b1;
                        end
                        8'h12: begin                       // QUERY
                            stat_req <= 1'b1;
                        end
                        8'h13: begin                       // ERASE：清当前下载槽
                            wptr    <= 9'd0;
                            dl_ok[dlslot] <= 1'b0;
                            ack_req <= 1'b1;
                        end
                        8'h20: begin                       // REC_START：开始录制
                            rec_start <= 1'b1;
                            ack_req   <= 1'b1;
                        end
                        8'h21: begin                       // REC_STOP：停止录制
                            rec_stop  <= 1'b1;
                            ack_req   <= 1'b1;
                        end
                        8'h22: begin                       // REC_QUERY：查询录制状态
                            recq_req  <= 1'b1;
                        end
                        8'h23: begin                       // REC_READ：请求回读（T_IDLE 里读 RAM 组装）
                            rdr_req <= 1'b1;
                        end
                        default: ;
                        endcase
                        st <= S_H0;
                    end
                    // 校验错：不改写指针、不应答（主机重试，重传幂等）
                    if (rx_data != sum_calc) st <= S_H0;
                end

                default: st <= S_H0;
                endcase
            end

            // REC_READ 的 RAM 读取已并入发送状态机 T_RDR1，见上方
        end
    end
endmodule
