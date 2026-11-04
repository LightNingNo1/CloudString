# -*- coding: utf-8 -*-
# ============================================================================
# dump2wav.py - 把 tb_dump.v 导出的 mix_dump.txt 转成 WAV，并做纯净度分析
#   · 统计：静音段、峰值(dBFS)、削波点数
#   · 拟合 440Hz 16 个谐波的幅度/相位 -> 与理论 W[n] 对比、算 THD+N 残差
#   · 非谐波频点探针：量化"杂散/不纯净"程度
#   · 输出 <name>.wav（原始电平）与 <name>_norm.wav（归一化到 -1dBFS）
# 用法: py -3 dump2wav.py mix_dump.txt out_name [new|old] [f0]
#   f0: 分析用基频（默认 261.63 = C4）；拨弦 C5 用 523.25，拉弦第二弦 C3 用 130.81
# ============================================================================
import sys, math, wave, struct

FS = 48000.0
F0 = 261.63
WN = [15327, 4197, 5284, 1577, 4986, 628] + [0]*10   # 当前 additive_engine.v 的 W_TBL_PLK（拨弦/竖琴谱）
_H16 = sum(1.0/k for k in range(1, 17))
WN_OLD = [round(32768.0/(k*_H16)) for k in range(1, 17)]                                      # 1/n（旧）
FULL24 = 8388607.0

def main(fname, outname, tbl="new", f0=None):
    global WN, F0
    if tbl == "old":
        WN = WN_OLD
    if f0 is not None:
        F0 = float(f0)
    mix = []
    vw = []
    with open(fname) as f:
        for line in f:
            a = line.split()
            if len(a) == 2:
                mix.append(int(a[0])); vw.append(int(a[1]))
    n = len(mix)
    print("samples = %d (%.3f s)" % (n, n/FS))

    # ---- 静音段与电平统计 ----
    silent = 0
    while silent < n and mix[silent] == 0: silent += 1
    pk25 = max(abs(v) for v in mix)
    clips = sum(1 for v in mix if abs(v) >= 8388607)
    print("前置静音帧 = %d（数字静音必须精确为 0）" % silent)
    print("mix 峰值 = %d (%.2f dBFS, %d/8388607)  削波点 = %d" %
          (pk25, 20*math.log10(max(pk25,1)/FULL24), pk25, clips))
    print("vw7 峰值 = %d（饱和阈值 32767）" % max(abs(v) for v in vw))

    # ---- 稳态窗口拟合 16 个谐波（帧 400..2200，约 37.5ms）----
    a, b = 400, min(2200, n)
    seg = [mix[t]/32768.0 for t in range(a, b)]   # 换算到 16bit 量纲便于读数
    N = len(seg)
    base = 0.0; coef = []
    for k in range(1, 17):
        w = 2*math.pi*F0*k/FS
        c = s = 0.0
        for i, x in enumerate(seg):
            c += x*math.cos(w*i); s += x*math.sin(w*i)
        c *= 2.0/N; s *= 2.0/N
        coef.append((c, s))
    base = math.hypot(*coef[0])
    print("\n谐波拟合（窗口 %d..%d，基音幅度 %.0f LSB16）" % (a, b, base))
    print(" n  实测dB  理论dB(Wn)  偏差")
    for k in range(16):
        amp = math.hypot(*coef[k])
        got = 20*math.log10(max(amp, 1e-9)/base) if k > 0 else 0.0
        if WN[k] > 0:
            exp = 20*math.log10(WN[k]/WN[0])
            print("%3d  %6.1f  %8.1f  %+5.1f" % (k+1, got, exp, got-exp))
        else:
            print("%3d  %6.1f  %8s  %5s" % (k+1, got, "-inf", "--"))

    # ---- 残差（THD+N）：减去 16 谐波后的剩余能量 ----
    res2 = 0.0
    for i, x in enumerate(seg):
        r = x
        for k in range(16):
            w = 2*math.pi*F0*k/FS
            r -= coef[k][0]*math.cos(w*i) + coef[k][1]*math.sin(w*i)
        res2 += r*r
    res_rms = math.sqrt(res2/N) if N else 0
    print("\n残差(谐波外全部成分) RMS = %.2f LSB16 -> %.1f dBc（相对基音）" %
          (res_rms, 20*math.log10(max(res_rms,1e-9)/(base/math.sqrt(2)))))

    # ---- 非谐波探针（谐波间半整数倍频点，随 F0 缩放）----
    print("非谐波频点探针（相对基音 dB）:")
    for m in [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 9.5]:
        fprobe = m*F0
        w = 2*math.pi*fprobe/FS
        c = s = 0.0
        for i, x in enumerate(seg):
            c += x*math.cos(w*i); s += x*math.sin(w*i)
        amp = 2.0/N*math.hypot(c, s)
        print("  %7.1f Hz : %6.1f dB" % (fprobe, 20*math.log10(max(amp,1e-9)/base)))

    # ---- 基频估计（F0 ± 6Hz 扫描相关峰）----
    best = (0, 0.0)
    ff = F0 - 6.0
    while ff <= F0 + 6.0:
        w = 2*math.pi*ff/FS
        c = s = 0.0
        for i, x in enumerate(seg):
            c += x*math.cos(w*i); s += x*math.sin(w*i)
        v = math.hypot(c, s)
        if v > best[1]: best = (ff, v)
        ff += 0.05
    print("\n基频估计 = %.2f Hz（理论 %.2f）" % (best[0], F0))

    # ---- 写 WAV（先把 24bit 转成 16bit，归一化在 16bit 量纲上做）----
    def write_wav(path, s16):
        with wave.open(path, 'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
            frames = b''.join(struct.pack('<h', max(-32768, min(32767, v))) for v in s16)
            w.writeframes(frames)
    raw16 = [v >> 8 for v in mix]
    pk16 = max(abs(v) for v in raw16) if raw16 else 0
    write_wav(outname + ".wav", raw16)
    scale = (29000.0/pk16) if pk16 else 1.0
    write_wav(outname + "_norm.wav", [int(v*scale) for v in raw16])
    print("已写 %s.wav（原始电平, 峰值 %d/32767） 与 %s_norm.wav（归一化到 29000）" %
          (outname, pk16, outname))

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else "mix_dump.txt",
         sys.argv[2] if len(sys.argv) > 2 else "d11",
         sys.argv[3] if len(sys.argv) > 3 else "new",
         sys.argv[4] if len(sys.argv) > 4 else None)