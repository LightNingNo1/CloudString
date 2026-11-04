// audio_player.js - FPGA 音色 1:1 复刻播放器（Web Audio API）
// ----------------------------------------------------------------------
// 音色数学逐采样复刻自 FPGA 合成链（LC G1/LC G1/src）：
//   additive_engine.v  32 声部 x 16 泛音加法合成（正弦表 + 泛音独立指数衰减）
//   ADSR.v             主包络（拨弦 ADR / 拉弦 ASR）
//   pitch_32v.v        32 弦定弦（拨弦 C3~F7 白键 / 拉弦 4 弦 x 8 段全音）
//   tone_gen_top.v     master_vol=0x7FFF（满幅）、SHV=9
//
// 双模式：
//   拨弦(竖琴) mode=pluck：仅 H1~H5 非零，泛音独立指数泄漏衰减（SH 随八度档 voff 递减），
//     主包络 3ms 起音 -> Decay(τ=1.37s 到 -6dB) -> Release(τ=2.73s)。
//   拉弦(小提琴) mode=bow：H1~H16 十六个泛音、持续期内恒满幅（无逐泛音衰减），
//     主包络 42.7ms 慢起振 -> Sustain(满幅) -> Release(τ=85.3ms)。用振荡器 + 周期波形
//     持续发声，按事件时值持音后进入释放，还原弓弦"慢起振 + 快收弓"的持续感。
//   默认无颤音（FPGA 颤音仅在按住编码器轴开关时生效，录制不包含颤音 LFO）。
//
// 弦号 -> 频率：
//   拨弦 s: 音级 = s%7，八度 = 3 + floor(s/7)；MIDI = 48 + 12*floor(s/7) + WHITE_SEMIS[s%7]
//   拉弦 v: 弦号 = v>>3（G3/D4/A4/E5），段号 = v&7；频率 = OPEN_BOW[s] * 2^(2k/12)

const WHITE_SEMIS = [0, 2, 4, 5, 7, 9, 11];   // C D E F G A B 相对本八度 C 的半音数

function stringToFreq(s) {
    const degree = s % 7;
    const octave = 3 + Math.floor(s / 7);
    const midi = 12 * (octave + 1) + WHITE_SEMIS[degree];
    return 440 * Math.pow(2, (midi - 69) / 12);
}

// ---------------- FPGA 拨弦(竖琴) 音色参数 ----------------
const NOTE_PEAK   = 0.85;            // 单音归一化峰值（相对 Web Audio 满幅 1.0）
const MASTER_VOLUME = 0.9;           // 主音量

const W_PLK = [15239, 3412, 6425, 2869, 4053];     // 泛音权重 Q15（H1..H5）
const W_PLK_REL = W_PLK.map(w => w / W_PLK[0]);    // 相对基频 H1 的线性幅度
const SUMW_PLK  = W_PLK_REL.reduce((a, b) => a + b, 0);

const SH_PLK   = [17, 16, 16, 15, 15];   // 泛音衰减右移位（基准 voff=0）
const ATK_MS    = 3.0;                   // 主包络起音 3ms（线性）
const SH_DECAY  = 17;                    // Decay 段 τ = 2^17/fs = 1.365s
const SH_REL    = 18;                    // Release 段 τ = 2^18/fs = 2.731s
const D_END     = 16384 / 32767;         // -6dB（幅度减半转 Release）
const GATE      = 400 / 32767;           // -38.3dB 噪声门（尾音截断）
const RENDER_SEC = 5.0;                  // 预渲染时长（秒）
const FADE_SEC   = 0.08;                 // 末尾淡出时长（秒）
const FP_FS      = 96000;                // FPGA 采样率（用于换算时间常数）

// ---------------- FPGA 拉弦(小提琴) 音色参数 ----------------
// H1..H16 泛音权重（Q15，stehady-state 谱：H2 略高于基音、奇偶混合、谐波延伸到 16 次）
const W_BOW = [6758, 9545, 3387, 1905, 3018, 1513, 1348, 1202, 758, 851, 676, 426, 269, 170, 107, 68];
const BOW_ATK_MS     = 42.7;        // 起音 4096 点 @96kHz（弓毛渐咬弦的慢起振）
const BOW_REL_TAU_MS = 85.3;        // 释放 τ = 2^13/96kHz（弓离弦即止）

// 拉弦 4 弦空弦（G3 D4 A4 E5，标准小提琴定弦）
const OPEN_BOW = [196.00, 293.66, 440.00, 659.26];
function bowStringToFreq(v) {
    const s = v >> 3, k = v & 7;
    return OPEN_BOW[s] * Math.pow(2, (2 * k) / 12);
}

// 预生成某根弦的完整拨弦音色波形（含全部泛音 + 独立包络 + 主 ADSR）
function synthStringBuffer(ctx, s) {
    const fs = ctx.sampleRate;
    const voff = s >> 3;                       // 八度衰减档 0..3（v0-7/8-15/16-23/24-31）
    const f0 = stringToFreq(s);
    const N = Math.max(1, Math.round(RENDER_SEC * fs));
    const fadeN = Math.min(N, Math.round(FADE_SEC * fs));
    const buf = ctx.createBuffer(1, N, fs);
    const data = buf.getChannelData(0);

    // 各泛音：相对幅度 + 泄漏系数。FPGA 时间常数 τ = 2^SH / 96kHz（秒），
    // 在 Web Audio 采样率 fs 下换算为逐采样泄漏因子 exp(-1/(τ·fs))，保证 τ 秒与 FPGA 一致。
    const partials = [];
    for (let n = 0; n < 5; n++) {
        const sh = Math.max(11, SH_PLK[n] - voff);   // 钳到引擎可表达的 11..17
        const tau = Math.pow(2, sh) / FP_FS;          // 秒
        partials.push({ w: W_PLK_REL[n], k: Math.exp(-1 / (tau * fs)) });
    }

    const atkN = Math.max(1, Math.round(ATK_MS / 1000 * fs));
    const kD = Math.exp(-1 / ((Math.pow(2, SH_DECAY) / FP_FS) * fs));
    const kR = Math.exp(-1 / ((Math.pow(2, SH_REL) / FP_FS) * fs));
    const norm = NOTE_PEAK / SUMW_PLK;

    const henv = partials.map(() => 1.0);   // 各泛音包络（note_on 满幅，随即泄漏）
    let phase = 0;
    let main = 0;        // 起音段线性幅值
    let mainAmp = 1.0;   // 泄漏段幅度（满幅起）

    for (let i = 0; i < N; i++) {
        // 主包络
        if (i < atkN) {
            main = (i + 1) / atkN;
        } else {
            mainAmp *= (mainAmp > D_END) ? kD : kR;
            main = mainAmp;
            if (main < GATE) main = 0;
        }

        // 泛音独立衰减
        for (let p = 0; p < 5; p++) henv[p] *= partials[p].k;

        // 加法合成：Σ W_n · sin(2π n φ) · henv_n
        let acc = 0;
        for (let p = 0; p < 5; p++) {
            acc += Math.sin(2 * Math.PI * (p + 1) * phase) * partials[p].w * henv[p];
        }

        let v = main * acc * norm;
        if (i >= N - fadeN) v *= (N - i) / fadeN;   // 末尾淡出，杜绝截断喀嚓
        data[i] = v;

        phase += f0 / fs;
        if (phase >= 1) phase -= 1;
    }
    return buf;
}

// 拉弦周期波形系数：Σ a_n·sin(2π n φ)，把峰值归一化到 1（apex 由数值扫描求得）
function bowPeriodicCoeffs() {
    const rel = W_BOW.map(w => w / W_BOW[0]);   // H1..H16 相对基频幅度
    let peak = 0;
    const N = 8192;
    for (let i = 0; i < N; i++) {
        const phi = i / N;
        let acc = 0;
        for (let n = 1; n <= 16; n++) acc += rel[n - 1] * Math.sin(2 * Math.PI * n * phi);
        const a = Math.abs(acc);
        if (a > peak) peak = a;
    }
    const norm = 1 / (peak || 1);
    const real = new Float32Array(17);
    const imag = new Float32Array(17);
    for (let n = 1; n <= 16; n++) imag[n] = rel[n - 1] * norm;   // 正弦项
    return { real, imag };
}

// ---------------- 播放器 ----------------
class HarpPlayer {
    constructor() {
        this.ctx = null;
        this.masterGain = null;
        this.compressor = null;
        this.stringBufs = null;   // Array(32) AudioBuffer，懒生成缓存（拨弦）
        this.bowWave = null;      // 拉弦共享 PeriodicWave
        this.bowVoices = new Map(); // 拉弦每弦常驻振荡器 { osc, g }（重触发只重置包络，相位连续）
        this.mode = 'pluck';      // 'pluck' | 'bow'
        this.events = [];         // [{strings:[s0,s1?], durMs}]
        this.isPlaying = false;
        this.isPaused = false;
        this.startTime = 0;
        this.pauseTime = 0;
        this.eventIdx = 0;
        this.nextEventTime = 0;
        this.timerId = null;
        this.onProgress = null;
        this.totalDurSec = 0;
        this.activeSrcs = [];     // 当前活跃的 BufferSource/Oscillator（停止/暂停时切断）
    }

    setMode(mode) {
        this.mode = (mode === 'bow') ? 'bow' : 'pluck';
    }

    _ensureCtx() {
        if (this.ctx) return;
        const AC = window.AudioContext || window.webkitAudioContext;
        this.ctx = new AC();
        this.masterGain = this.ctx.createGain();
        this.masterGain.gain.value = MASTER_VOLUME;
        // 仅作多音和弦偶发超峰的兜底：阈值设到 0dB，单音（峰值≈0.765）完全线性。
        // 拉弦 Sustain 是持续满幅，若阈值过低会全程被压缩 -> 波形顶部压平、谐波激增，
        // 听感变亮且带失真/抽吸；FPGA 本身无压缩器，这里必须保证单音不被压。
        this.compressor = this.ctx.createDynamicsCompressor();
        this.compressor.threshold.value = 0;
        this.compressor.knee.value = 0;
        this.compressor.ratio.value = 8;
        this.compressor.attack.value = 0.003;
        this.compressor.release.value = 0.1;
        this.masterGain.connect(this.compressor);
        this.compressor.connect(this.ctx.destination);
        // 拉弦周期波形（依赖 ctx，故在 ctx 就绪后构建）
        if (!this.bowWave) {
            const c = bowPeriodicCoeffs();
            this.bowWave = this.ctx.createPeriodicWave(c.real, c.imag);
        }
    }

    _buildBuffers() {
        if (this.mode === 'bow') return;   // 拉弦走振荡器 + 周期波形，无需预渲染
        if (this.stringBufs) return;
        this.stringBufs = [];
        for (let s = 0; s < 32; s++) this.stringBufs.push(synthStringBuffer(this.ctx, s));
    }

    _resumeCtx() {
        if (this.ctx.state === 'suspended') this.ctx.resume();
    }

    // 载入事件（24 位整数数组，与 FPGA 格式一致）
    //   cnt1 = 0/1：按下事件（1 或 2 音），dur = 距上一按下事件的间隔
    //   cnt1 = 2  ：拉弦释放事件（n0=弦号），dur = 该弦实际按住时长
    // rawGap=true：dur 是"距上一个按下事件"（FPGA 录制引擎的原生语义），
    //              这里换算成"到下一个按下事件"的间隔；手动乐谱/AI 转谱传 false。
    // 拉弦按"弦号"把释放事件配到最近一次按下，得到每根弦真正的发声时长；
    // 没有配到释放的音（按住到录制结束）回落到"持续到下一个按下事件"。
    loadEvents(encodedEvents, rawGap = false) {
        const parsed = [];
        for (const ev of encodedEvents) {
            const cnt1 = (ev >> 22) & 0x3;
            const n0 = (ev >> 17) & 0x1F;
            const n1 = (ev >> 12) & 0x1F;
            const durMs = (ev & 0x0FFF) * 10;
            if (cnt1 >= 2) {
                parsed.push({ type: 'rel', s: n0, holdMs: durMs });
            } else {
                const strings = [n0];
                if (cnt1 >= 1) strings.push(n1);
                parsed.push({ type: 'on', strings, durMs, holds: {} });
            }
        }
        const pending = new Map();   // 弦号 -> 最近一次尚未配对的按下事件
        const events = [];
        for (const ev of parsed) {
            if (ev.type === 'on') {
                events.push(ev);
                for (const s of ev.strings) pending.set(s, ev);
            } else {
                const on = pending.get(ev.s);
                if (on) { on.holds[ev.s] = ev.holdMs; pending.delete(ev.s); }
            }
        }
        for (let i = 0; i < events.length; i++) {
            events[i].gapMs = rawGap
                ? ((i + 1 < events.length) ? events[i + 1].durMs : 0)
                : events[i].durMs;
        }
        this.events = events;
        let totalMs = 0;
        for (const ev of events) totalMs += ev.gapMs;
        this.totalDurSec = totalMs / 1000;
        return { eventCount: this.events.length, totalSec: this.totalDurSec };
    }

    // 触发某根拨弦（用预生成的整段音色 buffer）
    _pluckString(s, startTime) {
        this._buildBuffers();
        if (!this.stringBufs || !this.stringBufs[s]) return;
        const src = this.ctx.createBufferSource();
        src.buffer = this.stringBufs[s];
        src.connect(this.masterGain);
        src.start(startTime);
        this.activeSrcs.push(src);
    }

    // 触发某根拉弦（每弦常驻振荡器 + 起音/持音/释放包络）
    //   与 FPGA 一致：每个物理弦 = 一个声部，重复触发是"同一声部重装包络"（note_on 把
    //   amp 清零重新起音），而不是新建第二个振荡器。振荡器常驻可保证相位连续，
    //   避免两个不同相位的正弦叠加产生拍频（听感"嗡"/杂音）。
    _bowString(s, startTime, holdMs) {
        const f0 = bowStringToFreq(s);
        let v = this.bowVoices.get(s);
        if (!v) {
            const osc = this.ctx.createOscillator();
            osc.setPeriodicWave(this.bowWave);
            osc.frequency.value = f0;
            const g = this.ctx.createGain();
            g.gain.value = 0;
            osc.connect(g);
            g.connect(this.masterGain);
            osc.start(0);
            v = { osc, g };
            this.bowVoices.set(s, v);
            this.activeSrcs.push(osc);
        }
        const g = v.g;
        const hold = Math.max(holdMs, 20);
        const relStart = startTime + hold / 1000;
        // 重装包络：起点清零 -> 线性起音 -> 持音 -> 指数释放（对应 FPGA 的 A/S/R）
        g.gain.cancelScheduledValues(startTime);
        g.gain.setValueAtTime(0, startTime);
        g.gain.linearRampToValueAtTime(NOTE_PEAK, startTime + BOW_ATK_MS / 1000);
        g.gain.setTargetAtTime(0, relStart, BOW_REL_TAU_MS / 1000);
    }

    _scheduleLoop() {
        if (!this.isPlaying || this.isPaused) return;
        const now = this.ctx.currentTime;
        while (this.eventIdx < this.events.length &&
               this.nextEventTime <= now + 0.2) {
            const ev = this.events[this.eventIdx];
            const t = this.nextEventTime;
            for (const s of ev.strings) {
                if (this.mode === 'bow') {
                    // 有释放事件就用实际按住时长，否则回落到持续到下一个按下事件
                    const hold = (ev.holds && ev.holds[s] != null) ? ev.holds[s] : ev.gapMs;
                    this._bowString(s, t, hold);
                } else this._pluckString(s, t);
            }
            this.nextEventTime += ev.gapMs / 1000;
            this.eventIdx++;
        }

        if (this.onProgress) {
            const cur = Math.max(0, this.ctx.currentTime - this.startTime);
            this.onProgress(Math.min(cur, this.totalDurSec), this.totalDurSec);
        }

        if (this.eventIdx >= this.events.length) {
            const endCheck = () => {
                const cur = this.ctx.currentTime - this.startTime;
                if (cur >= this.totalDurSec + 0.5) {
                    this.isPlaying = false;
                    if (this.onProgress) this.onProgress(this.totalDurSec, this.totalDurSec);
                    if (this.onEnded) this.onEnded();
                } else {
                    this.timerId = setTimeout(endCheck, 100);
                }
            };
            endCheck();
            return;
        }

        this.timerId = setTimeout(() => this._scheduleLoop(), 50);
    }

    play() {
        if (!this.events.length) return;
        this._ensureCtx();
        this._resumeCtx();
        this._buildBuffers();
        if (this.isPaused) {
            const pauseOffset = this.pauseTime;
            this.startTime = this.ctx.currentTime - pauseOffset;
            let acc = 0;
            this.eventIdx = 0;
            this.nextEventTime = this.startTime;
            while (this.eventIdx < this.events.length &&
                   acc + this.events[this.eventIdx].gapMs / 1000 <= pauseOffset) {
                acc += this.events[this.eventIdx].gapMs / 1000;
                this.eventIdx++;
                this.nextEventTime += this.events[this.eventIdx - 1].gapMs / 1000;
            }
            this.isPaused = false;
            this._scheduleLoop();
            return;
        }
        this.stop(true);
        this.isPlaying = true;
        this.eventIdx = 0;
        this.startTime = this.ctx.currentTime + 0.05;
        this.nextEventTime = this.startTime;
        this._scheduleLoop();
    }

    pause() {
        if (!this.isPlaying || this.isPaused) return;
        this.isPaused = true;
        this.pauseTime = this.ctx.currentTime - this.startTime;
        if (this.timerId) { clearTimeout(this.timerId); this.timerId = null; }
        this._stopSources();
    }

    stop(silent) {
        this.isPlaying = false;
        this.isPaused = false;
        if (this.timerId) { clearTimeout(this.timerId); this.timerId = null; }
        this.eventIdx = 0;
        this.pauseTime = 0;
        this._stopSources();
        if (!silent && this.ctx && this.masterGain) {
            const now = this.ctx.currentTime;
            this.masterGain.gain.cancelScheduledValues(now);
            this.masterGain.gain.setValueAtTime(0, now);
            setTimeout(() => {
                if (this.ctx && this.masterGain) {
                    this.masterGain.gain.setValueAtTime(MASTER_VOLUME, this.ctx.currentTime);
                }
            }, 30);
        }
    }

    _stopSources() {
        for (const src of this.activeSrcs) { try { src.stop(); } catch (e) {} }
        this.activeSrcs = [];
        this.bowVoices.clear();   // 振荡器已 stop，下次播放需重新创建
    }

    setVolume(v) {
        if (this.masterGain) this.masterGain.gain.value = v;
    }
}

// 导出（renderer 直接 script 标签引入，挂 window）
window.HarpPlayer = HarpPlayer;
window.stringToFreq = stringToFreq;
window.bowStringToFreq = bowStringToFreq;