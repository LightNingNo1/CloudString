// melody_diag.js - 转谱质量诊断：输出音高分布统计，验证主旋律提取是否被低音带偏
const path = require('path');
const { loadModel, STRING_MIDI } = require('./transcribe');
const { BasicPitch, outputToNotesPoly, noteFramesToTime, addPitchBendsToNoteEvents } = require('@spotify/basic-pitch');
const tf = require('@tensorflow/tfjs');

async function main() {
    const filePath = process.argv[2] || path.join('D:', '桌面', '嵌赛高云', '遇见+-+孙燕姿.mp3');
    const { MPEGDecoder } = await import('mpg123-decoder');
    const fs = require('fs');
    const decoder = new MPEGDecoder();
    await decoder.ready;
    const mp3 = new Uint8Array(fs.readFileSync(filePath));
    const { channelData, sampleRate } = decoder.decode(mp3);
    decoder.free();
    let mono = channelData[0];
    if (channelData.length > 1) {
        mono = new Float32Array(channelData[0].length);
        for (let i = 0; i < mono.length; i++) {
            let s = 0;
            for (let c = 0; c < channelData.length; c++) s += channelData[c][i];
            mono[i] = s / channelData.length;
        }
    }
    const ratio = sampleRate / 22050;
    const n = Math.floor(mono.length / ratio);
    const audio = new Float32Array(n);
    for (let i = 0; i < n; i++) {
        const pos = i * ratio, i0 = Math.floor(pos), frac = pos - i0;
        const i1 = i0 + 1 < mono.length ? i0 + 1 : i0;
        audio[i] = mono[i0] * (1 - frac) + mono[i1] * frac;
    }
    console.log(`解码完成: 源 ${(mono.length / sampleRate).toFixed(1)}s -> ${(n / 22050).toFixed(1)}s @22050Hz`);

    const bp = await loadModel();
    const frames = [], onsets = [], contours = [];
    await bp.evaluateModel(audio, (f, o, c) => { frames.push(...f); onsets.push(...o); contours.push(...c); }, (p) => {});
    const notes = noteFramesToTime(addPitchBendsToNoteEvents(contours, outputToNotesPoly(frames, onsets, 0.25, 0.25, 5)));

    console.log(`\n=== basic-pitch 原始音符: ${notes.length} 个 ===`);
    const dist = {};
    let ampSum = {};
    for (const n of notes) {
        const k = n.pitchMidi;
        dist[k] = (dist[k] || 0) + 1;
        ampSum[k] = (ampSum[k] || 0) + n.amplitude;
    }
    const keys = Object.keys(dist).map(Number).sort((a, b) => a - b);
    console.log('音高分布 (MIDI: 出现次数/总振幅):');
    for (const k of keys) {
        const name = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'][k % 12] + (Math.floor(k / 12) - 1);
        console.log(`  ${String(k).padStart(3)} ${name.padEnd(4)}: ${String(dist[k]).padStart(3)}次  振幅${ampSum[k].toFixed(2)}`);
    }
    const low = keys.filter(k => k < 48);
    const midHi = keys.filter(k => k >= 48);
    console.log(`\n低音区(<C3/48): ${low.length}个音高, 出现${low.reduce((a,k)=>a+dist[k],0)}次 (${(100*low.reduce((a,k)=>a+dist[k],0)/notes.length).toFixed(1)}%)`);
    console.log(`中高音区(>=C3): ${midHi.length}个音高, 出现${midHi.reduce((a,k)=>a+dist[k],0)}次`);
}

main().catch(e => { console.error('诊断失败:', e); process.exit(1); });
