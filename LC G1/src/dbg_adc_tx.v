// ============================================================================
// dbg_adc_tx.v - ADC 调试串口发送（115200 8N1，ASCII，引脚 F15）
// ----------------------------------------------------------------------------
// 每约 100ms 发送一行，逐通道回读最近一轮的原始 16bit SPI 帧：
//   R0=XXXX R1=XXXX R2=XXXX R3=XXXX R4=XXXX R5=XXXX R6=XXXX R7=XXXX
//   （Rk = ADC 通道 INk 的原始 16bit；CH0 对应 IN0，依此类推）
//
// 【怎么读】
//   原始帧 = 4 前导 0 + 8bit 数据 + 4 尾随 0（共 16 位）。
//   1) 看高 4 位（第 1 个十六进制位）：
//        0xxx -> DOUT 被 ADC 真正驱动，是有效转换结果
//        Fxxx -> DOUT 未被驱动（悬空/上拉），SPI 没通（查 CS/SCLK/DIN/DOUT 接线与电平）
//   2) 转某个通道的电位器，若只有对应 Rk 变化 -> SPI 与通道切换均正常
//   3) 若转动各路时所有 Rk 完全不变，或始终相同 -> 通道地址未生效（控制字/多路切换问题）
// ============================================================================
module dbg_adc_tx (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [127:0] raw_all,   // 8 通道原始 16bit，slot k = ch k：[16*k +: 16]
    output wire         tx
);
    // 帧周期：约 100ms @ 50MHz（10Hz 刷新）
    localparam [25:0] FRAME_PERIOD = 26'd5_000_000;

    // 每帧 66 字节：8 通道 × 8 字节 + \r\n
    //   pos 0..63 : 通道区，每通道 8 字节，token 形如 "R0=XXXX "
    //   pos 64    : '\r'
    //   pos 65    : '\n'
    localparam [6:0] POS_LAST = 7'd65;

    localparam [1:0] S_IDLE = 2'd0, S_SEND = 2'd1, S_DLY = 2'd2, S_WAIT = 2'd3;

    reg [1:0]  st;
    reg [6:0]  pos;        // 当前发送字节位置 0..65
    reg [25:0] timer;
    reg [7:0]  tx_data;
    reg        tx_start;
    wire       tx_busy;

    uart_tx u_tx (.clk(clk), .rst_n(rst_n), .data(tx_data), .start(tx_start),
                  .tx(tx), .busy(tx_busy));

    // 通道区索引：j = pos/8（通道号 0..7），r = pos%8（token 内字节号）
    wire [2:0]  j = pos[5:3];
    wire [2:0]  r = pos[2:0];
    wire [15:0] raw_cur = raw_all[16*j +: 16];   // 当前通道原始帧

    // 4bit 十六进制 -> ASCII（0~9 -> '0'~'9'，A~F -> 'A'~'F'）
    function [7:0] hex2asc;
        input [3:0] h;
        begin
            hex2asc = (h < 4'd10) ? (h + 8'h30) : (h + 8'h37);
        end
    endfunction

    // 当前要发送的字节（组合逻辑）
    always @(*) begin
        if (pos <= 7'd63) begin
            case (r)
                3'd0: tx_data = 8'h52;                    // 'R'
                3'd1: tx_data = 8'h30 + {5'd0, j};        // 通道号 '0'..'7'
                3'd2: tx_data = 8'h3D;                    // '='
                3'd3: tx_data = hex2asc(raw_cur[15:12]);  // 前导 4 位（关键：0=有效 / F=悬空）
                3'd4: tx_data = hex2asc(raw_cur[11:8]);
                3'd5: tx_data = hex2asc(raw_cur[7:4]);
                3'd6: tx_data = hex2asc(raw_cur[3:0]);
                default: tx_data = 8'h20;                 // 空格
            endcase
        end else if (pos == 7'd64) begin
            tx_data = 8'h0D;  // '\r'
        end else begin
            tx_data = 8'h0A;  // '\n'
        end
    end

    // 状态机：定时触发 -> 逐字节发送 -> 发完回空闲
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            pos      <= 7'd0;
            timer    <= 26'd0;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;  // 默认清除
            case (st)
                S_IDLE: begin
                    if (timer == FRAME_PERIOD - 1) begin
                        timer <= 26'd0;
                        pos   <= 7'd0;
                        st    <= S_SEND;
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end
                S_SEND: begin
                    tx_start <= 1'b1;   // 单周期脉冲
                    st       <= S_DLY;
                end
                S_DLY: begin
                    st <= S_WAIT;       // 等一拍让 busy 拉高
                end
                S_WAIT: begin
                    if (!tx_busy) begin
                        if (pos == POS_LAST) begin
                            st    <= S_IDLE;
                            timer <= 26'd0;
                        end else begin
                            pos <= pos + 1'b1;
                            st  <= S_SEND;
                        end
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule