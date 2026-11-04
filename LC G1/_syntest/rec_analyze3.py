# -*- coding: utf-8 -*-
# rec_analyze3.py - 录音 vs PC模型 同窗对照 + 峰值列表
import os, math, wave
import numpy as np
HERE=os.path.dirname(os.path.abspath(__file__)); FS=48000

def load(p):
    with wave.open(p,'rb') as w:
        raw=w.readframes(w.getnframes()); ch=w.getnchannels()
    x=np.frombuffer(raw,dtype=np.int16).astype(np.float64)/32768.0
    if ch>1: x=x.reshape(-1,ch).mean(axis=1)
    return x

def harm_db(seg,f0,nh=12,half=8.0):
    seg=(seg-seg.mean())*np.hanning(len(seg)); N=1<<18
    sp=np.abs(np.fft.rfft(seg,N)); fr=np.fft.rfftfreq(N,1.0/FS)
    def p(fc):
        lo=np.searchsorted(fr,fc-half); hi=np.searchsorted(fr,fc+half)
        return sp[lo:hi].max() if hi>lo else 1e-12
    a=np.array([p((k+1)*f0) for k in range(nh)])
    return 20*np.log10(np.maximum(a,1e-12)/max(a[0],1e-12))

def toppeaks(seg,k=14,lo=100,hi=4000,minsep=30):
    seg=(seg-seg.mean())*np.hanning(len(seg)); N=1<<18
    sp=np.abs(np.fft.rfft(seg,N)); fr=np.fft.rfftfreq(N,1.0/FS)
    sel=(fr>=lo)&(fr<=hi)
    idx=np.where(sel)[0]
    order=idx[np.argsort(sp[idx])[::-1]]
    out=[]
    for i in order:
        if len(out)>=k: break
        if all(abs(fr[i]-f)>minsep for f,_ in out):
            out.append((fr[i],sp[i]))
    mx=out[0][1] if out else 1
    return [(f,20*math.log10(max(v,1e-12)/mx)) for f,v in out]

def win(x,t0,dt,d):
    a=int((t0+dt)*FS); b=min(int((t0+dt+d)*FS),len(x))
    return x[a:b]

rec=load(os.path.join(HERE,'rec_input.wav'))
plk=load(os.path.join(HERE,'out_plk.wav'))
bow=load(os.path.join(HERE,'out_bow.wav'))
print("len rec=%.2f plk=%.2f bow=%.2f"%(len(rec)/FS,len(plk)/FS,len(bow)/FS))

print("\n########## 拨弦 C5：录音#1 vs 模型 out_plk ##########")
for tag,dt,d in [("起音0-.15",0.0,0.15),("中0.3-.7",0.3,0.4),("后1.0-1.5",1.0,0.5)]:
    r=harm_db(win(rec,0.65,dt,d),523.25)
    m=harm_db(win(plk,0.0,dt,d),523.25)
    print(" %-10s 录音: "%tag+" ".join("H%d:%+5.1f"%(i+1,v) for i,v in enumerate(r)))
    print(" %-10s 模型: "%("")+" ".join("H%d:%+5.1f"%(i+1,v) for i,v in enumerate(m)))

print("\n录音 拨弦#1 起音峰值:")
for f,db in toppeaks(win(rec,0.65,0.0,0.4)): print("   %7.1f Hz  %+6.1f dB"%(f,db))
print("模型 拨弦 起音峰值:")
for f,db in toppeaks(win(plk,0.0,0.0,0.4)): print("   %7.1f Hz  %+6.1f dB"%(f,db))

print("\n########## 拉弦 A4：录音#4 vs 模型 out_bow ##########")
for tag,dt,d in [("起音0-.15",0.0,0.15),("中0.3-.7",0.3,0.4),("后1.0-1.5",1.0,0.5)]:
    r=harm_db(win(rec,7.45,dt,d),440.0)
    m=harm_db(win(bow,0.0,dt,d),440.0)
    print(" %-10s 录音: "%tag+" ".join("H%d:%+5.1f"%(i+1,v) for i,v in enumerate(r)))
    print(" %-10s 模型: "%("")+" ".join("H%d:%+5.1f"%(i+1,v) for i,v in enumerate(m)))

print("\n录音 拉弦#4 中段峰值:")
for f,db in toppeaks(win(rec,7.45,0.3,0.6)): print("   %7.1f Hz  %+6.1f dB"%(f,db))
print("模型 拉弦 中段峰值:")
for f,db in toppeaks(win(bow,0.3,0.3,0.6)): print("   %7.1f Hz  %+6.1f dB"%(f,db))