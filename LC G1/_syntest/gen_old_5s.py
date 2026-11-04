# -*- coding: utf-8 -*-
# ============================================================================
# gen_old_5s.py - 按 RTL 逐拍数学模型生成 D11（声部7，A4 440Hz）"旧音色" 5 秒 WAV
#   · 复刻 additive_engine.v：32bit 相位累加(TEST_INC) + 12bit 正弦表(4096x16)
#     + henv 泛音包络每条目衰减 h<-h-max(h>>SH,1) + 16 泛音相乘求和饱和
#   · 复刻 ADSR.v 拨弦(mode=0)：线性起音 256 点 -> 快衰(>>10,到75%) -> 释放(>>15)
#   · 幅度用真实仿真 mix_dump.txt 标定 mix = A*(vw*env>>9)，并交叉验证模型 vw 与实测 vw7
# 用法: py -3 gen_old_5s.py [mix_dump.txt] [out_name] [dur_sec]
# ============================================================================
import sys, math, wave, struct

FS       = 48000
TEST_INC = 39370534                 # A4 440Hz 相位步长（=440/48000*2^32 取整）
H16 = sum(1.0/k for k in range(1, 17))

# ---- 泛音权重（旧：1/n 锯齿波频谱）----
W = [round(32768.0/(k*H16)) for k in range(1, 17)]

# ---- 泛音衰减右移位数 SH[1..16]（从 RTL 常量解码并校验）----
_SHV = int("6318C635AD6B5AE739F0", 16)
SH = [( _SHV >> (5*(n-1))) & 0x1F for n in range(1, 17)]
assert SH == [16,15,14,14,14]+[13]*6+[12]*5, ("SH 解码异常", SH)

# ---- 12bit 正弦表（与 gowin_prom_sin.v 一致：value(A)=round(32767*sin(2pi*A/4096))）----
SINE = [round(32767*math.sin(2*math.pi*a/4096)) for a in range(4096)]

# ---- ADSR 常量（ADSR.v mode=0）----
REL_FULL = 32767 << 16
REL_75   = REL_FULL - (REL_FULL >> 2)
GATE_AMP = 400
A_CNT    = 256
F_ON     = 4                        # tb 里前 4 帧静音，第 5 帧给 note_on

def sat16(x):
    return 32767 if x > 32767 else (-32768 if x < -32768 else x)

def gen(NS):
    """返回 (mix_proxy, vw) 两条长度 NS 的列表；mix_proxy = (vw*env)>>9（正比于真 mix）"""
    # ADSR：state/cnt/prod/amp 表示"上一帧写回值"
    S_IDLE, S_ATT, S_FAST, S_REL = 0, 1, 2, 3
    st, cnt, prod, amp = S_IDLE, 0, 0, 0
    # henv 状态：每泛音 32bit，满载 = W[n]<<16
    h = [0]*16
    ph = 0                          # 32bit 相位
    mix = [0]*NS
    vw  = [0]*NS
    for f in range(NS):
        # ---------- ADSR 本帧写回 ----------
        if f == F_ON:
            st, cnt, amp, prod = S_ATT, 0, 0, REL_FULL
        else:
            if st == S_IDLE:
                amp = 0
            elif st == S_ATT:
                if cnt >= A_CNT:
                    amp, cnt, prod, st = 32767, 0, REL_FULL, S_FAST
                else:
                    amp = cnt * 128
                    cnt += 1
            elif st == S_FAST:
                if prod <= REL_75:
                    st = S_REL
                else:
                    prod -= (prod >> 10)
                    amp = prod >> 16
            elif st == S_REL:
                if amp <= GATE_AMP:
                    amp, st, cnt = 0, S_IDLE, 0
                else:
                    prod -= (prod >> 15)
                    amp = prod >> 16
        env_f = amp

        # ---------- 相位推进（本帧输出用推进后的相位，与 RTL 每帧先更相位再合成一致）----------
        ph = (ph + TEST_INC) & 0xFFFFFFFF

        # ---------- 声部7 的 16 泛音求和（用上一帧末的 henv 状态，对应 RTL 读先于写）----------
        vacc = 0
        for n in range(16):
            a_n = h[n] >> 16                      # 上一帧末状态（h[n] 对应第 n+1 次泛音）
            sa  = ((n+1) * ph) & 0xFFFFFFFF       # 第 n+1 次泛音相位 = (n+1)*phase
            s   = SINE[sa >> 20]
            vacc += (s * a_n) >> 15
        vw[f] = sat16(vacc)

        # ---------- henv 更新（本帧末）：note_on 帧重装满幅，否则每帧衰减 ----------
        for n in range(16):
            if f == F_ON:
                h[n] = W[n] << 16
            elif h[n] != 0:
                h[n] -= max(h[n] >> SH[n], 1)

        mix[f] = (vw[f] * env_f) >> 9
    return mix, vw

def read_dump(path):
    m, v = [], []
    try:
        with open(path) as fp:
            for line in fp:
                a = line.split()
                if len(a) == 2:
                    m.append(int(a[0])); v.append(int(a[1]))
    except IOError:
        pass
    return m, v

def write_wav(path, s16):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(FS)
        w.writeframes(b''.join(struct.pack('<h', max(-32768, min(32767, x))) for x in s16))

def main(dump="mix_dump.txt", out="d11_old_5s", dur=5.0):
    NS = int(FS*dur)
    mix_m, vw_m = gen(NS)
    print("模型生成 %d 帧 (%.1f s)，vw 峰值(模型前 0.25s)=%d" %
          (NS, dur, max(abs(x) for x in vw_m[:12000])))

    mix_r, vw_r = read_dump(dump)
    A = None
    if len(mix_r) > 100:
        # 交叉验证：模型 vw 与实测 vw7
        L = min(len(vw_r), len(vw_m), 12000)
        # 找实测首个非零帧作为对齐参考
        first = next((i for i in range(L) if vw_r[i] != 0), None)
        best = None
        for off in (0, 1, 2, 3):
            e = [abs(vw_m[i-off] - vw_r[i]) for i in range(off, L) if mix_r[i] != 0]
            if e:
                mx = max(e)
                if best is None or mx < best[0]:
                    best = (mx, off)
        print("实测 vw7 首个非零帧 = %s；模型对齐偏移 off=%d，最大绝对误差=%d" %
              (first, best[1], best[0]) if best else "无重叠可比帧")
        off = best[1] if best else 0
        # 幅度标定 A = mix_real / (vw_m*env)>>9  —— 用实测 mix ÷ 模型 mix_proxy
        ratios = [mix_r[i]/mix_m[i-off] for i in range(off, L)
                  if mix_m[i-off] != 0 and mix_r[i] != 0]
        ratios.sort()
        A = ratios[len(ratios)//2] if ratios else None
        print("幅度标定 A = mix_real / mix_proxy = %.4f（取自 %d 帧中位）" % (A, len(ratios)))
        print("实测 mix 峰值 = %d" % max(abs(x) for x in mix_r))
    if A is None:
        A = 1.0
        print("警告：无实测数据可标定，A 取 1.0（电平不保证与板上一致）")

    raw = [int(A*x) for x in mix_m]
    pk  = max(abs(x) for x in raw)
    print("5s mix 峰值 = %d (%.2f dBFS @24bit, 24bit满幅8388607)" %
          (pk, 20*math.log10(max(pk, 1)/8388607.0)))
    s16 = [x >> 8 for x in raw]                      # 24bit -> 16bit
    write_wav(out + ".wav", s16)
    sc = 29000.0/max(abs(x) for x in s16)            # 归一化版，便于小喇叭试听
    write_wav(out + "_norm.wav", [int(x*sc) for x in s16])
    print("已写 %s.wav（原始电平）与 %s_norm.wav（归一化 -1dBFS 附近）" % (out, out))

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else "mix_dump.txt",
         sys.argv[2] if len(sys.argv) > 2 else "d11_old_5s",
         float(sys.argv[3]) if len(sys.argv) > 3 else 5.0)