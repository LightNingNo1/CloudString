# -*- coding: utf-8 -*-
# ============================================================================
# gen_harp.py - 竖琴音色候选生成（复用 gen_old_5s.py 里已用实测校准的 RTL 模型）
#   竖琴三要素：
#     1) 高次泛音快速衰减（SH[n] 随 n 下降）——"亮起音 + 暖余韵"
#     2) 基音长余韵（SH[1] 拉长 + ADSR 释放变慢）
#     3) 起音柔、无硬切（起音变慢 + 去掉满幅后 25% 的"初跌"）
#   本版对比：起音长度（5.3/10.7/21.3ms）与是否保留初跌，以及频谱亮度 α。
# 用法: py -3 gen_harp.py
# ============================================================================
import math, wave, struct
from gen_old_5s import SINE, read_dump

FS = 48000

# ---- 竖琴衰减表（SH[n]，τ=2^SH/48000 秒）----
SH_HARP = [17,16,15,15,14,14,13,13,13,12,12,12,11,11,11,11]
# 对应 τ(s): 2.73 1.37 .68 .68 .34 .34 .17 .17 .17 .085 .085 .085 .043 .043 .043 .043

REL_SHIFT = 17          # 拨弦释放右移（2^17 拍 = 2.73s，长余韵）
GATE_AMP  = 64          # 噪声门（收尾无硬切）
F_ON      = 4
F_TONE    = 261.63      # 测试音高 C4
inc_of    = lambda f: int(round(f/float(FS)*(1 << 32)))
INC_TONE  = inc_of(F_TONE)

def sat16(x):
    return 32767 if x > 32767 else (-32768 if x < -32768 else x)

def W_from_alpha(alpha):
    S = sum(n ** (-alpha) for n in range(1, 17))
    return [round(32768.0/((n**alpha)*S)) for n in range(1, 17)]

def gen(NS, W, SH, a_cnt=256, fast_drop=True, inc=INC_TONE,
        rel_shift=REL_SHIFT, gate=GATE_AMP):
    """a_cnt = 起音采样点数；fast_drop = 满幅后是否做 25% 初跌（RTL 的 FASTDECAY）"""
    S_IDLE, S_ATT, S_FAST, S_REL = 0, 1, 2, 3
    st, cnt, prod, amp = S_IDLE, 0, 0, 0
    h  = [0]*16
    ph = 0
    mix = [0]*NS
    ascale = 32768.0/a_cnt
    full = 32767 << 16
    for f in range(NS):
        if f == F_ON:
            st, cnt, amp, prod = S_ATT, 0, 0, full
        else:
            if st == S_IDLE:
                amp = 0
            elif st == S_ATT:
                if cnt >= a_cnt:
                    amp, cnt, prod = 32767, 0, full
                    st = S_FAST if fast_drop else S_REL
                else:
                    amp = int(cnt*ascale); cnt += 1
            elif st == S_FAST:
                if prod <= full - (full >> 2):
                    st = S_REL
                else:
                    prod -= (prod >> 10); amp = prod >> 16
            elif st == S_REL:
                if amp <= gate:
                    amp, st, cnt = 0, S_IDLE, 0
                else:
                    prod -= (prod >> rel_shift); amp = prod >> 16
        env_f = amp
        ph = (ph + inc) & 0xFFFFFFFF
        vacc = 0
        for n in range(16):
            a_n = h[n] >> 16
            s = SINE[(((n+1)*ph) & 0xFFFFFFFF) >> 20]
            vacc += (s * a_n) >> 15
        vw = sat16(vacc)
        for n in range(16):
            if f == F_ON:
                h[n] = W[n] << 16
            elif h[n]:
                h[n] -= max(h[n] >> SH[n], 1)
        mix[f] = (vw * env_f) >> 9
    return mix

def write_wav(path, raw):
    s16 = [x >> 8 for x in raw]
    pk  = max(abs(x) for x in s16) or 1
    sc  = 29000.0/pk
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(FS)
        w.writeframes(b''.join(struct.pack('<h', max(-32768, min(32767, int(x*sc)))) for x in s16))
    return pk

NS = int(FS*5.0)

# (标签, α, 起音点数, 是否初跌)   起音点数: 256=5.33ms 512=10.7ms 1024=21.3ms
CONFIGS = [
    ("harp_soft21",     1.5, 1024, False),   # 上一轮 21.3ms（对照）
    ("harp_att30",      1.5, 1440, False),   # 起音 30ms
    ("harp_att30_warm", 1.7, 1440, False),   # 起音 30ms + 更暖(α=1.7)
]
print("音高 = %.2f Hz (inc=%d)   release tau=2^%d   gate=%d" %
      (F_TONE, INC_TONE, REL_SHIFT, GATE_AMP))
for tag, alpha, a_cnt, fd in CONFIGS:
    W   = W_from_alpha(alpha)
    mix = gen(NS, W, SH_HARP, a_cnt=a_cnt, fast_drop=fd)
    pk24 = max(abs(x) for x in mix) or 1
    write_wav("%s.wav" % tag, mix)
    # 前 60ms 的包络（每 5ms 峰值），看起音陡峭度
    env = [max(abs(x) for x in mix[int(k*0.005*FS):int((k+1)*0.005*FS)]) for k in range(12)]
    lv  = [20*math.log10(max(s,1)/pk24) for s in env]
    print("%-17s α=%.1f 起音%4d(%.1fms) 初跌=%-5s  前60ms峰值dB: %s" %
          (tag, alpha, a_cnt, 1000.0*a_cnt/FS, str(fd),
           " ".join("%+.0f" % x for x in lv)))
print("\n已写 harp_soft21 / harp_att30 / harp_att30_warm.wav")