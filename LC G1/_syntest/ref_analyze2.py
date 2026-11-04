# -*- coding: utf-8 -*-
# ============================================================================
# ref_analyze2.py - 参考音色分析(2)：自动定音起点，提取
#   (a) 各次谐波在多个时间窗内的幅度(相对基音 dB)
#   (b) 各次谐波的衰减速率(dB/s)，用于反推 SH[n]
#   (c) 整体包络形态
# 用法: py -3 ref_analyze2.py
# ============================================================================
import os, math
import numpy as np
import miniaudio

REF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ref")
NOTES = {'C3':130.81,'C4':261.63,'G3':196.00,'G4':392.00,'A4':440.00,'C5':523.25,'E5':659.26}

def load_mono(path):
    dec = miniaudio.decode_file(path, output_format=miniaudio.SampleFormat.FLOAT32)
    x = np.frombuffer(dec.samples, dtype=np.float32)
    if dec.nchannels > 1:
        x = x.reshape(-1, dec.nchannels).mean(axis=1)
    return x.astype(np.float64), dec.sample_rate

def find_onset(x, sr, peak_db=-45.0):
    h = int(0.005*sr); n = len(x)//h
    e = np.array([np.sqrt(np.mean(x[k*h:(k+1)*h]**2)) for k in range(n)])
    pk = e.max()
    thr = pk * 10**(peak_db/20.0)
    idx = np.argmax(e > thr)
    return idx*h/sr

def harm_amp(x, sr, f0, t0, dur, nh=24):
    i0 = int(t0*sr); i1 = min(int((t0+dur)*sr), len(x))
    if i1 - i0 < 128: return None
    seg = x[i0:i1]; w = np.hanning(len(seg)); seg = (seg-seg.mean())*w
    N = 1 << 18
    sp = np.abs(np.fft.rfft(seg, N)); fr = np.fft.rfftfreq(N, 1.0/sr)
    def pk(fc, half=8.0):
        lo=np.searchsorted(fr, fc-half); hi=np.searchsorted(fr, fc+half)
        return sp[lo:hi].max() if hi>lo else 1e-12
    return np.array([pk((n+1)*f0) for n in range(nh)])

def analyze(name, note):
    path = os.path.join(REF, name)
    x, sr = load_mono(path)
    f0 = NOTES[note]
    on = find_onset(x, sr)
    print("=" * 84)
    print("%-14s (%s f0=%.1fHz)  dur=%.2fs  onset=%.3fs  peak=%.3f" %
          (name, note, f0, len(x)/sr, on, np.max(np.abs(x))))
    wins = [("A", 0.00, 0.15), ("B", 0.15, 0.25), ("C", 0.5, 0.5), ("D", 1.5, 0.5)]
    amps = {}
    for tag, dt0, dur in wins:
        a = harm_amp(x, sr, f0, on+dt0, dur)
        amps[tag] = a
        if a is None: continue
        db = 20*np.log10(np.maximum(a, 1e-12)/max(a[0], 1e-12))
        print("  win%s t=+%.2f..%.2f  " % (tag, dt0, dt0+dur) +
              " ".join("H%d:%+5.1f" % (i+1, v) for i, v in enumerate(db[:12])))
    # 衰减速率(dB/s): 用 A->C 两个窗的基音，和 B->C/D 估计
    if amps["A"] is not None and amps["C"] is not None:
        base = 20*np.log10(max(amps["A"][0],1e-12)/max(amps["C"][0],1e-12))
        print("  H1 衰减 A(0-.15s)->C(.5-1s): %+.1f dB over 0.6s  => %+.1f dB/s" % (base, base/0.6))
        rates = []
        for n in range(8):
            if amps["C"][n] > 1e-9 and amps["A"][n] > 1e-9:
                d = 20*math.log10(amps["A"][n]/amps["C"][n])
                rates.append(d/0.6)
            else:
                rates.append(float('nan'))
        print("  Hn 衰减(dB/s) A->C: " + " ".join("H%d:%+6.1f" % (i+1,r) for i,r in enumerate(rates)))
    # 整体包络
    h = int(0.05*sr); n = len(x)//h
    env = np.array([20*math.log10(max(np.sqrt(np.mean(x[k*h:(k+1)*h]**2)),1e-9)) for k in range(n)])
    rel = env - env[int(on/0.05):].max()
    idt = [int(t/0.05) for t in np.arange(0, min(3.0, n*0.05), 0.1)]
    print("  env rel dB @0.1s: " + " ".join("%+5.1f" % rel[i] for i in idt if i < len(rel)))

for fn, nt in [("harp_C5.mp3",'C5'), ("harp_C3.mp3",'C3'),
               ("vio_A4.mp3",'A4'), ("vio_C5.mp3",'C5'), ("vio_E5.mp3",'E5'), ("vio_G3.mp3",'G3')]:
    if os.path.exists(os.path.join(REF, fn)):
        analyze(fn, nt)