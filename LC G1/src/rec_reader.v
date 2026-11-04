// ============================================================================
// rec_reader.v - 录制 RAM 回读引擎（独立模块，减轻 ble_link 布线压力）
// ----------------------------------------------------------------------------
// 收到 rd_req 脉冲后，从录制 RAM 读 1 个事件，组装 9 字节应答帧，
// 组装完成后置 rd_valid（粘滞，由 ble_link 取走后清）。
//
// 应答帧：AA 55 LEN A3 IDX ev_b2 ev_b1 ev_b0 SUM
//   - 曲终事件（0 事件）：LEN=1，6 字节
//   - 普通 1 事件：LEN=4，9 字节
//
// 输出采用 9 字节并行寄存器（rdata[0]..rdata[8]），避免 rbuf 数组的布线拥塞。
// ============================================================================
module rec_reader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rd_req,        // 读请求脉冲
    input  wire [7:0]  rd_idx,        // 起始事件序号
    input  wire [23:0] ram_rdata,     // RAM 读数据（同步读 1 拍延迟）
    output reg  [7:0]  ram_raddr,     // RAM 读地址
    output reg  [7:0]  rd_byte0,      // 应答帧字节 0
    output reg  [7:0]  rd_byte1,
    output reg  [7:0]  rd_byte2,
    output reg  [7:0]  rd_byte3,
    output reg  [7:0]  rd_byte4,
    output reg  [7:0]  rd_byte5,
    output reg  [7:0]  rd_byte6,
    output reg  [7:0]  rd_byte7,
    output reg  [7:0]  rd_byte8,
    output reg  [3:0]  rd_len,         // 应答帧总长度（6 或 9）
    output reg         rd_valid       // 数据有效（粘滞，取走后清）
);

    reg [1:0] st;
    localparam [1:0] S_IDLE = 2'd0,
                     S_WAIT = 2'd1,
                     S_SEND = 2'd2,
                     S_DONE = 2'd3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            ram_raddr <= 8'd0;
            rd_valid <= 1'b0;
            rd_len   <= 4'd0;
            rd_byte0 <= 8'd0;
            rd_byte1 <= 8'd0;
            rd_byte2 <= 8'd0;
            rd_byte3 <= 8'd0;
            rd_byte4 <= 8'd0;
            rd_byte5 <= 8'd0;
            rd_byte6 <= 8'd0;
            rd_byte7 <= 8'd0;
            rd_byte8 <= 8'd0;
        end else begin
            case (st)
            S_IDLE: begin
                if (rd_req) begin
                    ram_raddr <= rd_idx;
                    rd_valid  <= 1'b0;
                    st        <= S_WAIT;
                end else begin
                    rd_valid  <= 1'b0;   // 空闲时保持无效，避免下一轮 ble_link 立即取到旧数据
                end
            end
            S_WAIT: begin
                // 等 RAM 同步读 1 拍
                st <= S_SEND;
            end
            S_SEND: begin
                rd_byte0 <= 8'hAA;
                rd_byte1 <= 8'h55;
                rd_byte3 <= 8'hA3;
                rd_byte4 <= rd_idx;
                if (ram_rdata == 24'h000000) begin
                    // 0 事件（曲终）：6 字节
                    rd_byte2 <= 8'd1;
                    rd_byte5 <= (8'd1 + 8'hA3 + rd_idx) & 8'hFF;
                    rd_len   <= 4'd6;
                end else begin
                    // 1 事件：9 字节
                    rd_byte2 <= 8'd4;
                    rd_byte5 <= ram_rdata[23:16];
                    rd_byte6 <= ram_rdata[15:8];
                    rd_byte7 <= ram_rdata[7:0];
                    rd_byte8 <= (8'd4 + 8'hA3 + rd_idx
                                 + ram_rdata[23:16] + ram_rdata[15:8] + ram_rdata[7:0]) & 8'hFF;
                    rd_len   <= 4'd9;
                end
                rd_valid <= 1'b1;
                st       <= S_DONE;
            end
            S_DONE: begin
                // 数据保持有效，等 rd_req 变低（ble_link 取走后清）再回空闲
                if (!rd_req) st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
