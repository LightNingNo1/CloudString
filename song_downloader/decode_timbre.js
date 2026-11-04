// 解码 FPGA additive_engine.v / ADSR.v 中的音色参数表
const fs = require('fs');

// ---- 泛音权重表（拨弦=竖琴 / 拉弦=小提琴），Q15 ----
const W_PLK = BigInt('0x' + '000000000000000000000000000000000000000000000FD50B3519190D543B87');
const W_BOW = BigInt('0x' + '0044006B00AA010D01AA02A4035302F604B2054405E90BCA07710D3B25491A66');

function decodeW(w) {
    const arr = [];
    for (let n = 0; n < 16; n++) {
        arr.push(Number((w >> BigInt(16 * n)) & 0xFFFFn));
    }
    return arr; // arr[0]=H1 ... arr[15]=H16
}

// ---- 泛音衰减右移位数表 SH_TBL（80bit，16 个 5bit，最低 5bit = H1） ----
const SH_TBL = BigInt('0x6318C6318D6B5CF7C211');
function decodeSH() {
    const arr = [];
    for (let n = 0; n < 16; n++) {
        arr.push(Number((SH_TBL >> BigInt(5 * n)) & 0x1Fn));
    }
    return arr; // arr[0]=H1 ...
}

const fsym = 48000; // 先显示 96k 与 48k 两套，APP 用秒更直接
const FS = 96000;

console.log('=== 泛音权重 W（Q15） ===');
for (const [name, w] of [['拨弦PLK', W_PLK], ['拉弦BOW', W_BOW]]) {
    const a = decodeW(w);
    const h1 = a[0];
    console.log(`\n[${name}] H1=${h1}`);
    a.forEach((v, i) => {
        if (v !== 0) {
            const db = 20 * Math.log10(v / h1);
            console.log(`  H${i + 1}: ${v}  (${db.toFixed(1)} dB)`);
        }
    });
    const sum = a.reduce((x, y) => x + y, 0);
    console.log(`  ΣW = ${sum}`);
}

console.log('\n=== 泛音衰减 SH_TBL（基准，voff=0 低音档） ===');
const sh = decodeSH();
sh.forEach((v, i) => {
    const tau96 = Math.pow(2, v) / FS;
    const tau48 = Math.pow(2, v) / 48000;
    console.log(`  H${i + 1}: SH=${v}  τ96k=${tau96.toFixed(4)}s  (τ48k=${tau48.toFixed(4)}s)`);
});

console.log('\n=== 各八度档 voff 下的有效 SH 与 τ（96kHz，钳位 11..17） ===');
for (let voff = 0; voff <= 3; voff++) {
    const row = sh.map((v, i) => {
        const shc = Math.max(11, v - voff);
        const tau = Math.pow(2, shc) / FS;
        return { n: i + 1, shc, tau };
    });
    const s = row.map(r => `H${r.n}=${r.shc}(${(r.tau * 1000).toFixed(0)}ms)`).join(' ');
    console.log(`  voff=${voff} (v=${voff * 8}..${voff * 8 + 7}): ${s}`);
}

console.log('\n=== ADSR 主包络（拨弦 mode=0） ===');
console.log(`  Attack: A_INC=114/采样，0->32767 需 ${Math.round(32767 / 114)} 采样 = ${(32767 / 114 / FS * 1000).toFixed(2)} ms（线性）`);
console.log(`  Decay : D_SH=17, τ=${(Math.pow(2, 17) / FS).toFixed(4)}s = ${(Math.pow(2, 17) / FS * 1000).toFixed(0)}ms，衰减到 -6dB(幅度半)即转 Release`);
console.log(`          到 -6dB 耗时 = ${(Math.log(2) * Math.pow(2, 17) / FS * 1000).toFixed(0)}ms`);
console.log(`  Release: R_SH=18, τ=${(Math.pow(2, 18) / FS).toFixed(4)}s = ${(Math.pow(2, 18) / FS * 1000).toFixed(0)}ms`);
console.log(`  噪声门: GATE_AMP=400 (${(20 * Math.log10(400 / 32767)).toFixed(1)} dB)，尾音截断`);