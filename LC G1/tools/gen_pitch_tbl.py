#!/usr/bin/env python3
# ============================================================================
# gen_pitch_tbl.py - 生成 pitch_tbl.v（电压码 -> 频率比例因子 指数映射表）
# ----------------------------------------------------------------------------
# 映射：ratio(code) = 2^(code / K)，16.16 定点（1.0 = 65536）
#
#   K 的定标依据：滑音电位器为 0~3.3V、ADC 的 VA = 5V，
#   故电位器满程 3.3V -> code = 3.3/5*255*16 ≈ 2693，
#   令其恰好对应 +2 个八度（ratio = 4.0）：2^(2693/K) = 4  ->  K = 1346.5，
#   取整 K = 1346（误差 < 0.1%，1 个 code 约 0.006 半音）。
#
# 生成格式：64 行 x 64bit，第 a 行 = {T[a+1], T[a]}，addr = code[11:6]
#           T[code] = round(2^(code/K) * 65536)
# ============================================================================
import math
import os

K    = 1346.0   # 指数定标：八度数 = code / K
ROWS = 64       # 64 行，每行覆盖 64 个 code（addr = code[11:6]）
FIX  = 65536    # 16.16 定点 1.0

def T(code):
    return int(round((2.0 ** (code / K)) * FIX))

lines = []
lines.append("// ============================================================================")
lines.append("// pitch_tbl.v - 电压码 -> 频率比例因子 指数映射表（脚本生成，勿手改）")
lines.append("// ----------------------------------------------------------------------------")
lines.append("// 生成器 : tools/gen_pitch_tbl.py")
lines.append("// 内容   : ratio(code) = 2^(code/1346)，16.16 定点（1.0 = 65536）")
lines.append("//          定标使滑音电位器满程(0~3.3V, VA=5V, code≈2693)对应 +2 个八度(~4.0)")
lines.append("//          code=0 -> 1.0(空弦) ; code=1346 -> ~2.0(+1八度,1.65V) ; code=2693 -> ~4.0(+2八度,3.3V)")
lines.append("// 结构   : 64 行 x 64bit，第 a 行 = {T[a+1], T[a]}，addr = code[11:6]")
lines.append("// 读方式 : 同步读（posedge clk），整表落 BSRAM")
lines.append("// ============================================================================")
lines.append("module pitch_tbl(")
lines.append("    input  wire        clk,")
lines.append("    input  wire [5:0]  addr,")
lines.append("    output reg  [63:0] dout")
lines.append(");")
lines.append("    reg [63:0] rom [0:63];")
lines.append("    initial begin")
for a in range(ROWS):
    c0 = a * 64
    c1 = (a + 1) * 64
    t0 = T(c0)
    t1 = T(c1)
    lines.append("        rom[%2d] = 64'h%08X%08X;  // code=%4d  ratio=%.4f -> %.4f"
                 % (a, t1, t0, c0, t0 / FIX, t1 / FIX))
lines.append("    end")
lines.append("    always @(posedge clk) dout <= rom[addr];")
lines.append("endmodule")

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "pitch_tbl.v")
out = os.path.normpath(out)
with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print("wrote:", out)
print("K=%.1f  T[2048]=%.4f  T[2693]=%.4f  T[4096]=%.4f"
      % (K, T(2048) / FIX, T(2693) / FIX, T(4096) / FIX))