// query_once.js - 单次 QUERY：打开 COM13(带重试), 发一帧 QUERY, 收一帧 STATUS, 立即退出
// 用法: node query_once.js COM13
const { spawn } = require('child_process');
const path = require('path');
const COM = process.argv[2] || 'COM13';
const BAUD = 115200;

function buildFrame(cmd, payload = []) {
    const len = payload.length;
    const buf = Buffer.alloc(5 + len);
    buf[0] = 0xAA; buf[1] = 0x55; buf[2] = len; buf[3] = cmd;
    let sum = (len + cmd) & 0xFF;
    for (let i = 0; i < len; i++) { buf[4 + i] = payload[i]; sum = (sum + payload[i]) & 0xFF; }
    buf[4 + len] = sum;
    return buf;
}

function spawnBridge() {
    return new Promise((resolve) => {
        const bridge = spawn(path.join(__dirname, 'bridge.exe'), [COM, String(BAUD)], { stdio: ['pipe','pipe','pipe'] });
        let done = false;
        const settle = (ok) => { if (!done) { done = true; if (!ok) { try { bridge.kill(); } catch {} } resolve(ok ? bridge : null); } };
        bridge.stderr.on('data', d => {
            if (d.toString().includes('BRIDGE_OPEN_OK')) settle(bridge);
            else if (d.toString().includes('BRIDGE_OPEN_FAIL')) settle(null);
        });
        bridge.on('close', () => settle(null));
        setTimeout(() => settle(null), 3000);
    });
}

async function main() {
    let bridge = null;
    for (let attempt = 0; attempt < 4 && !bridge; attempt++) {
        if (attempt) { console.log('重试打开 ' + (attempt + 1) + '/4...'); await new Promise(r => setTimeout(r, 1500)); }
        bridge = await spawnBridge();
    }
    if (!bridge) { console.log('RESULT: OPEN_FAIL（多次重试均无法打开 COM13）'); process.exit(1); }
    console.log('OPEN_OK');

    let out = Buffer.alloc(0);
    let sent = false;
    const timer = setTimeout(() => { console.log('RESULT: timeout（已打开但未收到 STATUS）'); process.exit(2); }, 6000);

    bridge.stdin.on('error', () => {});
    bridge.stdout.on('data', d => {
        out = Buffer.concat([out, d]);
        while (out.length >= 7) {
            let idx = -1;
            for (let i = 0; i < out.length - 1; i++) if (out[i] === 0xAA && out[i + 1] === 0x55) { idx = i; break; }
            if (idx === -1) break;
            if (idx > 0) out = out.slice(idx);
            if (out.length < 7) break;
            const len = out[2], cmd = out[3];
            if (len === 2 && cmd === 0x92) {
                const stat = out[4], cnt = out[5];
                const sum = (2 + 0x92 + stat + cnt) & 0xFF;
                if (out[6] === sum) {
                    console.log('RESULT: play_en=' + (!!(stat & 1)) + ' dl_ok=' + (!!(stat & 2)) + ' CNT=' + cnt + ' STAT=0x' + stat.toString(16));
                    clearTimeout(timer); try { bridge.kill(); } catch {} process.exit(0);
                } else out = out.slice(1);
            } else out = out.slice(1);
        }
    });

    setTimeout(() => { if (!sent) { sent = true; bridge.stdin.write(buildFrame(0x12, [])); } }, 300);
}
main();