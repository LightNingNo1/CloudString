# -*- coding: utf-8 -*-
# 比较 实测 vw7 与 模型 vw 的谐波谱（稳态段），定位模型偏差
import math
from gen_old_5s import gen, read_dump, W

FS = 48000.0; F0 = 440.0
mix_r, vw_r = read_dump("mix_dump.txt")
NS = len(vw_r)
mix_m, vw_m = gen(NS)

def spec(seg, tag):
    N = len(seg)
    print("\n%s  N=%d  max=%d min=%d rms=%.1f" %
          (tag, N, max(seg), min(seg), math.sqrt(sum(x*x for x in seg)/N)))
    amps = []
    for k in range(1, 17):
        w = 2*math.pi*F0*k/FS
        c = s = 0.0
        for i, x in enumerate(seg):
            c += x*math.cos(w*i); s += x*math.sin(w*i)
        amps.append(2.0/N*math.hypot(c, s))
    base = amps[0]
    print(" n   实测/模型 幅度   理论W[n]  相对基音dB(实/模)  理论dB")
    for k in range(16):
        got = 20*math.log10(max(amps[k],1e-9)/base) if base else 0
        exp = 20*math.log10(W[k]/W[0])
        print("%3d  %9.0f        %6d      %6.1f / %6.1f" % (k+1, amps[k], W[k], got, exp))
    return amps

# 稳态段（对齐 off=1，模型 1 帧偏早）
A = 2000; B = 2400
spec([vw_r[i] for i in range(A, B)], "实测 vw7")
spec([vw_m[i-1] for i in range(A, B)], "模型 vw ")