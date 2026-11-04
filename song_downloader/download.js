// download.js - ble_link 曲目下载协议（帧构建 + 应答解析 + 下载状态机）
// 协议定义见 FPGA ble_link.v：
//   帧:  AA 55 | LEN | CMD | PAYLOAD[LEN] | SUM ; SUM=(LEN+CMD+ΣPAYLOAD)&0xFF
//   ACK: AA 55 01 (CMD|0x80) 01 SUM           （收到帧校验通过后回）
//   STATUS: AA 55 04 92 STAT CNT OCC SLOT SUM
//        STAT bit0=指引运行中(play_en) bit1=当前槽已成功下载(dl_ok)
//        CNT=当前槽写指针；OCC bit0/1/2=下载槽 0/1/2 占用位；SLOT=当前槽号
// BEGIN 帧负载 = 下载槽号（0..2）；PLAY 帧负载 = 曲目号（1/2/3 = 下载槽 0/1/2）
// DATA 帧负载 = 起始事件序号(1 字节) + n×3 字节事件（高字节在前，n 即事件数）
// 事件为 24 位（最多 2 音混音）：{cnt1[1:0], n0[4:0], n1[4:0], dur[11:0]}
// 可靠性：DATA 帧自带起始序号 IDX 天然幂等；ACK 等待超时重发（最多 3 次）；
//         下载末尾强制 QUERY 回读，以 FPGA 实际写指针判定成功，杜绝 ACK 误导。
// 多曲目：FPGA 存 3 个下载槽，槽位由调用方分配（App 侧计数 % 3，第 4 首覆盖第 1 首）

const CMD = {
    BEGIN: 0x01,  // 开始下载：负载 = 下载槽号（0..2），写指针归 0
    DATA: 0x02,   // 数据：负载 = IDX + 事件字节
    END: 0x03,    // 结束：补 24'h000000 曲终标记，置当前槽 dl_ok
    PLAY: 0x10,   // 选曲并开始指引（负载 1 字节曲目号，1/2/3 = 下载槽 0/1/2）
    STOP: 0x11,
    QUERY: 0x12,
    ERASE: 0x13,
    REC_START: 0x20,  // 开始录制
    REC_STOP:  0x21,  // 停止录制
    REC_QUERY: 0x22,  // 查询录制状态（1 字节：bit7=busy，bit6..0=事件数）
    REC_READ:  0x23   // 读取录制数据（负载=起始序号，回传最多 8 个事件）
};

function buildFrame(cmd, payload = []) {
    const len = payload.length;
    const buf = Buffer.alloc(5 + len);   // AA 55 LEN CMD + PAYLOAD + SUM
    buf[0] = 0xAA;
    buf[1] = 0x55;
    buf[2] = len;
    buf[3] = cmd;
    let sum = (len + cmd) & 0xFF;
    for (let i = 0; i < len; i++) {
        buf[4 + i] = payload[i];
        sum = (sum + payload[i]) & 0xFF;
    }
    buf[4 + len] = sum;
    return buf;
}

// 从字节流中解析出全部完整合法帧（滑动窗口，返回 {cmd, payload:number[]} 数组）
function parseFrames(stream) {
    const frames = [];
    let i = 0;
    while (i + 3 < stream.length) {
        if (stream[i] !== 0xAA || stream[i + 1] !== 0x55) { i++; continue; }
        const len = stream[i + 2];
        if (i + 5 + len > stream.length) break;         // 帧未收全（含 SUM），等后续字节
        const cmd = stream[i + 3];
        let sum = (len + cmd) & 0xFF;
        for (let j = 0; j < len; j++) sum = (sum + stream[i + 4 + j]) & 0xFF;
        if (stream[i + 4 + len] === sum) {
            frames.push({ cmd, payload: stream.slice(i + 4, i + 4 + len) });
            i += 5 + len;
        } else {
            i++;                                        // 校验错：放弃当前 AA，重扫
        }
    }
    return frames;
}

const expectAckFor = (sendCmd) => sendCmd | 0x80;

// ---------------- 下载会话（单例状态机；port 注入以便测试模拟 FPGA） ----------------
let port = null;        // 串口对象 { isOpen, write(buf, cb) }
let ackWait = null;     // { ackCmd, resolve, reject, timer }
let rxStream = [];
let statusHook = null;  // QUERY 回读捕获器 { consume(byte)->bool }，命中后停喂 ACK

function attachPort(p) { port = p; rxStream = []; }
function abortDownload() {
    if (ackWait) ackWait.reject(new Error('下载中断'));
    rxStream = [];
}

function feedRx(byte) {
    rxStream.push(byte);
    if (rxStream.length > 512) rxStream = rxStream.slice(-256);
    // 优先喂给 QUERY 回读捕获器
    if (statusHook) {
        if (statusHook.consume(byte)) return;
    }
    if (!ackWait) return;
    const frames = parseFrames(rxStream);
    if (frames.length) {
        rxStream = [];
        for (const f of frames)
            if (ackWait && f.cmd === ackWait.ackCmd) ackWait.resolve();
    }
}

// 发送 QUERY 并回读 STATUS 帧，返回 { stat, playEn, dlOk, cnt, occ, slot }
// 实现：向串口写 QUERY 帧，然后从后续收到的最早一帧 STATUS(cmd=0x92, len=4) 解析。
function queryStatus(timeoutMs = 1500) {
    return new Promise((resolve, reject) => {
        if (!port || !port.isOpen) return reject(new Error('串口未连接'));
        if (statusHook) return reject(new Error('已有回读等待'));
        let acc = new Uint8Array(0);
        let resolved = false;
        const finish = (st, err) => {
            if (resolved) return;
            resolved = true;
            statusHook = null;
            clearTimeout(timer);
            if (err) reject(err); else resolve(st);
        };
        // 从原始字节累加，滑动窗口找 STATUS 帧
        const consume = (byte) => {
            const tmp = new Uint8Array(acc.length + 1);
            tmp.set(acc); tmp[acc.length] = byte;
            acc = tmp;
            let i = 0;
            while (i + 6 <= acc.length) {
                if (acc[i] !== 0xAA || acc[i + 1] !== 0x55) { i++; continue; }
                const len = acc[i + 2], cmd = acc[i + 3];
                if (i + 4 + len >= acc.length) break;      // SUM 字节(i+4+len)未到达，等待后续
                let sum = (len + cmd) & 0xFF;
                for (let j = 0; j < len; j++) sum = (sum + acc[i + 4 + j]) & 0xFF;
                if (acc[i + 4 + len] !== sum) { i++; continue; }
                // 完整合法帧
                if (cmd === 0x92 && len === 4) {
                    const stat = acc[i + 4], cnt = acc[i + 5], occ = acc[i + 6], slot = acc[i + 7];
                    finish({ stat, playEn: !!(stat & 1), dlOk: !!(stat & 2), cnt, occ, slot });
                    return true;
                }
                i += 5 + len;
            }
            return false;
        };
        statusHook = { consume };
        const timer = setTimeout(() => finish(null, new Error('QUERY 回读超时')), timeoutMs);
        port.write(Buffer.from(buildFrame(CMD.QUERY, [])), (err) => {
            if (err) finish(null, err);
        });
    });
}

// 发送一帧并等待对应 ACK（超时 600ms，最多重发 3 次）
function txFrameAndWait(cmd, payload, onResend) {
    return new Promise((resolve, reject) => {
        if (ackWait) return reject(new Error('已有未完成的应答等待'));
        const ackCmd = expectAckFor(cmd);
        const buf = buildFrame(cmd, payload);
        let tries = 0;
        const attempt = () => {
            tries++;
            if (!port || !port.isOpen) return reject(new Error('串口未连接'));
            // 应答等待须先于 write 建立：串口实现可能同步回调
            ackWait = {
                ackCmd,
                resolve: () => { clearTimeout(ackWait.timer); ackWait = null; resolve(); },
                reject: (e) => { clearTimeout(ackWait.timer); ackWait = null; reject(e); }
            };
            ackWait.timer = setTimeout(() => {
                if (tries < 3) { ackWait = null; attempt(); }
                else ackWait.reject(new Error(`ACK 超时（帧命令 0x${cmd.toString(16)} 重发 ${tries} 次无应答）`));
            }, 600);
            onResend && onResend(tries);
            port.write(buf, (err) => { if (err) ackWait.reject(err); });
        };
        attempt();
    });
}

// 完整下载流程：BEGIN(带槽号) -> DATA 分帧(≤16 事件/帧) -> END -> PLAY(4+槽号) -> 回读校验
// 每事件 3 字节（24 位），帧负载 = 1 + 3×16 = 49 字节，LEN 单字节可容纳
const MAX_EVENTS = 255;
async function downloadSong(encodedEvents, slot = 0, onProgress) {
    const n = encodedEvents.length;
    if (n < 1 || n > MAX_EVENTS) throw new Error(`事件数 ${n} 超出 1..${MAX_EVENTS} 范围`);
    if (slot < 0 || slot > 2) throw new Error(`下载槽号 ${slot} 超出 0..2 范围`);
    onProgress && onProgress({ stage: 'begin', text: `BEGIN 开始下载（槽 ${slot}）` });
    await txFrameAndWait(CMD.BEGIN, [slot]);
    const CHUNK = 16;
    for (let i = 0; i < n; i += CHUNK) {
        const chunk = encodedEvents.slice(i, i + CHUNK);
        const payload = [i];
        for (const ev of chunk)
            payload.push((ev >> 16) & 0xFF, (ev >> 8) & 0xFF, ev & 0xFF);
        onProgress && onProgress({ stage: 'data', done: i, total: n, text: `DATA 帧 ${i / CHUNK + 1}` });
        await txFrameAndWait(CMD.DATA, payload);
    }
    onProgress && onProgress({ stage: 'end', text: 'END 结束下载' });
    await txFrameAndWait(CMD.END, []);
    onProgress && onProgress({ stage: 'play', text: `PLAY 曲目 ${1 + slot}（下载槽 ${slot}）` });
    await txFrameAndWait(CMD.PLAY, [1 + slot]);
    // ---- 回读校验：以 FPGA 写指针为准，杜绝 ACK 误导 ----
    await new Promise(r => setTimeout(r, 120));           // 等 FPGA 发送链稳定
    const st = await queryStatus();
    if (st.cnt !== n) {
        throw new Error(
            `下载后回读不一致：FPGA 写指针 CNT=${st.cnt}，应=${n}，` +
            `play_en=${st.playEn ? 1 : 0} dl_ok=${st.dlOk ? 1 : 0}` +
            (st.cnt === 0 && st.dlOk ? '（疑似 DATA 未真正写入 RAM）' : '')
        );
    }
    onProgress && onProgress({ stage: 'verify', done: n, total: n, text: `回读校验通过：槽 ${slot} 已存 ${st.cnt} 事件` });
    onProgress && onProgress({ stage: 'done', done: n, total: n, text: `下载完成（槽 ${slot}），已开始播放` });
    return { success: true, eventCount: n, verifiedCnt: st.cnt, slot, occ: st.occ };
}

// ---------------- 录制相关函数 ----------------

// 开始录制
function startRecording() {
    return txFrameAndWait(CMD.REC_START, []);
}

// 停止录制
function stopRecording() {
    return txFrameAndWait(CMD.REC_STOP, []);
}

// 查询录制状态：返回 { busy, count, mode }
//   REC_QUERY 应答：cmd=0xA2，len=1(旧固件) 或 len=2(新固件，追加 MODE 字节)
//     payload[0]: bit7=busy, bit6..0=事件数；payload[1]: bit0=音色模式(0拨弦/1拉弦)
function queryRecording(timeoutMs = 1500) {
    return new Promise((resolve, reject) => {
        if (!port || !port.isOpen) return reject(new Error('串口未连接'));
        if (statusHook) return reject(new Error('已有回读等待'));
        let acc = new Uint8Array(0);
        let resolved = false;
        const finish = (st, err) => {
            if (resolved) return;
            resolved = true;
            statusHook = null;
            clearTimeout(timer);
            if (err) reject(err); else resolve(st);
        };
        const consume = (byte) => {
            const tmp = new Uint8Array(acc.length + 1);
            tmp.set(acc); tmp[acc.length] = byte;
            acc = tmp;
            let i = 0;
            while (i + 6 <= acc.length) {
                if (acc[i] !== 0xAA || acc[i + 1] !== 0x55) { i++; continue; }
                const len = acc[i + 2], cmd = acc[i + 3];
                if (i + 4 + len >= acc.length) break;
                let sum = (len + cmd) & 0xFF;
                for (let j = 0; j < len; j++) sum = (sum + acc[i + 4 + j]) & 0xFF;
                if (acc[i + 4 + len] !== sum) { i++; continue; }
                if (cmd === 0xA2 && (len === 1 || len === 2)) {
                    const cntByte = acc[i + 4];
                    const mode = (len === 2) ? (acc[i + 5] & 0x01) : 0;
                    finish({ busy: !!(cntByte & 0x80), count: cntByte & 0x7F, mode });
                    return true;
                }
                i += 5 + len;
            }
            return false;
        };
        statusHook = { consume };
        const timer = setTimeout(() => finish(null, new Error('REC_QUERY 回读超时')), timeoutMs);
        port.write(Buffer.from(buildFrame(CMD.REC_QUERY, [])), (err) => {
            if (err) finish(null, err);
        });
    });
}

// 读取录制数据（从 idx 开始，最多 8 个事件/帧，循环读取直到曲终或读完）
//   REC_READ 应答：cmd=0xA3, payload = [IDX, ev0_b2, ev0_b1, ev0_b0, ... evn_b2, evn_b1, evn_b0]
//   返回 { events, mode }：events = 24 位事件数组（与下载曲目格式一致），
//   mode = 录制时的音色模式（0=拨弦/竖琴, 1=拉弦/小提琴，来自 REC_QUERY 回传，旧固件缺省 0）
async function readRecording() {
    // 先查录制时锁存的音色模式（避免录制后切换 F10 导致误判）
    let mode = 0;
    try {
        const q = await queryRecording(800);
        if (q && typeof q.mode === 'number') mode = q.mode ? 1 : 0;
    } catch (_) { /* 旧固件无 MODE 字段：默认拨弦 */ }
    const events = [];
    let idx = 0;
    while (true) {
        const chunk = await readRecordingChunk(idx);
        if (chunk.events.length === 0) break;   // FPGA 回空帧 = 读到显式曲终标记
        for (const ev of chunk.events) events.push(ev);
        idx += chunk.events.length;
    }
    return { events, mode };
}

// 读一帧录制数据（最多 8 个事件），返回 { events: [], hasMore: bool }
function readRecordingChunk(startIdx, timeoutMs = 1500) {
    return new Promise((resolve, reject) => {
        if (!port || !port.isOpen) return reject(new Error('串口未连接'));
        if (statusHook) return reject(new Error('已有回读等待'));
        let acc = new Uint8Array(0);
        let resolved = false;
        const finish = (result, err) => {
            if (resolved) return;
            resolved = true;
            statusHook = null;
            clearTimeout(timer);
            if (err) reject(err); else resolve(result);
        };
        const consume = (byte) => {
            const tmp = new Uint8Array(acc.length + 1);
            tmp.set(acc); tmp[acc.length] = byte;
            acc = tmp;
            let i = 0;
            while (i + 6 <= acc.length) {
                if (acc[i] !== 0xAA || acc[i + 1] !== 0x55) { i++; continue; }
                const len = acc[i + 2], cmd = acc[i + 3];
                if (i + 4 + len >= acc.length) break;
                let sum = (len + cmd) & 0xFF;
                for (let j = 0; j < len; j++) sum = (sum + acc[i + 4 + j]) & 0xFF;
                if (acc[i + 4 + len] !== sum) { i++; continue; }
                if (cmd === 0xA3 && len >= 1) {
                    const payload = acc.slice(i + 4, i + 4 + len);
                    const nEvents = Math.floor((len - 1) / 3);
                    const events = [];
                    for (let k = 0; k < nEvents; k++) {
                        const b2 = payload[1 + k * 3];
                        const b1 = payload[2 + k * 3];
                        const b0 = payload[3 + k * 3];
                        events.push((b2 << 16) | (b1 << 8) | b0);
                    }
                    // 曲终由 FPGA 显式回空帧（nEvents=0）表示，不再用 dur==0 误判
                    const hasMore = nEvents > 0;
                    finish({ events, hasMore, startIdx: payload[0] });
                    return true;
                }
                i += 5 + len;
            }
            return false;
        };
        statusHook = { consume };
        const timer = setTimeout(() => finish(null, new Error('REC_READ 回读超时')), timeoutMs);
        port.write(Buffer.from(buildFrame(CMD.REC_READ, [startIdx & 0xFF])), (err) => {
            if (err) finish(null, err);
        });
    });
}

module.exports = { CMD, buildFrame, parseFrames, expectAckFor, attachPort, abortDownload, feedRx, downloadSong, queryStatus,
    startRecording, stopRecording, queryRecording, readRecording, readRecordingChunk };