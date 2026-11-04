# -*- coding: utf-8 -*-
# D11 C4 数字输出的纯净度 / 拍频(合唱) 专项分析
import sys, math

FS = 48000.0
F0 = 261.63
FULL24 = 8388607.0

def load(fn):
    mix=[]
    with open(fn) as f:
        for line in f:
            a=line.split()
            if len(a)>=1:
                try: mix.append(int(a[0]))
                except: pass
    return mix

def goertzel(seg, freq):
    w = 2*math.pi*freq/FS
    c=s=0.0
    for i,x in enumerate(seg):
        c += x*math.cos(w*i); s += x*math.sin(w*i)
    N=len(seg)
    return (2.0/N)*math.hypot(c,s)

def main():
    fn = sys.argv[1] if len(sys.argv)>1 else "mix_dump.txt"
    mix = load(fn)
    n = len(mix)
    print("samples=%d (%.4f s)" % (n, n/FS))

    silent=0
    while silent<n and mix[silent]==0: silent+=1
    print("前置静音帧=%d 峰值=%d (%.2f dBFS) 削波=%d" %
          (silent, max(abs(v) for v in mix),
           20*math.log10(max(max(abs(v) for v in mix),1)/FULL24),
           sum(1 for v in mix if abs(v)>=8388607)))

    # ---- 稳态窗口：起音 1440 点之后 ----
    a = 1800
    b = n
    seg = [mix[t]/32768.0 for t in range(a,b)]
    N = len(seg)
    print("稳态窗口 %d..%d (%d 点)" % (a,b,N))

    # 基音与谐波幅度
    base = goertzel(seg, F0)
    print("\n稳态谐波幅度（相对基音 dB）:")
    for k in range(1,17):
        amp = goertzel(seg, F0*k)
        print(" n=%2d  f=%7.1f  %7.1f dB" % (k, F0*k, 20*math.log10(max(amp,1e-9)/base)))

    # ---- 残差：减掉 1..16 谐波后 ----
    res2=0.0
    coef=[]
    for k in range(1,17):
        w=2*math.pi*F0*k/FS
        c=s=0.0
        for i,x in enumerate(seg):
            c+=x*math.cos(w*i); s+=x*math.sin(w*i)
        c*=2.0/N; s*=2.0/N
        coef.append((w,c,s))
    for i,x in enumerate(seg):
        r=x
        for (w,c,s) in coef:
            r -= c*math.cos(w*i)+s*math.sin(w*i)
        res2+=r*r
    rr=math.sqrt(res2/N)
    print("\n稳态残差 RMS=%.1f LSB16 -> %.1f dBc" % (rr, 20*math.log10(max(rr,1e-9)/(base/math.sqrt(2)))))

    # ---- 拍频检测：基音幅度包络 ----
    print("\n基音幅度包络（每 400 点一段）：")
    seglen=400
    mn=1e9; mx=-1e9
    for st in range(a, n-seglen, seglen):
        s2=[mix[t]/32768.0 for t in range(st, st+seglen)]
        amp=goertzel(s2, F0)
        mn=min(mn,amp); mx=max(mx,amp)
    print("  基音包络 min=%.1f max=%.1f  峰谷比=%.2f dB" % (mn,mx,20*math.log10(mx/max(mn,1e-9))))

    # ---- 精细谱：基音附近找峰 ----
    print("\n基音附近精细扫描（256..267Hz，步长0.02Hz，找前3峰）:")
    peaks=[]
    ff=256.0
    while ff<=267.0:
        peaks.append((ff, goertzel(seg, ff)))
        ff+=0.02
    peaks.sort(key=lambda t:-t[1])
    shown=[]
    for f,v in peaks:
        if all(abs(f-g)>0.5 for g,_ in shown):
            shown.append((f,v))
        if len(shown)>=3: break
    for f,v in shown:
        print("   %7.2f Hz  %.1f dB" % (f, 20*math.log10(max(v,1e-9)/base)))

    # ---- 非谐波探针 ----
    print("\n非谐波探针（相对基音 dB）:")
    for fp in [350,450,620,700,900,1100,1300,1550,1900,2100,2500,3300]:
        print("  %6.1f Hz : %6.1f dB" % (fp, 20*math.log10(max(goertzel(seg,fp),1e-9)/base)))

    # ---- 包络调制检测（"像合唱"/哆嗦/拍频的直接证据）----
    #   全波整流 -> 16:1 平均 -> 3000Hz 包络；去均值后做 FFT，找 0.5..60Hz 最强调制分量
    env=[]
    D=16
    for st in range(a, n-D, D):
        s=0
        for t in range(st, st+D):
            s += abs(mix[t])
        env.append(s/float(D))
    E=len(env)
    mu=sum(env)/E
    e2=[v-mu for v in env]
    var=sum(v*v for v in e2)/E
    std=math.sqrt(var)
    print("\n[包络调制] 均值=%.1f 标准差=%.1f  深度(std/mean)=%.2f%%" %
          (mu, std, 100.0*std/max(mu,1e-9)))
    fse = FS/D
    best=(0.0,0.0)
    ff=0.5
    while ff<=60.0:
        w=2*math.pi*ff/fse; c=s=0.0
        for i,x in enumerate(e2):
            c+=x*math.cos(w*i); s+=x*math.sin(w*i)
        v=(2.0/E)*math.hypot(c,s)
        if v>best[1]: best=(ff,v)
        ff+=0.25
    print("  最强调制分量: %.2f Hz  幅度=%.1f (%.1f%% 相对均值)" %
          (best[0], best[1], 100.0*best[1]/max(mu,1e-9)))

    # ---- Hann 窗泄漏受控的残差 ----
    win=[0.5-0.5*math.cos(2*math.pi*i/(N-1)) for i in range(N)]
    ws=[win[i]*seg[i] for i in range(N)]
    wsum=sum(win)
    res2w=0.0
    ch=[]
    for k in range(1,17):
        w=2*math.pi*F0*k/FS; c=s=0.0
        for i,x in enumerate(ws):
            c+=x*math.cos(w*i); s+=x*math.sin(w*i)
        ch.append((w, 2.0*c/wsum, 2.0*s/wsum))
    for i,x in enumerate(ws):
        r=x
        for (w,c,s) in ch:
            r-=c*math.cos(w*i)+s*math.sin(w*i)
        res2w+=r*r
    rr2=math.sqrt(res2w/sum(wi*wi for wi in win))
    print("\n[Hann窗] 残差 RMS=%.1f LSB16 -> %.1f dBc（泄漏受控）" %
          (rr2, 20*math.log10(max(rr2,1e-9)/(base/math.sqrt(2)))))

if __name__=="__main__":
    main()