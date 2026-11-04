// test_wasm.js - 对比 tfjs cpu / wasm 后端推理性能与结果一致性
const fs = require('fs');
const path = require('path');
const tf = require('@tensorflow/tfjs');
const { BasicPitch, outputToNotesPoly, noteFramesToTime, addPitchBendsToNoteEvents } = require('@spotify/basic-pitch');

const SR = 22050;
const DUR = 20;   // 20 秒测试音频

// 合成"旋律 + 低音伴奏"更接近真实歌曲：A4 主旋律 + C3 低音 + 简单节奏
function synth() {
    const samples = new Float32Array(SR * DUR);
    const melody = [440, 523.25, 659.25, 523.25, 587.33, 659.25, 783.99, 659.25]; // A4 C5 E5 ...
    for (let i = 0; i < samples.length; i++) {
        const t = i / SR;
        const beat = Math.floor(t / 0.5);
        const f = melody[beat % melody.length];
        const env = Math.min(1, t * 4) * Math.exp(-((t % 0.5) * 6));
        samples[i] = 0.5 * env * Math.sin(2 * Math.PI * f * t);
        samples[i] += 0.25 * Math.sin(2 * Math.PI * 130.81 * t); // C3 低音持续
    }
    return samples;
}

async function loadModel() {
    const modelDir = path.join(__dirname, 'node_modules', '@spotify', 'basic-pitch', 'model');
    const modelJson = JSON.parse(fs.readFileSync(path.join(modelDir, 'model.json'), 'utf8'));
    const manifest = modelJson.weightsManifest[0];
    const weightData = new Uint8Array(fs.readFileSync(path.join(modelDir, manifest.paths[0]))).buffer;
    const model = await tf.loadGraphModel({
        load: async () => ({ modelTopology: modelJson.modelTopology, weightSpecs: manifest.weights, weightData })
    });
    return new BasicPitch(model);
}

async function run(backend) {
    tf.setBackend(backend);
    const bp = await loadModel();
    const samples = synth();
    const frames = [], onsets = [], contours = [];
    const t0 = Date.now();
    await bp.evaluateModel(samples, (f, o, c) => { frames.push(...f); onsets.push(...o); contours.push(...c); }, () => {});
    const ms = Date.now() - t0;
    const notes = noteFramesToTime(addPitchBendsToNoteEvents(contours, outputToNotesPoly(frames, onsets, 0.25, 0.25, 5)));
    return { ms, notes: notes.map(n => `${Math.round(n.pitchMidi)}@${n.startTimeSeconds.toFixed(2)}s`).slice(0, 6) };
}

(async () => {
    const cpu = await run('cpu');
    console.log(`[cpu ] 推理 ${DUR}s 音频: ${cpu.ms}ms (${(cpu.ms / DUR / 1000).toFixed(2)}x 实时) 音符: ${cpu.notes.join(', ')}`);
    const wasm = await run('wasm');
    console.log(`[wasm] 推理 ${DUR}s 音频: ${wasm.ms}ms (${(wasm.ms / DUR / 1000).toFixed(2)}x 实时) 音符: ${wasm.notes.join(', ')}`);
    console.log(`加速比: ${(cpu.ms / wasm.ms).toFixed(1)}x`);
    process.exit(0);
})().catch((e) => { console.error('失败:', e); process.exit(1); });
