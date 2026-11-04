# -*- coding: utf-8 -*-
# ============================================================================
# rec_analyze.py - 分析上板录音 rec_input.wav（前2声=拨弦，后1声=拉弦）
#   1) 自动切出各次发声段
#   2) 估基频 f0（抛物线插值）
#   3) 各时间窗谐波谱(dB 相对基音) + 基音衰减速率
#   4) 整体包络 / 削波 / 噪声底
#   5) 与参考竖琴/小提琴采样、与 PC 模型输出对照
# 用法: py -3 rec_analyze.py
# ============================================================================
import os, math, wave
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
FS = 48000

def load_wav(path):
    with wave.open(path, 'rb') as w:
        n = w.getnframes(); ch = w.getnchannels(); sw = w.getsampwidth()
        raw = w.readframes(n)
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0
    if ch > 1: x = x.reshape(-1, ch).mean(axis=1)
    return x, w.getframerate() if False else FS

def rms_env(x, hop=0.01):
    h = int(hop*FS); n = len(x)//h
    e = np.array([math.sqrt(np.mean(x[k*h:(k+1)*h]**2)) for k in range(n)])
    return e, hop

def find_segments(x, thr_db=-38.0, min_gap=0.15):
    e, hop = rms_env(x)
    pk = e.max(); thr = pk*10**(thr_db/20.0)
    on = e > thr
    segs = []; i = 0; N = len(on)
    while i < N:
        if on[i]:
            j = i
            while j < N and on[j]: j += 1
            segs.append((i*hop, j*hop))
            i = j
        else:
            i += 1
    # 合并间隔过近的段
    merged = []
    for s in segs:
        if merged and s[0]-merged[-1][1] < min_gap:
            merged[-1] = (merged[-1][0], s[1])
        else: merged.append(list(s))
    # 丢掉太短的
    return [tuple(m) for m in merged if m[1]-m[0] > 0.08]

def est_f0(x, t0, dur, lo=55, hi=1600):
    i0 = int(t0*FS); i1 = min(int((t0+dur)*FS), len(x))
    seg = x[i0:i1]
    if len(seg) < 256: return 0.0
    seg = (seg-seg.mean())*np.hanning(len(seg))
    N = 1 << 18
    sp = np.abs(np.fft.rfft(seg, N)); fr = np.fft.rfftfreq(N, 1.0/FS)
    m = (fr >= lo) & (fr <= hi)
    k = np.argmax(sp[m]) + np.searchsorted(fr, lo)
    # 抛物线插值
    if 0 < k < len(sp)-1:
        a, b, c = sp[k-1], sp[k], sp[k+1]
        d = 0.5*(a-c)/(a-2*b+c) if (a-2*b+c) != 0 else 0
        f0 = fr[k] + d*(fr[1]-fr[0])
    else:
        f0 = fr[k]
    return f0

def harm_db(x, f0, t0, dur, nh=16, half=8.0):
    i0 = int(t0*FS); i1 = min(int((t0+dur)*FS), len(x))
    seg = x[i0:i1]
    if len(seg) < 128: return None
    seg = (seg-seg.mean())*np.hanning(len(seg))
    N = 1 << 18
    sp = np.abs(np.fft.rfft(seg, N)); fr = np.fft.rfftfreq(N, 1.0/FS)
    def pk(fc):
        lo = np.searchsorted(fr, fc-half); hi = np.searchsorted(fr, fc+half)
        return sp[lo:hi].max() if hi > lo else 1e-12
    a = np.array([pk((n+1)*f0) for n in range(nh)])
    return 20*np.log10(np.maximum(a, 1e-12)/max(a[0], 1e-12))

def env_at(x, t0, hop=0.02):
    h = int(hop*FS); k = int(t0/h)
    seg = x[k*h:(k+1)*h]
    return 20*math.log10(max(math.sqrt(np.mean(seg**2)), 1e-9))

NOTES = {'C3':130.81,'C4':261.63,'D4':293.66,'G3':196.00,'G4':392.00,
         'A4':440.00,'C5':523.25,'E5':659.26,'B4':493.88,'D5':587.33}

x, _ = load_wav(os.path.join(HERE, 'rec_input.wav'))
print("rec: %.2fs  peak=%.3f  rms=%.4f" % (len(x)/FS, np.max(np.abs(x)),
      math.sqrt(np.mean(x**2))))
clip = np.sum(np.abs(x) >= 0.998)
print("削波样本数 = %d (%.4f%%)" % (clip, 100.0*clip/len(x)))

segs = find_segments(x)
print("\n检测到 %d 段发声：" % len(segs))
for i, (t0, t1) in enumerate(segs):
    print("  #%d  t=%.2f..%.2f s  (dur=%.2fs)" % (i+1, t0, t1, t1-t0))

for i, (t0, t1) in enumerate(segs):
    dur = t1-t0
    f0 = est_f0(x, t0, min(0.4, dur))
    # 匹配最近音名
    best = min(NOTES.items(), key=lambda kv: abs(kv[1]-f0))
    print("\n" + "="*80)
    print("#%d  f0=%.1f Hz  -> 最近音名 %s (%.1f)" % (i+1, f0, best[0], best[1]))
    # 谐波谱：起音 / 中段
    for tag, dt, d in [("起音(0-.15)", 0.0, 0.15), ("中段(.3-.6)", 0.3, 0.3)]:
        if dur > dt+0.05:
            hd = harm_db(x, f0, t0+dt, d, 12)
            if hd is not None:
                print("  %-12s" % tag + " ".join("H%d:%+5.1f" % (n+1, v) for n, v in enumerate(hd)))
    # 包络
    step = 0.1
    env = [env_at(x, t0+t) for t in np.arange(0, min(dur, 1.5), step)]
    e0 = max(env)
    print("  包络 rel dB @0.1s: " + " ".join("%+5.1f" % (v-e0) for v in env))
    # 基音衰减 dB/s（用包络线性段）
    if len(env) >= 6:
        r = (env[1]-env[5])/0.4
        print("  基音衰减(0.1->0.5s) ≈ %+.1f dB/s" % r)

print("\n[参考] 竖琴 C3 -6.8 / C5 -16.5 dB/s；小提琴 A4 平顶持续")
print("[模型] 拨弦C5 winB H1..H5 = 0 -13.0 -10.9 -24.7 -21.7")