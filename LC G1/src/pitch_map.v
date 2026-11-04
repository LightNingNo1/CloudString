// ============================================================================
// pitch_map.v - 12bit 电压码 -> 频率比例因子（指数映射 + 线性插值）
// ----------------------------------------------------------------------------
// 映射规律：ratio(code) = 2^(code / 1346)，16.16 定点（1.0 = 65536）
//   code =    0            -> 1.00  （该弦空弦音，滑音区间下限）
//   code = 1346 (~1.65V)   -> 2.00  （空弦 +1 八度）
//   code = 2693 (~3.30V)   -> ~4.00 （空弦 +2 八度，区间上限）
// 【定标依据】滑音电位器 0~3.3V、ADC VA=5V（code = V*816）：令满程 3.3V
//   （code≈2693）恰好 = +2 个八度，故 K = 2693/2 ≈ 1346（见 tools/gen_pitch_tbl.py）。
// 即滑音范围 = 该弦定弦音高 ~ 向上两个八度（只升不降）。
// 各通道最终 inc = INC_BASE_k * ratio >> 16（在 pitch_32v 中完成）。
//
// 实现：pitch_tbl 同步给出 code[11:6] 处的 {T[a+1], T[a]}，段内线性插值。
// 流水线 4 拍：valid_in 起算，第 4 拍 valid_out 与 ratio 同时有效。
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

    // ---------------------------------------------------------------
    // 【120MHz 4 级流水】原 3 拍版把"表读出 -> t1-t0 -> (diff>>2)*frac -> +t0"
    //   整条组合链压在一拍里，PnR 实测 12.671ns（限 8.333ns），是音频域最差
    //   路径（占前 25 条里的 14 条）。现按算术边界拆成 4 拍：
    //     拍1  BSRAM 输出 tbl_dout（pitch_tbl 内建寄存器）
    //     拍2  寄存 t0 与 diff = t1 - t0
    //     拍3  寄存 mul = (diff>>2) * frac
    //     拍4  ratio = t0 + (mul>>4)，valid_out 同时有效
    //   算式与位宽与原版完全一致（乘/加均按 32bit 自决宽截断），只是多花 1 拍。
    //   pitch_32v 的 S_WAIT 是条件等待（if (vout)），会自动多等这一拍。
    // ---------------------------------------------------------------
    reg [5:0]  frac_r1, frac_r2;
    reg [31:0] t0_r, diff_r, mul_r;
    reg        v1, v2, v3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frac_r1   <= 6'd0;
            frac_r2   <= 6'd0;
            t0_r      <= 32'd0;
            diff_r    <= 32'd0;
            mul_r     <= 32'd0;
            v1        <= 1'b0;
            v2        <= 1'b0;
            v3        <= 1'b0;
            valid_out <= 1'b0;
            ratio     <= 32'd65536;   // 复位默认 1.0
        end else begin
            frac_r1   <= frac;
            frac_r2   <= frac_r1;
            t0_r      <= tbl_dout[31:0];
            diff_r    <= tbl_dout[63:32] - tbl_dout[31:0];
            mul_r     <= (diff_r >> 2) * frac_r2;
            v1        <= valid_in;
            v2        <= v1;
            v3        <= v2;
            valid_out <= v3;
            if (v3) ratio <= t0_r + (mul_r >> 4);
        end
    end
endmodule