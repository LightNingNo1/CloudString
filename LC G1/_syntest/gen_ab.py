# -*- coding: utf-8 -*-
# gen_ab.py - 生成 C4 参考音 A/B，用于区分"合成音色"与"输出链路"问题
#   三个样本同一包络（30ms 起音 + 指数衰减），仅谐波配比不同：
#     c4_pure    : 只有基音（纯正弦）
#     c4_cur     : 1/n^1.5（当前 RTL 实测配比）
#     c4_mellow  : 1/n^2  （更柔和/更清澈）
#   用法: py -3 gen_ab.py
import math, wave, struct

FS = 48000.0
F0 = 261.6256
DUR = 1.0
A_CNT = 1440          # 30ms 起音
TAU = 2.73 * FS       # 拨弦释放时间常数（2^17 拍 @48kHz ≈ 2.73s）
NH = 16
N = int(FS * DUR)

def weights(p):
    s = sum(1.0/(k**p) for k in range(1, NH+1))
    return [ (1.0/(k**p))/s for k in range(1, NH+1) ]

def gen(name, p, nh):
    w = weights(p) if p else None
    data = []
    prod = 1.0
    cnt = 0
    for i in range(N):
        if cnt < A_CNT:
            amp = (cnt+1)*23.0/32768.0
            if amp > 1.0: amp = 1.0
            cnt += 1
        else:
            prod *= (1.0 - 1.0/TAU)
            amp = prod
        ph = 2*math.pi*F0*i/FS
        if nh == 1:
            v = math.cos(ph)
        else:
            v = 0.0
            for k in range(nh):
                v += w[k]*math.cos((k+1)*ph)
        data.append(amp*v)
    pk = max(abs(x) for x in data) or 1.0
    sc = 26000.0/pk
    out = [int(max(-32767, min(32767, x*sc))) for x in data]
    with wave.open(name, 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(int(FS))
        f.writeframes(b''.join(struct.pack('<h', x) for x in out))
    print("%s  峰值=%d" % (name, max(abs(x) for x in out)))

if __name__ == '__main__':
    gen("c4_pure.wav",   None, 1)
    gen("c4_cur.wav",    1.5,  NH)
    gen("c4_mellow.wav", 2.0,  NH)
    print("done")