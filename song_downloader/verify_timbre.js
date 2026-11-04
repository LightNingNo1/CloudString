// 离线验证 audio_player.js 的 FPGA 音色复刻数学（不依赖 Web Audio）
const W_PLK = [15239, 3412, 6425, 2869, 4053];
const W_REL = W_PLK.map(w => w / W_PLK[0]);
const SUMW = W_REL.reduce((a, b) => a + b, 0);
const SH_PLK = [17, 16, 16, 15, 15];
const ATK_MS = 3.0, SH_DECAY = 17, SH_REL = 18;
const D_END = 16384 / 32767, GATE = 400 / 32767;
const NOTE_PEAK = 0.85, FP_FS = 96000;

const WHITE_SEMIS = [0, 2, 4, 5, 7, 9, 11];
function stringToFreq(s) {
    const degree = s % 7, octave = 3 + Math.floor(s / 7);
    const midi = 12 * (octave + 1) + WHITE_SEMIS[degree];
    return 440 * Math.pow(2, (midi - 69) / 12);
}

function synth(fs, s, RENDER_SEC = 5.0) {
    const voff = s >> 3, f0 = stringToFreq(s);
    const N = Math.round(RENDER_SEC * fs);
    const data = new Float32Array(N);
    const partials = [];
    for (let n = 0; n < 5; n++) {
        const sh = Math.max(11, SH_PLK[n] - voff);
        const tau = Math.pow(2, sh) / FP_FS;
        partials.push({ w: W_REL[n], k: Math.exp(-1 / (tau * fs)) });
    }
    const atkN = Math.max(1, Math.round(ATK_MS / 1000 * fs));
    const kD = Math.exp(-1 / ((Math.pow(2, SH_DECAY) / FP_FS) * fs));
    const kR = Math.exp(-1 / ((Math.pow(2, SH_REL) / FP_FS) * fs));
    const norm = NOTE_PEAK / SUMW;
    const henv = partials.map(() => 1.0);
    let phase = 0, main = 0, mainAmp = 1.0;
    for (let i = 0; i < N; i++) {
        if (i < atkN) main = (i + 1) / atkN;
        else { mainAmp *= (mainAmp > D_END) ? kD : kR; main = mainAmp; if (main < GATE) main = 0; }
        for (let p = 0; p < 5; p++) henv[p] *= partials[p].k;
        let acc = 0;
        for (let p = 0; p < 5; p++) acc += Math.sin(2 * Math.PI * (p + 1) * phase) * partials[p].w * henv[p];
        data[i] = main * acc * norm;
        phase += f0 / fs; if (phase >= 1) phase -= 1;
    }
    return data;
}

function findTimeToAmp(data, fs, target) {
    for (let i = 0; i < data.length; i++) {
        // 取包络：用局部峰值的滑动包络近似（主包络）
    }
    return -1;
}

for (const fs of [44100, 48000]) {
    console.log(`\n===== fs=${fs} =====`);
    // 1) 主包络 -6dB 时间（用 H1 单音的包络近似：峰值滑动平均）
    //    直接按公式推：t_D_to_half = ln(2) * 2^17 / 96000
    console.log(`理论 D 段到 -6dB 时间 = ${(Math.log(2) * Math.pow(2, SH_DECAY) / FP_FS * 1000).toFixed(1)} ms`);
    console.log(`理论 R 段 τ = ${(Math.pow(2, SH_REL) / FP_FS * 1000).toFixed(1)} ms`);
    console.log(`理论 H1 τ(voff=0) = ${(Math.pow(2, SH_PLK[0]) / FP_FS * 1000).toFixed(1)} ms`);
    console.log(`理论 H1 τ(voff=3) = ${(Math.pow(2, Math.max(11, SH_PLK[0] - 3)) / FP_FS * 1000).toFixed(1)} ms`);

    // 2) 各弦峰值检查
    let maxPeak = 0, maxPeakS = -1;
    for (let s = 0; s < 32; s++) {
        const d = synth(fs, s, 3.0);
        for (let i = 0; i < d.length; i++) {
            const a = Math.abs(d[i]);
            if (a > maxPeak) { maxPeak = a; maxPeakS = s; }
        }
    }
    console.log(`全局峰值 = ${maxPeak.toFixed(4)}（弦 ${maxPeakS}，${stringToFreq(maxPeakS).toFixed(1)}Hz）${maxPeak < 1.0 ? ' OK 不削顶' : ' ！！削顶'}`);

    // 3) 抽样几根弦的峰值与首个非零样本时延
    for (const s of [0, 7, 8, 16, 24, 31]) {
        const d = synth(fs, s, 1.0);
        let pk = 0; for (let i = 0; i < d.length; i++) pk = Math.max(pk, Math.abs(d[i]));
        console.log(`  弦${String(s).padStart(2)} (${stringToFreq(s).toFixed(1)}Hz, voff=${s >> 3}) 峰值=${pk.toFixed(4)}`);
    }
}