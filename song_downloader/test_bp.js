// test_bp.js - 验证 basic-pitch 在 Electron 主进程(Node) 环境能否跑通
// 用合成正弦波(22050Hz 单声道) 代替真实 MP3，验证：tfjs 后端 + 模型 IOHandler 加载 + 推理
const fs = require('fs');
const path = require('path');
const tf = require('@tensorflow/tfjs');
const { BasicPitch, outputToNotesPoly, noteFramesToTime, addPitchBendsToNoteEvents } = require('@spotify/basic-pitch');

// ---- 合成 22050Hz 单声道正弦波：A4(440Hz) 1s + C5(523.25Hz) 1s，2 秒 ----
const SR = 22050;
const samples = new Float32Array(SR * 2);
const freqs = [440.0, 523.25];
for (let i = 0; i < samples.length; i++) {
    const t = i / SR;
    const f = freqs[Math.floor(t / 1.0) % 2];
    samples[i] = 0.7 * Math.sin(2 * Math.PI * f * t);
}

async function loadModel() {
    const modelDir = path.join(__dirname, 'node_modules', '@spotify', 'basic-pitch', 'model');
    const modelJson = JSON.parse(fs.readFileSync(path.join(modelDir, 'model.json'), 'utf8'));
    const manifest = modelJson.weightsManifest[0];
    // 必须传 ArrayBuffer：tfjs decodeWeights 对 int32 权重按字节视图读取，
    // 传 Uint8Array 会被逐元素拷贝（4 字节 -> 4 个 int32），解析错位
    const weightData = new Uint8Array(fs.readFileSync(path.join(modelDir, manifest.paths[0]))).buffer;
    console.log('[test] model.json 字段:', Object.keys(modelJson).join(','));
    console.log('[test] weights:', manifest.weights.length, '个, bin:', weightData.byteLength, '字节');
    const model = await tf.loadGraphModel({
        load: async () => ({
            modelTopology: modelJson.modelTopology,
            weightSpecs: manifest.weights,
            weightData
        })
    });
    return model;
}

(async () => {
    try {
        tf.setBackend('cpu');   // Node 下显式启用内置 cpu 后端
        console.log('[test] tfjs backend:', tf.getBackend());
        console.log('[test] 加载模型...');
        const t0 = Date.now();
        const model = await loadModel();
        console.log('[test] 模型加载完成', Date.now() - t0, 'ms');

        const bp = new BasicPitch(model);
        const frames = [], onsets = [], contours = [];
        let pct = 0;
        console.log('[test] 推理 2 秒正弦波...');
        const t1 = Date.now();
        await bp.evaluateModel(
            samples,
            (f, o, c) => { frames.push(...f); onsets.push(...o); contours.push(...c); },
            (p) => { if (Math.floor(p * 10) !== pct) { pct = Math.floor(p * 10); console.log('[test] 进度', pct * 10, '%'); } }
        );
        console.log('[test] 推理完成', Date.now() - t1, 'ms, frames:', frames.length);

        const notes = noteFramesToTime(
            addPitchBendsToNoteEvents(contours, outputToNotesPoly(frames, onsets, 0.25, 0.25, 5))
        );
        console.log('[test] 音符数:', notes.length);
        for (const n of notes) {
            console.log('[test]   note: start=%.3fs dur=%.3fs midi=%d amp=%.3f',
                n.startTimeSeconds, n.durationSeconds, n.pitchMidi, n.amplitude);
        }
        console.log('[test] 全部通过 ✓');
        process.exit(0);
    } catch (e) {
        console.error('[test] 失败:', e);
        process.exit(1);
    }
})();
