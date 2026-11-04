# -*- coding: utf-8 -*-
# env_track.py - 细粒度起音包络 + 谐波随时间的演化（录音 vs 模型）
import os, math, wave
import numpy as np
HERE=os.path.dirname(os.path.abspath(__file__)); FS=48000
def load(p):
    with wave.open(p,'rb') as w:
        raw=w.readframes(w.getnframes()); ch=w.getnchannels()
    x=np.frombuffer(raw,dtype=np.int16).astype(np.float64)/32768.0
    if ch>1: x=x.reshape(-1,ch).mean(axis=1)
    return x
def harm_db_seg(seg,f0,nh=8,half=6.0):
    if len(seg)<256: return None
    seg=(seg-seg.mean())*np.hanning(len(seg)); N=1<<16
    sp=np.abs(np.fft.rfft(seg,N)); fr=np.fft.rfftfreq(N,1.0/FS)
    def p(fc):
        lo=np.searchsorted(fr,fc-half); hi=np.searchsorted(fr,fc+half)
        return sp[lo:hi].max() if hi>lo else 1e-12
    a=np.array([p((k+1)*f0) for k in range(nh)])
    return 20*np.log10(np.maximum(a,1e-12)/max(a[0],1e-12))
def env_ms(x,t0,dur_ms=200,step_ms=2):
    st=int(step_ms*FS/1000)
    out=[]
    for k in range(0,dur_ms//step_ms):
        a=int(t0*FS)+k*st; b=a+st
        out.append(20*math.log10(max(math.sqrt(np.mean(x[a:b]**2)),1e-9)))
    return out

rec=load(os.path.join(HERE,'rec_input.wav'))
plk=load(os.path.join(HERE,'out_plk.wav'))

print("########## 振幅包络 @2ms（起音 200ms，rel 峰值 dB）##########")
r=env_ms(rec,0.65); m=env_ms(plk,0.0)
rp=max(r); mp=max(m)
print(" t(ms) 录音 模型")
for k in range(0,100,5):
    print("  %3d   %+6.1f %+6.1f"%(k*2, r[k]-rp, m[k]-mp))
# 起音时间：到达 -3dB 的时刻
def t3(e,step=2):
    e=np.array(e); pk=e.max()
    idx=np.argmax(e>pk-3)
    return idx*step
print("到达-3dB时间: 录音 %d ms  模型 %d ms"%(t3(r),t3(m)))

print("\n########## 拨弦 C5 各谐波随时间 (rel H1 dB) ##########")
WINS=[("0-30ms",0.0,0.030),("30-80ms",0.030,0.050),("80-150ms",0.080,0.070),
      ("150-300ms",0.150,0.150),("0.3-0.5s",0.30,0.20),("0.5-0.8s",0.50,0.30)]
print("  %-10s %-42s | %s"%("窗","录音 H1..H6","模型 H1..H6"))
for tag,dt,d in WINS:
    ar=int((0.65+dt)*FS); br=ar+int(d*FS)
    am=int(dt*FS);        bm=am+int(d*FS)
    hr=harm_db_seg(rec[ar:br],523.25)
    hm=harm_db_seg(plk[am:bm],523.25)
    fr_=" ".join("%+5.1f"%v for v in hr[:6]) if hr is not None else "n/a"
    fm_=" ".join("%+5.1f"%v for v in hm[:6]) if hm is not None else "n/a"
    print("  %-10s %-42s | %s"%(tag,fr_,fm_))