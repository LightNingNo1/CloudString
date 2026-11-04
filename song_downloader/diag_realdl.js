// diag_realdl.js - 真实串口下载诊断：通过 bridge 连真串口重放下载，并用 QUERY 验证 CNT
// 用法: node diag_realdl.js COM13
const { spawn } = require('child_process');
const path = require('path');
const { attachPort, feedRx, downloadSong, buildFrame, parseFrames, CMD } = require('./download.js');
const { encodeEvent } = require('./transcribe.js');

const COM = process.argv[2] || 'COM13';
const BAUD = 115200;

function makeEvents(n) {
    const evs = [];
    for (let i = 0; i < n; i++) { const s = (i * 5) % 16; evs.push({ s, durMs: 300 }); }
    return evs.map((e) => encodeEvent(e.s, e.durMs));
}

function openBridge() {
    return new Promise((resolve) => {
        const bridge = spawn(path.join(__dirname, 'bridge.exe'), [COM, String(BAUD)], { stdio: ['pipe','pipe','pipe'] });
        let opened = false;
        let out = Buffer.alloc(0);
        const port = {
            isOpen: false,
            write(buf, cb) { try { if (!this.isOpen) return cb && cb(new Error('未打开')); bridge.stdin.write(buf); cb && cb(); } catch (e) { cb && cb(e); } }
        };
        bridge.stderr.on('data', d => {
            if (d.toString().includes('BRIDGE_OPEN_OK') && !opened) {
                opened = true; port.isOpen = true;
                bridge.stdout.on('data', b => { for (const x of b) feedRx(x); });
                console.log('OPEN_OK');
                resolve({ bridge, port });
            }
        });
        setTimeout(() => { if (!opened) { console.log('OPEN_FAIL'); try { bridge.kill(); } catch {} resolve(null); } }, 3000);
    });
}

// 发一帧 QUERY 并手动解析 STATUS（download.js 未暴露查询，这里直接解析）
function queryStatus(bridge) {
    return new Promise((resolve) => {
        const t0 = Date.now();
        let outBuf = Buffer.alloc(0);
        const h = (d) => {
            outBuf = Buffer.concat([outBuf, d]);
            while (outBuf.length >= 7) {
                let idx = -1;
                for (let i = 0; i < outBuf.length - 1; i++) if (outBuf[i]===0xAA && outBuf[i+1]===0x55) { idx=i; break; }
                if (idx === -1) break;
                if (idx > 0) outBuf = outBuf.slice(idx);
                if (outBuf.length < 7) break;
                const len = outBuf[2], cmd = outBuf[3];
                if (len === 2 && cmd === 0x92) {
                    const stat = outBuf[4], cnt = outBuf[5];
                    const sum = (2 + 0x92 + stat + cnt) & 0xFF;
                    if (outBuf[6] === sum) {
                        bridge.stdout.removeListener('data', h);
                        resolve({ playEn: !!(stat&1), dlOk: !!(stat&2), cnt });
                    } else outBuf = outBuf.slice(1);
                } else outBuf = outBuf.slice(1);
            }
        };
        bridge.stdout.on('data', h);
        bridge.stdin.write(buildFrame(CMD.QUERY, []));
    });
}

async function main() {
    const o = await openBridge();
    if (!o) process.exit(1);
    const { bridge, port } = o;
    attachPort(port);

    // 1. 下载前状态
    const before = await queryStatus(bridge);
    console.log('下载前 STATUS: play_en=' + before.playEn + ' dl_ok=' + before.dlOk + ' CNT=' + before.cnt);

    // 2. 制造 40 事件并下载
    const events = makeEvents(40);
    console.log('开始下载 ' + events.length + ' 个事件...');
    try {
        await downloadSong(events, (p) => console.log('  ' + p.text));
        console.log('downloadSong 返回成功（所有帧 ACK 已确认）');
    } catch (e) {
        console.log('downloadSong 失败: ' + e.message);
        try { bridge.kill(); } catch {}
        process.exit(3);
    }

    // 3. 下载后状态（等 FPGA 稳定几百 ms）
    await new Promise(r => setTimeout(r, 500));
    const after = await queryStatus(bridge);
    console.log('下载后 STATUS: play_en=' + after.playEn + ' dl_ok=' + after.dlOk + ' CNT=' + after.cnt);

    // 判定
    if (after.cnt >= 40) console.log('\n>>> 结论: DATA 成功写入 RAM（CNT=' + after.cnt + '），FPGA 下载链路正常');
    else if (after.cnt === 0 && after.dlOk) console.log('\n>>> 结论: END 通过但 CNT=0 => DATA 未写入 RAM => 固件 DATA 落盘逻辑有问题');
    else console.log('\n>>> 结论: 其他异常（CNT=' + after.cnt + ' dl_ok=' + after.dlOk + '）');

    try { bridge.kill(); } catch {}
    process.exit(0);
}
main();