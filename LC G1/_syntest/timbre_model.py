# -*- coding: utf-8 -*-
# ============================================================================
# timbre_model.py - 拨弦(竖琴)合成链的逐帧数学复刻 + 参考音色对比 + 参数搜索
#   复刻对象（与 RTL 严格对齐）：
#     ADSR.v            : 拨弦 A(线性) -> D(快衰到阈值) -> R(长尾)，噪声门 400
#     additive_engine.v : 泛音包络 h -= max(h>>sh_eff,1)（voff 音高依赖），
#                         term = (SINE[(n+1)ph>>20] * (h>>16)) >> 15，
#                         声部波形 sat16(Σterm)，out = (vw * amp) >> SHV(=8)
#   用法: python timbre_model.py
# ============================================================================
import math, os
import numpy as np
import miniaudio

FS = 48000
SHV = 8
SINE = np.array([round(32767*math.sin(2*math.pi*a/4096)) for a in range(4096)], dtype=np.int64)
REL_FULL = 0x7FFF0000
GATE = 400

# 拨弦 32 声部固定音（v0=C3 ... v7=C4 | v8=C4..v15=C5 | v16=C5..v23=C6 | v24=C6..v31=C7）
PLK_HEX = ("0b29a61a0a8942e70962fc96085cd15707734075070834ba0643cd1b0594d30d0594d30d"
           "0544a17304b17e4b042e68ac03b9a03a03841a5d0321e68d02ca698702ca698702a250ba0"
           "258bf260217345601dcd01d01c20d2f0190f347016534c3016534c30151285d012c5f9301"
           "0b9a2b00ee680f00e1069700c879a300b29a62")
_PL = int(PLK_HEX, 16)
inc_plk = lambda v: (_PL >> (32*v)) & 0xFFFFFFFF
NOTE = {0:'C3',7:'C4',8:'C4',15:'C5',16:'C5',23:'C6',24:'C6',31:'C7'}

# ---------------- 当前 RTL 表 ----------------
W_CUR = [(0x000000000000000000000000000000000000000000000FD50B3519190D543B87 >> (16*i)) & 0xFFFF
         for i in range(16)]                      # = [15239,3412,6425,2869,4053,0...]
SH_CUR = [16, 16, 15, 14, 14, 13, 12, 12, 12, 11, 11, 11, 11, 11, 11, 11]

def hexW(W):
    return "256'h" + "".join("%04X" % (W[i] & 0xFFFF) for i in range(15, -1, -1))
def hexSH(SH):
    return "80'h" + "%020X" % sum(SH[i] << (5*i) for i in range(16))

# ============================ 合成 ============================
def adsr(ns, f_on, A_CNT, A_INC, D_SH, D_END, R_SH):
    amp = np.zeros(ns, dtype=np.int64)
    st, cnt, a, prod = 0, 0, 0, 0
    for f in range(ns):
        if f == f_on:
            st, cnt, a, prod = 1, 0, 0, REL_FULL
        elif st == 0:
            a = 0
        elif st == 1:                                   # ATTACK 线性
            if cnt >= A_CNT: a, cnt, prod, st = 32767, 0, REL_FULL, 2
            else:            a, cnt = min(32767, a + A_INC), cnt + 1
        elif st == 2:                                   # DECAY (拨弦)
            na, nprod = prod >> 16, prod - (prod >> D_SH)
            st = 3 if a <= D_END else 2
            a, prod = na, nprod
        else:                                           # RELEASE
            if a <= GATE: a, st, cnt = 0, 0, 0
            else:         na = prod >> 16; prod -= prod >> R_SH; a = na
        amp[f] = a
    return amp

def render(ns, inc, W, SH, voff, A_CNT, A_INC, D_SH, D_END, R_SH, f_on=2):
    n  = np.arange(ns, dtype=np.int64)
    ph = (n * inc) & 0xFFFFFFFF
    nidx = np.empty((ns, 16), dtype=np.int64)
    for k in range(16):
        nidx[:, k] = ((((k+1) * ph) & 0xFFFFFFFF) >> 20)
    S = SINE[nidx]                                      # (ns,16) 正弦采样
    sh  = np.array([max(11, SH[k] - voff) for k in range(16)])
    tau = 2.0 ** sh
    t   = np.maximum(n - f_on, 0)
    hd  = np.zeros((ns, 16))
    for k in range(16):
        if W[k]: hd[:, k] = W[k] * np.exp(-t / tau[k])  # 当前权重 h>>16
    vacc = np.floor(S * hd / 32768.0).sum(axis=1).astype(np.int64)   # term >>15 后求和
    vw   = np.clip(vacc, -32768, 32767).astype(np.int64)            # sat16
    return (vw * adsr(ns, f_on, A_CNT, A_INC, D_SH, D_END, R_SH)) >> SHV, ph

# ============================ 参考音色 ============================
REF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ref")
def load_mono(p):
    dec = miniaudio.decode_file(p, output_format=miniaudio.SampleFormat.FLOAT32)
    x = np.frombuffer(dec.samples, dtype=np.float32)
    if dec.nchannels > 1: x = x.reshape(-1, dec.nchannels).mean(axis=1)
    return x.astype(np.float64), dec.sample_rate
def find_onset(x, sr):
    h = int(0.005*sr); n = len(x)//h
    e = np.array([np.sqrt(np.mean(x[k*h:(k+1)*h]**2)) for k in range(n)])
    return int(np.argmax(e > e.max()*10**(-45/20)))*h
def spec_db(x, sr, f0, t0, dur, nh=8):
    i0, i1 = int(t0*sr), min(int((t0+dur)*sr), len(x))
    if i1-i0 < 256: return None
    seg = x[i0:i1] - x[i0:i1].mean(); seg = seg*np.hanning(len(seg))
    N = 1 << 18; sp = np.abs(np.fft.rfft(seg, N)); fr = np.fft.rfftfreq(N, 1.0/sr)
    a = []
    for k in range(nh):
        fc = (k+1)*f0; lo = np.searchsorted(fr, fc-8); hi = np.searchsorted(fr, fc+8)
        a.append(sp[lo:hi].max() if hi > lo else 1e-12)
    a = np.array(a); return 20*np.log10(np.maximum(a, 1e-12)/max(a[0], 1e-12))
def env_db(x, sr, hop=0.1):
    h = int(hop*sr); n = len(x)//h
    e = np.array([np.sqrt(np.mean(x[k*h:(k+1)*h]**2)) for k in range(n)])
    return 20*np.log10(np.maximum(e, 1e-9))

WINS = [("A", 0.00, 0.15), ("B", 0.15, 0.25), ("C", 0.50, 0.50)]
def report(tag, x, sr, f0, on, nh=7):
    out = {}
    for w, t0, dur in WINS:
        out[w] = spec_db(x, sr, f0, on+t0, dur, nh)
    out["env"] = env_db(x, sr)
    out["on"]  = on
    return out

def load_ref(name, f0):
    x, sr = load_mono(os.path.join(REF, name))
    on = find_onset(x, sr)/sr
    return report(name, x, sr, f0, on)

def fmt(v):
    return " ".join("%+5.1f" % q for q in v) if v is not None else "  n/a"

# ---------------- 由参考谱自动反解泛音表（拨弦, C5=voff1） ----------------
#   模型相对谱 level_n(t) = W_n(dB) - (r_n - r_1)*t，r = 8.686*48000/2^sh_eff。
#   对每个泛音在 winA/B/C 三时刻做加权最小二乘（winA 权重偏低，因其含节拍抖动），
#   sh_eff 只能取整数档（11..17）-> 枚举取最优；W 由拟合截距得到。
T_TGT  = [0.075, 0.275, 0.75]
W_TGT  = [1.0, 1.6, 1.2]                      # winA / winB / winC 权重

def fit_table(ref, nh=5):
    y = [ref[w][:nh] for w in "ABC"]          # [win][harm]
    r1 = 8.686*48000.0/2.0**max(11, SH_CUR[0]-1)
    Wdb = [0.0]; she = [max(11, SH_CUR[0]-1)]
    for k in range(1, nh):
        best = None
        for s in range(11, 17):               # sh_eff 候选
            d = 8.686*48000.0/2.0**s - r1
            a = sum(W_TGT[j]*(y[j][k] + d*T_TGT[j]) for j in range(3)) / sum(W_TGT)
            e = sum(W_TGT[j]*(a - d*T_TGT[j] - y[j][k])**2 for j in range(3))
            if best is None or e < best[0]: best = (e, a, s)
        Wdb.append(best[1]); she.append(best[2])
    lin = [10**(d/20.0) for d in Wdb]
    sc  = 32000.0/sum(lin)
    W   = [int(round(x*sc)) for x in lin] + [0]*(16-nh)
    SH  = [min(17, s + 1) for s in she] + [11]*(16-nh)      # eff = SH - voff(=1)
    return W, SH

def env_shape(x, sr, on):
    """0.1s 起归一化的 RMS 包络（dB, 0.1s 步长），取 0.1~2.0s"""
    e = env_db(x, sr); i0 = int(round(on/0.1))+1
    s = e[i0:i0+19]
    return s - s[0]

def main():
    ns = int(FS*3.0)
    refs = {15: load_ref("harp_C5.mp3", 523.25), 0: load_ref("harp_C3.mp3", 130.81)}

    print("=== 参考竖琴 (dB 相对基音) ===")
    for v in (15, 0):
        r = refs[v]; print(" %-3s 音高%.1fHz" % (NOTE[v], 523.25 if v == 15 else 130.81))
        for w in "ABC":
            print("   win%s H1..H6 " % w + fmt(r[w][:6]))
        print("   env(0.1s起归一) " + fmt(env_shape(_refx[v], FS, r["on"])[:15]))

    # 泛音衰减表候选：SH_B = 把 H2 起步调快一档（参考竖琴 H2 相对基音持续变暗）
    SH_B = [16, 15, 15, 14, 14, 13, 12, 12, 12, 11, 11, 11, 11, 11, 11, 11]
    # 候选泛音表
    W_FIT, SH_FIT = fit_table(refs[15])
    TV = {"表SH-B": (W_CUR, SH_B), "表:当前": (W_CUR, SH_CUR)}
    print("\n拟合表 W =", W_FIT, " Σ=", sum(W_FIT), "\n  ", hexW(W_FIT))
    print("拟合表 SH =", SH_FIT, "\n  ", hexSH(SH_FIT))

    ADV = {"A3ms": (144, 227), "A6ms": (288, 114), "A10ms": (480, 68), "A20ms": (960, 34)}
    DRV = {"D16/R17":       (16, 16384, 17)}

    print("\n=== 搜索（C5 频谱 + C3/C5 包络形态）===")
    rows = []
    for an, (ac, ai) in ADV.items():
        for dn, (ds, de, rs) in DRV.items():
            for tn, (W, SH) in TV.items():
                res = {}
                esh = 0.0
                for v, f0, inc, voff in ((15, 523.25, inc_plk(15), 1), (0, 130.81, inc_plk(0), 0)):
                    out, _ = render(ns, inc, W, SH, voff, ac, ai, ds, de, rs)
                    mo = out.astype(np.float64)
                    m = report("m", mo, FS, f0, 2.0/FS)
                    res[v] = m
                    for w in "ABC":
                        for k in range(5): esh += (m[w][k+1]-refs[v][w][k+1])**2
                    es = env_shape(mo, FS, 2.0/FS)   # 模型 0.1~2.0s
                    er = env_shape(_refx[v], FS, refs[v]["on"])
                    m["es"], m["er"] = es, er
                    esh += 1.2*float(np.sum((es[:14]-er[:14])**2))   # 只用到 ~1.4s，避开参考噪声底
                rows.append((esh, an, dn, tn, res))
    rows.sort(key=lambda z: z[0])
    for e, an, dn, tn, res in rows:
        print(" err=%7.1f  %-6s %-14s %s" % (e, an, dn, tn))
        for v in (15, 0):
            print("      %-3s env " % NOTE[v] + fmt(res[v]["es"][:14]) +
                  " | ref " + fmt(res[v]["er"][:14]))
    e, an, dn, tn, res = rows[0]
    print("\n>>> 最优: err=%.1f  %s | %s | %s" % (e, an, dn, tn))
    for v, f0 in ((15, 523.25), (0, 130.81)):
        m, r = res[v], refs[v]
        print("  %-3s winA " % NOTE[v] + fmt(m["A"][:6]) + " | ref " + fmt(r["A"][:6]))
        print("      winB " + fmt(m["B"][:6]) + " | ref " + fmt(r["B"][:6]))
        print("      winC " + fmt(m["C"][:6]) + " | ref " + fmt(r["C"][:6]))
    for e2, an2, dn2, tn2, res2 in rows:
        print(">> %-6s %-14s %s :" % (an2, dn2, tn2), end="")
        for v in (15, 0):
            print("  %s winA(Δ) " % NOTE[v] +
                  fmt([res2[v]["A"][k+1]-refs[v]["A"][k+1] for k in range(4)]) +
                  " winB(Δ) " + fmt([res2[v]["B"][k+1]-refs[v]["B"][k+1] for k in range(4)]) +
                  " winC(Δ) " + fmt([res2[v]["C"][k+1]-refs[v]["C"][k+1] for k in range(4)]), end="")
        print()

if __name__ == "__main__":
    _refx = {}
    def _load(name):
        x, sr = load_mono(os.path.join(REF, name)); return x
    _refx[15] = _load("harp_C5.mp3"); _refx[0] = _load("harp_C3.mp3")
    main()