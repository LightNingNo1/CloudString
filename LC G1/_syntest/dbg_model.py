# -*- coding: utf-8 -*-
import math
from gen_old_5s import gen, read_dump, W, SH, SINE, TEST_INC

mix_r, vw_r = read_dump("mix_dump.txt")
NS = len(vw_r)
mix_m, vw_m = gen(NS)
print("W =", W)
print("SH=", SH)

# 手算一个"理想"16泛音锯齿（无衰减、无表量化），与模型比较
def ideal(f, ph0=0):
    ph = (ph0 + (f+1)*TEST_INC) & 0xFFFFFFFF
    return sum(W[n-1]*math.sin(2*math.pi*(n*ph)/2**32) for n in range(1,17))

print("\n f   模型vw   实测vw7   理想(无量化)")
for f in range(2000, 2040):
    print("%5d  %7d  %7d  %8.0f" % (f, vw_m[f], vw_r[f+1], ideal(f)))

# 模型基频：过零间隔统计
zc = [i for i in range(2100, 2400) if vw_m[i] >= 0 > vw_m[i+1]]
print("\n模型下降过零点间隔:", [zc[k+1]-zc[k] for k in range(min(6, len(zc)-1))])
zc2 = [i for i in range(2100, 2400) if vw_r[i] >= 0 > vw_r[i+1]]
print("实测下降过零点间隔:", [zc2[k+1]-zc2[k] for k in range(min(6, len(zc2)-1))])