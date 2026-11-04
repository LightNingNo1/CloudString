// diag_query.js - 独立诊断：独占 COM13 发 QUERY 帧，读回 STATUS 判断 FPGA 状态
// 通过 XS1: 必须独占 COM13（需先断开 APP 连接）
// STATUS 帧: AA 55 02 92 STAT CNT SUM
//   STAT bit0 = play_en（指引运行中）  bit1 = dl_ok（已成功下载）
//   CNT = 已写入事件数
const { spawn } = require('child_process');
const path = require('path');
const CMD = {
    BEGIN: 0x01, DATA: 0x02, END: 0x03, PLAY: 0x10,
    STOP: 0x11, QUERY: 0x12, ERASE: 0x13
};

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

function tryOnce() {
    return new Promise((resolve) => {
        const bridge = spawn(path.join(__dirname, 'bridge.exe'), [COM, String(BAUD)], {
            stdio: ['pipe', 'pipe', 'pipe']
        });
        let opened = false;
        let outBuf = Buffer.alloc(0);
        let settled = false;
        const done = (res) => { if (!settled) { settled = true; try { bridge.kill(); } catch {} resolve(res); } };

        bridge.stderr.on('data', d => {
            const s = d.toString();
            if (s.includes('BRIDGE_OPEN_OK')) {
                opened = true;
                console.log('[bridge] OPEN OK, 发送 QUERY 帧...');
                bridge.stdin.write(buildFrame(CMD.QUERY, []));
            } else if (s.includes('BRIDGE_OPEN_FAIL')) {
                console.log('[bridge] OPEN FAIL:', s.trim());
                done({ error: s.trim() });
            }
        });

    bridge.stdout.on('data', d => {
            outBuf = Buffer.concat([outBuf, d]);
            // 找 STATUS 帧 AA 55 02 92 STAT CNT SUM
            while (outBuf.length >= 7) {
                let idx = -1;
                for (let i = 0; i < outBuf.length - 1; i++) {
                    if (outBuf[i] === 0xAA && outBuf[i + 1] === 0x55) { idx = i; break; }
                }
                if (idx === -1) { outBuf = Buffer.alloc(0); break; }
                outBuf = outBuf.slice(idx);
                if (outBuf.length < 7) break;
                const len = outBuf[2], cmd = outBuf[3];
                if (len === 2 && cmd === 0x92) {
                    const stat = outBuf[4], cnt = outBuf[5];
                    const sum = (2 + 0x92 + stat + cnt) & 0xFF;
                    if (outBuf[6] === sum) {
                        const playEn = !!(stat & 1);
                        const dlOk = !!(stat & 2);
                        console.log('=== FPGA STATUS ===');
                        console.log('STAT(raw)=0x' + stat.toString(16));
                        console.log('play_en(指引运行中) =', playEn);
                        console.log('dl_ok(下载成功)     =', dlOk);
                        console.log('已写入事件数        =', cnt);
                        if (!playEn) console.log('>>> play_en=0: FPGA 未进入播放!! LED 自然不亮');
                        else console.log('>>> play_en=1: FPGA 在播放，LED 不亮=LED 硬件问题');
                        done({ stat, playEn, dlOk, cnt });
                    } else { outBuf = outBuf.slice(1); continue; }
                } else { outBuf = outBuf.slice(1); continue; }
            }
        });

        // 打开成功但 4s 内没收到 STATUS：判定无应答
        setTimeout(() => {
            if (opened) { console.log('[diag] 已打开但超时未收到 STATUS（FPGA 未接/未上线）'); done({ timeout: true, opened }); }
        }, 4000);
    });
}

async function main() {
    for (let attempt = 1; attempt <= 5; attempt++) {
        console.log(`[diag] === 尝试 ${attempt}/5 ===`);
        const res = await tryOnce();
        if (res && !res.error && !res.timeout) { process.exit(0); }
        if (res && res.error && res.error.includes('FAIL')) {
            console.log('[diag] 打开被拒，2s 后重试（蓝牙栈不稳属间歇性）');
            await new Promise(r => setTimeout(r, 2000));
            continue;
        }
        process.exit(res && res.timeout ? 2 : 0);
    }
    console.log('[diag] 连续 5 次均被拒，蓝牙栈可能需重置');
    process.exit(2);
}
main();