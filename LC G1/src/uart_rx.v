// ============================================================================
// uart_rx.v - 115200 8N1 串口接收（50MHz 时钟）
// ----------------------------------------------------------------------------
// 50MHz / 115200 = 434.0278，不是整数。这里用小数分频累加器：
//   把 1 个位周期表示为 15625 个刻度、每个 clk 累加 36 个刻度，
//   则 15625/36 = 434.0278 恰好等于要求的分频比（无累积误差）。
//   溢出即产生一次位节拍 baud_tick。
// 起始位下降沿后把累加器预置成半位(7812)，于是首个 baud_tick 正好落在
// 起始位中点，其后每个 baud_tick 依次落在各数据位与停止位中点。
// 数据 LSB 先收，停止位为高才认为帧有效。
// ============================================================================
module uart_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,          // 空闲=1
    output reg  [7:0] data,
    output reg        valid        // 收完一字节，单周期脉冲
);
    localparam [15:0] BAUD_MOD = 16'd15625;   // 1 位 = 434.0278 拍，放大 36 倍
    localparam [15:0] BAUD_INC = 16'd36;
    localparam [15:0] HALF_MOD = 16'd7812;    // 半位

    reg  [1:0]  st;      // 0=空闲 1=起始位 2=数据位 3=停止位
    reg  [2:0]  bi;
    reg  [7:0]  sh;
    reg  [15:0] acc;
    reg         rx_s1, rx_s2;

    wire [16:0] acc_nxt   = {1'b0, acc} + {1'b0, BAUD_INC};
    wire        baud_tick = (acc_nxt >= {1'b0, BAUD_MOD});

    // 两级同步，防亚稳态
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s1 <= 1'b1; rx_s2 <= 1'b1;
        end else begin
            rx_s1 <= rx; rx_s2 <= rx_s1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= 2'd0;
            bi    <= 3'd0;
            sh    <= 8'd0;
            acc   <= 16'd0;
            data  <= 8'd0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (st)
            2'd0: begin                       // 空闲：等起始位下降沿
                if (!rx_s2) begin
                    acc <= HALF_MOD;          // 预置半位
                    st  <= 2'd1;
                end else begin
                    acc <= 16'd0;
                end
            end
            2'd1: begin                       // 起始位中点
                if (baud_tick) begin
                    acc <= acc_nxt[15:0] - BAUD_MOD;
                    if (!rx_s2) begin          // 仍是低 -> 真起始位
                        st <= 2'd2;
                        bi <= 3'd0;
                    end else begin
                        st <= 2'd0;            // 毛刺
                    end
                end else begin
                    acc <= acc_nxt[15:0];
                end
            end
            2'd2: begin                       // 8 个数据位，LSB 先
                if (baud_tick) begin
                    acc <= acc_nxt[15:0] - BAUD_MOD;
                    sh  <= {rx_s2, sh[7:1]};
                    if (bi == 3'd7) st <= 2'd3;
                    else            bi <= bi + 3'd1;
                end else begin
                    acc <= acc_nxt[15:0];
                end
            end
            2'd3: begin                       // 停止位中点
                if (baud_tick) begin
                    acc <= acc_nxt[15:0] - BAUD_MOD;
                    if (rx_s2) begin
                        data  <= sh;
                        valid <= 1'b1;
                    end
                    st <= 2'd0;
                end else begin
                    acc <= acc_nxt[15:0];
                end
            end
            default: st <= 2'd0;
            endcase
        end
    end
endmodule
