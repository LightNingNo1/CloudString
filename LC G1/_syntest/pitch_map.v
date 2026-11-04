// ============================================================================
// pitch_map.v - 12bit 电压码 -> 频率比例因子（指数映射 + 线性插值）
// ----------------------------------------------------------------------------
// 映射规律：ratio(code) = 2^(code / 2048)，16.16 定点（1.0 = 65536）
//   code =    0 (0V)    -> 1.00  （该弦空弦音，滑音区间下限）
//   code = 2048 (1.65V) -> 2.00  （空弦 +1 八度，区间中点）
//   code = 4095 (3.3V)  -> ~4.00 （空弦 +2 八度，区间上限）
// 即滑音范围 = 该弦定弦音高 ~ 向上两个八度（只升不降）。
// 各通道最终 inc = INC_BASE_k * ratio >> 16（在 pitch_bank8 中完成）。
//
// 实现：pitch_tbl 同步给出 code[11:6] 处的 {T[a+1], T[a]}，段内线性插值。
// 流水线 3 拍：valid_in 起算，第 3 拍 valid_out 与 ratio 同时有效。
// ============================================================================
module pitch_map(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire [11:0] code,
    output reg         valid_out,
    output reg  [31:0] ratio        // 16.16 定点比例因子
);
    wire [5:0]  a    = code[11:6];
    wire [5:0]  frac = code[5:0];

    wire [63:0] tbl_dout;
    pitch_tbl u_tbl (.clk(clk), .addr(a), .dout(tbl_dout));

    wire [31:0] t0     = tbl_dout[31:0];
    wire [31:0] t1     = tbl_dout[63:32];
    wire [31:0] diff   = t1 - t0;
    wire [31:0] interp = t0 + (((diff >> 2) * frac_r) >> 4);

    reg [5:0] frac_r;
    reg       v1, v2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frac_r    <= 6'd0;
            v1        <= 1'b0;
            v2        <= 1'b0;
            valid_out <= 1'b0;
            ratio     <= 32'd65536;   // 复位默认 1.0
        end else begin
            frac_r    <= frac;
            v1        <= valid_in;
            v2        <= v1;
            valid_out <= v2;
            if (v2) ratio <= interp;
        end
    end
endmodule