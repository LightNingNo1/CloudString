// transcribe.js - MP3 -> 拨弦模式 32 弦引导事件 转录流水线（次功能）
// 流程：mpg123 解码 -> 混单声道 -> 重采样 22050Hz -> basic-pitch 推理
//       -> 主旋律提取(单音化) -> 白键量化到 32 弦 -> {弦号,时值} 事件编码
// 32 弦定弦与 FPGA song_rom.v / pitch_32v.v 完全一致（C3~F7 连续白键竖琴定弦）。
// 注：手动乐谱输入（score.js）已取代本模块成为主功能；本流水线保留作快速转谱辅助。
const fs = require('fs');
const path = require('path');
const tf = require('@tensorflow/tfjs');
const { BasicPitch, outputToNotesPoly, noteFramesToTime, addPitchBendsToNoteEvents } = require('@spotify/basic-pitch');

const TARGET_SR = 22050;      // basic-pitch 固定输入采样率
const MAX_EVENTS = 255;       // song_ram 深度：255 音符 + 1 曲终标记
const GRID_DT = 0.02;         // 主旋律提取时间格（20ms）
const MIN_EVENT_MS = 100;     // 事件最短时值
const SHORT_SEG_S = 0.12;     // 短音段并入阈值

// ---- 32 弦定弦：v0..31 = C3~F7 连续白键（十二平均律，与 FPGA pitch_32v.v 一致） ----
const WHITE_SEMIS = [0, 2, 4, 5, 7, 9, 11];   // 白键相对本八度 C 的半音数
const STRING_MIDI = [];
for (let s = 0; s < 32; s++)
    STRING_MIDI.push(48 + 12 * Math.floor(s / 7) + WHITE_SEMIS[s % 7]);

const NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
function midiName(m) { return NOTE_NAMES[m % 12] + (Math.floor(m / 12) - 1); }

// MIDI 音高 -> 弦号：量化到最近白键（平分取低音弦），越界吸附边界弦
function midiToString(midi) {
    if (midi <= 48) return 0;
    if (midi >= 102) return 31;
    let best = 0, bestDist = Infinity;
    for (let s = 0; s < 32; s++) {
        const d = Math.abs(midi - STRING_MIDI[s]);
        if (d < bestDist) { bestDist = d; best = s; }
    }
    return best;
}

// 事件 24 位编码：{cnt1[1:0], n0[4:0], n1[4:0], 时值(10ms)[11:0]}
// 自动转谱为单音旋律（cnt1=0、n1=0）；双音混音事件由手动乐谱 score.js 编码。
// 弦号 = 层×8 + 片内号；时值 0 = 曲终标记（由 END 帧自动补，此处从 1 起）
function encodeEvent(s, durMs) {
    const dur = Math.min(4095, Math.max(1, Math.round(durMs / 10)));
    return (s << 17) | dur;
}

// ---- MP3 解码 -> 混单声道 -> 重采样 22050Hz ----
async function decodeToMono22050(filePath, onStage) {
    onStage && onStage('decode', 0.05);
    const { MPEGDecoder } = await import('mpg123-decoder');   // 纯 ESM 包，动态导入
    const decoder = new MPEGDecoder();
    await decoder.ready;   // WASM 异步初始化，就绪后才能 decode
    const mp3 = new Uint8Array(fs.readFileSync(filePath));
    const { channelData, sampleRate } = decoder.decode(mp3);
    decoder.free();
    onStage && onStage('decode', 0.5);
    let mono = channelData[0];
    if (channelData.length > 1) {   // 多声道平均混单
        mono = new Float32Array(channelData[0].length);
        for (let i = 0; i < mono.length; i++) {
            let s = 0;
            for (let c = 0; c < channelData.length; c++) s += channelData[c][i];
            mono[i] = s / channelData.length;
        }
    }
    onStage && onStage('decode', 0.75);
    return resample(mono, sampleRate, TARGET_SR);
}

function resample(src, srcRate, dstRate) {
    if (srcRate === dstRate) return src;
    const ratio = srcRate / dstRate;
    const n = Math.floor(src.length / ratio);
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) {
        const pos = i * ratio;
        const i0 = Math.floor(pos);
        const frac = pos - i0;
        const i1 = i0 + 1 < src.length ? i0 + 1 : i0;
        out[i] = src[i0] * (1 - frac) + src[i1] * frac;
    }
    return out;
}

// ---- basic-pitch 模型（进程内单例，缓存避免重复加载） ----
let modelPromise = null;
function loadModel() {
    if (!modelPromise) {
        modelPromise = (async () => {
            tf.setBackend('cpu');   // Node 环境显式启用内置后端
            const modelDir = path.join(__dirname, 'node_modules', '@spotify', 'basic-pitch', 'model');
            const modelJson = JSON.parse(fs.readFileSync(path.join(modelDir, 'model.json'), 'utf8'));
            const manifest = modelJson.weightsManifest[0];
            // 必须传 ArrayBuffer：tfjs decodeWeights 对 int32 权重按字节视图读取
            const weightData = new Uint8Array(fs.readFileSync(path.join(modelDir, manifest.paths[0]))).buffer;
            const model = await tf.loadGraphModel({
                load: async () => ({
                    modelTopology: modelJson.modelTopology,
                    weightSpecs: manifest.weights,
                    weightData
                })
            });
            return new BasicPitch(model);
        })();
    }
    return modelPromise;
}

// ---- 主旋律提取（单音化）：20ms 格选最强音 -> 连续同音合并为事件段 ----
// 音域加权：低音伴奏（<C3）物理塌陷且常压过人声，排除；人声旋律窗口（A3~C6）
// 加权 2x 让旋律线不被贝斯带偏；高音区（>C6）保留但弱化（常为泛音/装饰）。
function melodyWeight(midi) {
    if (midi < 48) return 0;                      // <C3：32 弦最低音，量化全塌到弦0，无意义
    if (midi >= 55 && midi <= 84) return 2.0;     // A3~C6：人声/主奏旋律窗口，优先
    if (midi < 55) return 1.0;                    // C3~A3：保留但权重低
    return 1.2;                                   // >C6：泛音/装饰，弱化
}
function extractMelody(notes) {
    if (!notes.length) return [];
    notes.sort((a, b) => a.startTimeSeconds - b.startTimeSeconds);
    const total = notes[notes.length - 1].startTimeSeconds + notes[notes.length - 1].durationSeconds;
    const nGrid = Math.max(1, Math.ceil(total / GRID_DT));
    const grid = new Int32Array(nGrid).fill(-1);
    for (let k = 0; k < notes.length; k++) {
        const n = notes[k];
        const s0 = Math.max(0, Math.floor(n.startTimeSeconds / GRID_DT));
        const s1 = Math.min(nGrid - 1, Math.floor((n.startTimeSeconds + n.durationSeconds) / GRID_DT));
        for (let g = s0; g <= s1; g++) {
            const cur = grid[g];
            const curW = cur >= 0 ? notes[cur].amplitude * melodyWeight(notes[cur].pitchMidi) : -1;
            const newW = n.amplitude * melodyWeight(n.pitchMidi);
            if (curW < 0 || newW > curW) grid[g] = k;
        }
    }
    // 连续同音高格合并为段（末尾哨兵强制收尾）
    const segs = [];
    let cur = -1, start = 0;
    for (let g = 0; g <= nGrid; g++) {
        const k = g < nGrid ? grid[g] : -2;
        const p = k >= 0 ? notes[k].pitchMidi : -1;
        if (p !== cur) {
            if (cur >= 0) segs.push({ start: start * GRID_DT, end: g * GRID_DT, midi: cur });
            cur = p; start = g;
        }
    }
    // 短段（颤音/识别噪声）并入前段，保持旋律骨干
    const out = [];
    for (const s of segs) {
        if (s.end - s.start < SHORT_SEG_S && out.length) out[out.length - 1].end = s.end;
        else out.push({ start: s.start, end: s.end, midi: s.midi });
    }
    return out;
}

// ---- 事件化 + 超长压缩（>64 事件时吞掉最短音并入邻居） ----
function segsToEvents(segs) {
    const evs = [];
    for (const s of segs) {
        const midi = s.midi;
        const durMs = Math.max(MIN_EVENT_MS, Math.round((s.end - s.start) * 1000));
        evs.push({
            s: midiToString(midi),
            midi,
            noteName: midiName(midi),
            durMs,
            layer: midiToString(midi) >>> 3,
            inner: midiToString(midi) & 7
        });
    }
    return evs;
}

function compressTo(evs, maxN) {
    const arr = evs.slice();
    let dropped = 0;
    while (arr.length > maxN) {
        let mi = 1;                       // 找最短事件（首事件并入其后时用 index0 也可）
        for (let i = 2; i < arr.length; i++) if (arr[i].durMs < arr[mi].durMs) mi = i;
        const victim = arr.splice(mi, 1)[0];
        const tgt = mi < arr.length ? arr[mi] : arr[mi - 1];
        tgt.durMs += victim.durMs;        // 时值并入邻居（尾事件则并入前件）
        dropped++;
    }
    return { events: arr, dropped };
}

// ---- 对外主入口 ----
async function transcribeMp3(filePath, hooks = {}) {
    const t0 = Date.now();
    const audio = await decodeToMono22050(filePath, hooks.onStage);
    hooks.onStage && hooks.onStage('decode', 1);

    hooks.onStage && hooks.onStage('transcribe', 0);
    const bp = await loadModel();
    const frames = [], onsets = [], contours = [];
    await bp.evaluateModel(
        audio,
        (f, o, c) => { frames.push(...f); onsets.push(...o); contours.push(...c); },
        (p) => hooks.onStage && hooks.onStage('transcribe', p)
    );

    hooks.onStage && hooks.onStage('post', 0);
    const notes = noteFramesToTime(
        addPitchBendsToNoteEvents(contours, outputToNotesPoly(frames, onsets, 0.25, 0.25, 5))
    );
    const { events, dropped } = compressTo(segsToEvents(extractMelody(notes)), MAX_EVENTS);
    const encoded = events.map(e => encodeEvent(e.s, e.durMs));
    hooks.onStage && hooks.onStage('post', 1);

    return {
        events,
        encoded,
        dropped,
        meta: {
            sourceSec: audio.length / TARGET_SR,
            rawNoteCount: notes.length,
            eventCount: events.length,
            compressedDropped: dropped,
            modelMs: Date.now() - t0
        }
    };
}

module.exports = { transcribeMp3, loadModel, midiToString, midiName, encodeEvent, STRING_MIDI };
