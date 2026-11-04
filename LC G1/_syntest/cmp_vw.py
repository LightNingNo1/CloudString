# -*- coding: utf-8 -*-
# 对比模型 vw 与实测 vw7（对齐后），定位误差来源
import math
from gen_old_5s import gen, read_dump

mix_r, vw_r = read_dump("mix_dump.txt")
# 模型只跑实测长度即可
NS = len(vw_r)
# 复用 gen：但 gen 按 F_ON 生成，重跑一次
mix_m, vw_m = gen(NS)

L = NS
for off in (0, 1, 2):
    errs = [abs(vw_m[i-off] - vw_r[i]) for i in range(off, L)]
    rms = math.sqrt(sum(e*e for e in errs)/len(errs))
    print("off=%d  max=%d rms=%.1f" % (off, max(errs), rms))

off = 1
print("\n逐帧（off=%d）  real vs model：" % off)
for i in list(range(2, 24)) + list(range(200, 208)) + list(range(600, 608)):
    print("f=%6d  real=%7d  model=%7d  d=%6d" % (i, vw_r[i], vw_m[i-off], vw_r[i]-vw_m[i-off]))

# 最大误差出现在哪
errs = [(abs(vw_m[i-off]-vw_r[i]), i) for i in range(off, L)]
errs.sort(reverse=True)
print("\n误差最大的 10 帧：", [(i, e) for e, i in errs[:10]])
# 前 50 帧、稳态段分别统计
for lo, hi, tag in [(off, 60, "起音段"), (2000, 8000, "稳态段")]:
    e = [abs(vw_m[i-off]-vw_r[i]) for i in range(lo, hi)]
    print("%s[%d..%d): max=%d rms=%.1f" % (tag, lo, hi, max(e), math.sqrt(sum(x*x for x in e)/len(e))))