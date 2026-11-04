// verify_transcribe.js - 验证修复后转谱的弦号分布
const path = require('path');
const { transcribeMp3 } = require('./transcribe');

async function main() {
    const filePath = process.argv[2] || path.join('D:', '桌面', '嵌赛高云', '遇见+-+孙燕姿.mp3');
    const r = await transcribeMp3(filePath, {});
    console.log(`\n=== 转谱结果 ===`);
    console.log(`源 ${r.meta.sourceSec.toFixed(1)}s | 原始音符 ${r.meta.rawNoteCount} | 事件 ${r.meta.eventCount} | 压缩丢弃 ${r.meta.compressedDropped}`);
    console.log(`\n弦号分布 (前 32 槽):`);
    const dist = {};
    for (const e of r.events) dist[e.s] = (dist[e.s] || 0) + 1;
    const keys = Object.keys(dist).map(Number).sort((a, b) => a - b);
    let string0 = 0;
    for (const k of keys) {
        const cnt = dist[k];
        if (k === 0) string0 = cnt;
        console.log(`  弦${String(k).padStart(2)} (${r.events.find(e=>e.s===k).noteName.padEnd(4)}): ${String(cnt).padStart(2)}次`);
    }
    console.log(`\n弦00 占比: ${string0}/${r.meta.eventCount} = ${(100 * string0 / r.meta.eventCount).toFixed(1)}%`);
    console.log(`\n=== 事件序列 (前 24) ===`);
    for (let i = 0; i < Math.min(24, r.events.length); i++) {
        const e = r.events[i];
        console.log(`  #${String(i).padStart(2)} ${e.noteName.padEnd(4)} 弦${String(e.s).padStart(2)} ${e.durMs}ms`);
    }
    console.log('\n(完整事件已写入 verify_out.json)');
    require('fs').writeFileSync(path.join(__dirname, 'verify_out.json'), JSON.stringify(r.events, null, 2));
}

main().catch(e => { console.error('转谱验证失败:', e); process.exit(1); });
