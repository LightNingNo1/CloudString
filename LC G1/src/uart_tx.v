// ============================================================================
// uart_tx.v - 115200 8N1 串口发送（50MHz 时钟）
// ----------------------------------------------------------------------------
// 分频原理与 uart_rx.v 相同：1 位 = 15625/36 = 434.0278 拍。
// start 为单周期脉冲，把 data 装载后依次发出：起始位(0) -> 8 位数据(LSB 先)
// -> 停止位(1)。发送期间 busy=1。
// ============================================================================
module uart_tx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx,
    output reg        busy
);
    localparam [15:0] BAUD_MOD = 16'd15625;
    localparam [15:0] BAUD_INC = 16'd36;

    reg [1:0]  st;      // 0=空闲 1=起始位 2=数据位 3=停止位
    reg [2:0]  bi;
    reg [7:0]  sh;
    reg [15:0] acc;

    wire [16:0] acc_nxt   = {1'b0, acc} + {1'b0, BAUD_INC};
    wire        baud_tick = (acc_nxt >= {1'b0, BAUD_MOD});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= 2'd0;
            bi   <= 3'd0;
            sh   <= 8'd0;
            acc  <= 16'd0;
            tx   <= 1'b1;
            busy <= 1'b0;
        end else begin
            // 位节拍累加器（空闲态由下面的 case 复位成 0）
            if (baud_tick) acc <= acc_nxt[15:0] - BAUD_MOD;
            else           acc <= acc_nxt[15:0];

            case (st)
            2'd0: begin                       // 空闲
                tx   <= 1'b1;
                busy <= 1'b0;
                acc  <= 16'd0;
                if (start) begin
                    sh   <= data;
                    tx   <= 1'b0;             // 起始位
                    busy <= 1'b1;
                    st   <= 2'd1;
                    bi   <= 3'd0;
                end
            end
            2'd1: begin                       // 起始位发完 -> 数据位 0
                if (baud_tick) begin
                    tx <= sh[0];
                    sh <= {1'b0, sh[7:1]};
                    st <= 2'd2;
                end
            end
            2'd2: begin                       // 数据位 1..7
                if (baud_tick) begin
                    if (bi == 3'd7) begin
                        tx <= 1'b1;           // 停止位
                        st <= 2'd3;
                    end else begin
                        tx <= sh[0];
                        sh <= {1'b0, sh[7:1]};
                        bi <= bi + 3'd1;
                    end
                end
            end
            2'd3: begin                       // 停止位发完
                if (baud_tick) st <= 2'd0;
            end
            default: st <= 2'd0;
            endcase
        end
    end
endmodule
