// test_download_seq.js - 下载握手模拟验证：FakeFPGA 收到帧即校验并回 ACK
// 场景 1：正常下载 40 事件（BEGIN + 3×DATA + END + PLAY）
// 场景 2：首帧 DATA 的 ACK 被吞（模拟丢包）-> 应触发重发并成功
const { attachPort, feedRx, downloadSong, buildFrame, parseFrames, CMD } = require('./download.js');
const { encodeEvent } = require('./transcribe.js');

class FakeFPGA {
    constructor(opts = {}) { this.isOpen = true; this.frames = []; this.dropFirstDataAck = opts.dropFirstDataAck; this.rxBuf = []; this.eventsStored = 0; }
    write(buf, cb) {
        const bytes = Array.from(buf);
        this.frames.push(bytes);
        const parsed = parseFrames(bytes);
        if (!parsed.length) { cb && cb(new Error('收到校验失败帧: ' + bytes.map(b => b.toString(16)).join(' '))); return; }
        const f = parsed[0];
        if (f.cmd === CMD.DATA) {
            const n = (f.payload.length - 1) / 2;
            const idx = f.payload[0];
            this.eventsStored = Math.max(this.eventsStored, idx + n);   // 模拟写指针推进
        } else if (f.cmd === CMD.QUERY) {
            const stat = 0x03;   // play_en | dl_ok
            const st = Buffer.alloc(7);
            st[0] = 0xAA; st[1] = 0x55; st[2] = 2; st[3] = 0x92;
            st[4] = stat; st[5] = this.eventsStored; st[6] = (2 + 0x92 + stat + this.eventsStored) & 0xFF;
            this.rxBuf.push(...Array.from(st));
            for (const b of this.rxBuf) { feedRx(b); }
            this.rxBuf = [];
            cb && cb(); return;
        }
        const isFirstData = f.cmd === CMD.DATA && this.frames.filter((x) => x[3] === CMD.DATA).length === 1;
        if (!(f.cmd === CMD.DATA && this.dropFirstDataAck && isFirstData)) {
            const ack = buildFrame(f.cmd | 0x80, [0x01]);   // FPGA 应答帧：ACK
            this.rxBuf.push(...Array.from(ack));
            for (const b of this.rxBuf) { feedRx(b); }
            this.rxBuf = [];
        } else {
            console.log('  [fpga] 模拟丢包：首帧 DATA 不应答');
        }
        cb && cb();
    }
}

function makeEvents(n) {
    const evs = [];
    for (let i = 0; i < n; i++) {
        const s = (i * 5) % 32;
        evs.push({ s, durMs: 300 + (i % 3) * 100 });
    }
    return evs.map((e) => encodeEvent(e.s, e.durMs));
}

async function runScenario(name, opts, nEvents) {
    const fpga = new FakeFPGA(opts);
    attachPort(fpga);
    const events = makeEvents(nEvents);
    const t0 = Date.now();
    await downloadSong(events, () => {});
    const ms = Date.now() - t0;
    // 帧序列校验：BEGIN, DATA 若干（丢包场景含重发）, END, PLAY
    const cmds = fpga.frames.map((f) => f[3]);
    const dataCount = cmds.filter((c) => c === CMD.DATA).length;
    const expectData = opts.dropFirstDataAck ? Math.ceil(nEvents / 16) + 1 : Math.ceil(nEvents / 16);
    const okHead = cmds[0] === CMD.BEGIN && dataCount === expectData &&
                   cmds.indexOf(CMD.END) !== -1 && cmds.indexOf(CMD.PLAY) !== -1 &&
                   cmds[cmds.length - 1] === CMD.QUERY;   // downloadSong 末尾强制回读校验
    console.log(`\n===== ${name} =====`);
    console.log('  帧命令序列:', cmds.map((c) => '0x' + c.toString(16)).join(' '));
    console.log('  DATA 帧数  :', dataCount, '(期望', expectData + ')');
    if (!okHead) throw new Error('帧序列不符');
    // DATA 帧负载比对（跳过重发帧，按 IDX 去重后逐帧核对）
    const seenIdx = new Set();
    for (const f of fpga.frames) {
        if (f[3] !== CMD.DATA) continue;
        const len = f[2];
        const idx = f[4];
        if (seenIdx.has(idx)) { console.log(`  DATA[IDX=${idx}] 为重发帧（幂等覆写，FPGA 侧天然安全）`); continue; }
        seenIdx.add(idx);
        const n = (len - 1) / 2;
        for (let k = 0; k < n; k++) {
            const want = events[idx + k];
            const hi = (want >> 8) & 0xFF, lo = want & 0xFF;
            if (f[5 + k * 2] !== hi || f[6 + k * 2] !== lo)
                throw new Error(`事件 ${idx + k} 字节错`);
        }
        console.log(`  DATA[IDX=${idx}] ${n} 个事件字节校验 OK`);
    }
    console.log(`  下载完成：${nEvents} 事件，耗时 ${ms}ms，ACK 全部确认`);
}

(async () => {
    await runScenario('正常下载 40 事件', {}, 40);
    await runScenario('首帧 DATA 丢 ACK -> 重发', { dropFirstDataAck: true }, 40);
    attachPort(null);
    console.log('\n全部通过 ✓');
    process.exit(0);
})().catch((e) => { console.error('失败:', e); process.exit(1); });
