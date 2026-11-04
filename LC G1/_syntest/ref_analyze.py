# -*- coding: utf-8 -*-
# ============================================================================
# ref_analyze.py - 参考音色分析：解码 virtualinstruments.net 的竖琴/小提琴 mp3，
#   提取谐波幅度包络（相对基音 dB）与整体衰减包络，用于对标 RTL 音色设计。
# 用法: py -3 ref_analyze.py
# ============================================================================
import os, math
import numpy as np
import miniaudio

REF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ref")

def load_mono(path):
    dec = miniaudio.decode_file(path, output_format=miniaudio.SampleFormat.FLOAT32)
    x = np.frombuffer(dec.samples, dtype=np.float32)
    if dec.nchannels > 1:
        x = x.reshape(-1, dec.nchannels).mean(axis=1)
    return x.astype(np.float64), dec.sample_rate

def harmonic_db(x, sr, f0, t0, dur, nh=16):
    """在 [t0, t0+dur] 窗口内做 Hann FFT，返回 n*f0 各次谐波相对基音的 dB。"""
    i0 = int(t0 * sr); i1 = min(int((t0 + dur) * sr), len(x))
    seg = x[i0:i1]
    if len(seg) < 64:
        return None
    w = np.hanning(len(seg))
    seg = (seg - seg.mean()) * w
    N = 1 << 18
    sp = np.abs(np.fft.rfft(seg, N))
    freqs = np.fft.rfftfreq(N, 1.0 / sr)
    def peak(fc, half=6.0):
        lo = np.searchsorted(freqs, fc - half); hi = np.searchsorted(freqs, fc + half)
        if hi <= lo: return 1e-12
        return sp[lo:hi].max()
    a1 = peak(f0)
    out = []
    for n in range(1, nh + 1):
        a = peak(n * f0)
        out.append(20 * math.log10(max(a, 1e-12) / max(a1, 1e-12)))
    return out

def rms_env_db(x, sr, hop=0.02):
    h = int(hop * sr)
    n = len(x) // h
    env = []
    for k in range(n):
        s = x[k*h:(k+1)*h]
        env.append(20 * math.log10(max(np.sqrt(np.mean(s**2)), 1e-9)))
    return np.array(env), hop

def spectral_centroid(x, sr, t0, dur):
    i0 = int(t0*sr); i1 = min(int((t0+dur)*sr), len(x))
    seg = x[i0:i1]
    if len(seg) < 64: return 0
    w = np.hanning(len(seg))
    sp = np.abs(np.fft.rfft(seg*w))
    fr = np.fft.rfftfreq(len(seg), 1.0/sr)
    return float((sp*fr).sum()/max(sp.sum(), 1e-12))

NOTES = {'C3':130.81,'C4':261.63,'G3':196.00,'G4':392.00,'A4':440.00,'C5':523.25,'E5':659.26}

def report(path, note):
    x, sr = load_mono(path)
    f0 = NOTES[note]
    print("=" * 78)
    print("%s  (%s)  sr=%d  dur=%.2fs  peak=%.3f" % (os.path.basename(path), note, sr, len(x)/sr, np.max(np.abs(x))))
    # 起音/持续两个窗口的谐波
    for tag, t0, dur in [("attack(30-330ms)", 0.03, 0.30), ("sustain(0.5-0.9s)", 0.50, 0.40)]:
        h = harmonic_db(x, sr, f0, t0, dur)
        if h is None: continue
        print("  %-18s H1..H16 rel dB: %s" % (tag, " ".join("%+5.1f" % v for v in h)))
    print("  centroid attack=%.0fHz  sustain=%.0fHz" % (
        spectral_centroid(x, sr, 0.03, 0.30), spectral_centroid(x, sr, 0.50, 0.40)))
    env, hop = rms_env_db(x, sr)
    peak = env.max()
    # 打印 0..2s 每 0.1s 的 dB（相对各自峰值）
    idx = [int(t/hop) for t in np.arange(0, min(2.0, len(env)*hop), 0.1)]
    print("  env dB(0.1s步): %s" % " ".join("%+5.1f" % (env[i]-peak) for i in idx if i < len(env)))
    return x, sr

if __name__ == "__main__":
    pairs = [("harp_C5.mp3",'C5'), ("harp_C3.mp3",'C3'),
             ("vio_A4.mp3",'A4'), ("vio_C5.mp3",'C5'), ("vio_E5.mp3",'E5'), ("vio_G3.mp3",'G3')]
    for fn, nt in pairs:
        p = os.path.join(REF, fn)
        if os.path.exists(p):
            report(p, nt)