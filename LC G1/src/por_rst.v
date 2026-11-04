// ============================================================================
// por_rst.v - 上电复位（Power-On Reset）
// ----------------------------------------------------------------------------
// 50MHz 下计数 2^21 拍 ≈ 42ms，期间拉低 rst_n，之后拉高并保持。
// 整个系统的异步复位低有效信号都由本模块产生。
// ============================================================================
module por_rst (
    input  wire clk,        // 50 MHz
    output reg  rst_n       // 异步复位，低有效
);
    localparam [20:0] POR_MAX = 21'h1FFFFF;

    reg [20:0] por_cnt = 21'd0;

    always @(posedge clk) begin
        if (por_cnt != POR_MAX) begin
            por_cnt <= por_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end
endmodule