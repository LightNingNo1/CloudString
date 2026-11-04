# -*- coding: utf-8 -*-
# rec_analyze2.py - 更细的录音分析：全局包络 + 自相关基频 + 分段谐波谱
import os, math, wave
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); FS = 48000

def load(path):
    with wave.open(path,'rb') as w:
        n=w.getnframes(); ch=w.getnchannels(); raw=w.readframes(n)
    x=np.frombuffer(raw,dtype=np.int16).astype(np.float64)/32768.0
    if ch>1: x=x.reshape(-1,ch).mean(axis=1)
    return x

x=load(os.path.join(HERE,'rec_input.wav'))
N=len(x)
print("dur=%.2fs peak=%.3f"%(N/FS,np.max(np.abs(x))))

# ---- 全局包络 0.05s ----
hop=0.05; h=int(hop*FS); n=N//h
env=np.array([20*math.log10(max(math.sqrt(np.mean(x[k*h:(k+1)*h]**2)),1e-9)) for k in range(n)])
pk=env.max()
print("\n全局包络 rel dB @0.05s (前 220 点 = 0..11s):")
line=[]
for k in range(n):
    line.append("%+.0f"%(env[k]-pk))
    if len(line)==20:
        print("  t=%4.1fs "%( (k-19)*hop) + " ".join(line)); line=[]
if line: print("  (tail t=%4.1fs) "%((n-len(line))*hop)+" ".join(line))

# ---- 自相关基频 ----
def ac_f0(seg, lo=60, hi=1200):
    seg=seg-seg.mean(); e=np.sum(seg*seg)
    if e<=0: return 0.0
    ac=np.correlate(seg,seg,'full')[len(seg)-1:]
    lo_l=int(FS/hi); hi_l=int(FS/lo)
    hi_l=min(hi_l,len(ac)-2)
    if hi_l<=lo_l: return 0.0
    k=np.argmax(ac[lo_l:hi_l])+lo_l
    if 0<k<len(ac)-1:
        a,b,c=ac[k-1],ac[k],ac[k+1]; d=0.5*(a-c)/(a-2*b+c) if (a-2*b+c)!=0 else 0
        k=k+d
    return FS/k

def harm_db(seg,f0,nh=16,half=8.0):
    seg=(seg-seg.mean())*np.hanning(len(seg)); Nn=1<<18
    sp=np.abs(np.fft.rfft(seg,Nn)); fr=np.fft.rfftfreq(Nn,1.0/FS)
    def p(fc):
        lo=np.searchsorted(fr,fc-half); hi=np.searchsorted(fr,fc+half)
        return sp[lo:hi].max() if hi>lo else 1e-12
    a=np.array([p((k+1)*f0) for k in range(nh)])
    return 20*np.log10(np.maximum(a,1e-12)/max(a[0],1e-12))

# ---- 自动分段：阈值 -32dB，最短 0.15s，间隔>0.25s 才算新音 ----
thr=pk-32.0
on=env>thr
segs=[]; k=0
while k<n:
    if on[k]:
        j=k
        while j<n and on[j]: j+=1
        segs.append([k,j]); k=j
    else: k+=1
# 合并间隔 <0.25s
merged=[]
for s in segs:
    if merged and (s[0]-merged[-1][1])*hop<0.25: merged[-1][1]=s[1]
    else: merged.append(s)
segs=[(a*hop,b*hop) for a,b in merged if (b-a)*hop>0.15]
print("\n分段(阈值-32dB): " + ", ".join("#%d[%.2f-%.2f]"%(i+1,a,b) for i,(a,b) in enumerate(segs)))

for i,(t0,t1) in enumerate(segs):
    i0=int(t0*FS); i1=int(t1*FS); seg=x[i0:i1]; dur=t1-t0
    # 自相关基频（取前 0.5s）
    f0=ac_f0(seg[:int(0.5*FS)])
    print("\n"+"="*76)
    print("#%d  %.2f..%.2f (%.2fs)  f0(自相关)=%.1f Hz"%(i+1,t0,t1,dur,f0))
    for tag,dt,d in [("起音0-.15",0.0,0.15),("中0.3-.7",0.3,0.4),("后1.0-1.5",1.0,0.5)]:
        a=int(dt*FS); b=min(int((dt+d)*FS),len(seg))
        if b-a>2048:
            try:
                hd=harm_db(seg[a:b],f0,12)
                print("  %-10s"%tag + " ".join("H%d:%+5.1f"%(k+1,v) for k,v in enumerate(hd)))
            except Exception as e: pass
    # 本段包络每 0.1s
    hh=int(0.1*FS); m=len(seg)//hh
    ee=[20*math.log10(max(math.sqrt(np.mean(seg[j*hh:(j+1)*hh]**2)),1e-9)) for j in range(m)]
    if ee:
        e0=max(ee)
        print("  段内包络 rel: " + " ".join("%+.1f"%(v-e0) for v in ee[:20]))