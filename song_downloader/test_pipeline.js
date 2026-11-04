// test_pipeline.js - 端到端验证：真实 MP3 -> 解码 -> 转谱 -> 事件编码 -> 帧打包
// 预期：harp_C3.mp3 识别为 C3(v0)，vio_A4.mp3 识别为 A4(v13)，vio_C4.mp3 识别为 C4(v7)
const path = require('path');
const { transcribeMp3, midiToString, encodeEvent } = require('./transcribe.js');
const { CMD, buildFrame, parseFrames } = require('./download.js');

const REF = 'D:\\桌面\\嵌赛高云\\LC G1\\LC G1\\_syntest\\ref';

const CASES = [
    { file: 'harp_C3.mp3', expectMidi: 48, expectS: 0 },
    { file: 'vio_A4.mp3', expectMidi: 69, expectS: 13 },
    { file: 'vio_C4.mp3', expectMidi: 60, expectS: 7 }
];

function framesRoundtripTest() {
    // DATA 帧：IDX + 2 事件（32 位）
    const payload = [0, 0x08, 0x14, 0xA8, 0x14];   // idx0 + v8(C4)八分 + v13(A4)八分
    const frame = buildFrame(CMD.DATA, payload);
    console.log('  DATA 帧 hex:', frame.toString('hex'));
    const frames = parseFrames(Array.from(frame));
    if (frames.length !== 1) throw new Error(`帧解析失败: ${frames.length} 帧`);
    if (frames[0].cmd !== CMD.DATA) throw new Error('帧命令不符');
    if (frames[0].payload.join(',') !== payload.join(',')) throw new Error('帧负载不符');
    console.log('  帧打包/解析回读 OK');
    // BEGIN 帧 5 字节：AA 55 00 01 01
    const b = buildFrame(CMD.BEGIN, []);
    if (b.toString('hex') !== 'aa55000101') throw new Error('BEGIN 帧不符: ' + b.toString('hex'));
    console.log('  BEGIN 帧:', b.toString('hex'), 'OK');
}

async function main() {
    let pass = 0;
    for (const c of CASES) {
        const f = path.join(REF, c.file);
        console.log(`\n===== ${c.file} （期望 midi=${c.expectMidi} -> 弦 ${c.expectS}） =====`);
        const res = await transcribeMp3(f, {
            onStage: (s, p) => process.stdout.write(`  [${s} ${(p * 100).toFixed(0)}%]\r`)
        });
        console.log('');
        console.log('  meta:', JSON.stringify(res.meta));
        console.log('  事件数:', res.events.length);
        for (const e of res.events.slice(0, 10))
            console.log(`   ev: ${e.noteName} midi=${e.midi} 弦${e.s} (层${e.layer} 内${e.inner}) dur=${e.durMs}ms code=0x${encodeEvent(e.s, e.durMs).toString(16).padStart(4, '0')}`);
        const ok = res.events.length > 0 && res.events[0].midi === c.expectMidi;
        console.log(ok ? '  ✓ 识别正确' : '  ✗ 识别不符（首事件应为主音）');
        if (ok) pass++;
    }
    console.log(`\n===== 帧打包/解析回读 =====`);
    framesRoundtripTest();

    // 超 64 事件压缩测试（编码器位域验证；压缩逻辑已在管线内）
    const ev = encodeEvent(31, 20470);   // 层3 内7 + 满时值 = 全 1 = 0xFFFF
    if (ev !== 0xFFFF) throw new Error('encodeEvent 边界错误: ' + ev.toString(16));
    const ev2 = encodeEvent(8, 100);   // v8 = 层1 内0
    if ((ev2 >> 11 & 3) !== 1 || (ev2 >> 13 & 7) !== 0) throw new Error('encodeEvent 位域错误: ' + ev2.toString(16));
    console.log('  encodeEvent 位域边界 OK (v31 max:0xFFFF, v8:0x' + ev2.toString(16) + ')');

    console.log(`\n结果: ${pass}/${CASES.length} 用例通过`);
    process.exit(pass === CASES.length ? 0 : 1);
}

main().catch((e) => { console.error('失败:', e); process.exit(1); });
