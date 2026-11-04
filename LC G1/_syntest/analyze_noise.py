import wave, numpy as np, os

base = os.path.dirname(os.path.abspath(__file__))

def analyze(fname):
    p = os.path.join(base, fname)
    if not os.path.exists(p):
        print(f"[skip] {fname}")
        return
    with wave.open(p, 'rb') as w:
        nch = w.getnchannels(); sw = w.getsampwidth(); fr = w.getframerate(); n = w.getnframes()
        raw = w.readframes(n)
    dt = np.int16 if sw == 2 else (np.int32 if sw == 4 else np.int8)
    x = np.frombuffer(raw, dtype=dt).astype(np.float64)
    if nch == 2: x = x.reshape(-1, 2)[:, 0]
    print(f"\n=== {fname} ({len(x)} samp @ {fr}Hz) ===")
    print(f"  peak={np.max(np.abs(x)):.0f}  rms={np.sqrt(np.mean(x**2)):.1f}")
    tail = x[int(len(x) * 0.75):]
    nf = np.sqrt(np.mean(tail ** 2))
    pk = np.max(np.abs(tail))
    print(f"  tail(75%+) pk={pk:.0f}  rms={nf:.1f}  ({20*np.log10(max(nf/32768, 1e-120)):.1f} dBFS)")
    N = min(32768, len(tail))
    if N > 1024:
        seg = tail[-N:]
        win = np.hanning(N)
        sp = np.abs(np.fft.rfft(seg * win)) / N * 2
        freqs = np.fft.rfftfreq(N, 1 / fr)
        sp_db = 20 * np.log10(sp / 32768 + 1e-120)
        idx = np.argsort(sp)[::-1][:20]
        print("  tail top20 peaks:")
        for i in idx:
            if sp[i] < 0.5: continue
            print(f"    {freqs[i]:7.1f} Hz  {sp_db[i]:.1f} dBFS")
    mid = x[len(x)//4 : len(x)//2]
    M = min(8192, len(mid))
    if M > 1024:
        seg2 = mid[:M] * np.hanning(M)
        sp2 = np.abs(np.fft.rfft(seg2)) / M * 2
        freqs2 = np.fft.rfftfreq(M, 1/fr)
        sp2_db = 20*np.log10(sp2/32768 + 1e-120)
        idx2 = np.argsort(sp2)[::-1][:12]
        print("  mid-active top12 peaks:")
        for i in idx2:
            if sp2[i] < 0.5: continue
            print(f"    {freqs2[i]:7.1f} Hz  {sp2_db[i]:.1f} dBFS")

for f in ['harp_C4.wav','harp_C4_mellow.wav','harp_A2.wav','harp_A3.wav','harp_A4.wav','harp_C4_bright.wav','d11_old_5s_norm.wav','ref_harp_C5.wav','ref_violin_A4.wav']:
    analyze(f)
