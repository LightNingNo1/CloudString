// renderer.js - 曲目下载器界面逻辑
// 注意：contextBridge 已把 API 暴露为全局变量 api（window.api），无需也不能再 const 声明
const $ = (id) => document.getElementById(id);

let selectedFile = null;       // 用户选择的 MP3 路径
let currentSong = null;        // 当前可下载曲目 { events, encoded, meta, source }
let recordedSong = null;       // 录制读取到的曲目 { events, encoded, meta }
let rxLogAcc = 0;              // RX 字节日志节流计数
let player = null;             // HarpPlayer 实例（懒创建，用户首次点播放才创建）
// FPGA 存 3 个下载槽（曲目号 1/2/3 = 槽 0/1/2，另有 1 首预制曲目号 0），超过 3 首从槽 0 循环覆盖
const NUM_SLOTS = 3;
let dlCount = 0;               // 累计下载次数（决定下一次写入哪个槽）
let slotInfo = [null, null, null];   // 每次下载后回读的占用状态 { cnt, occ }（按槽号）
let slotSongs = ['', '', ''];        // 各槽最近写入的歌曲名/来源摘要
let queryTimer = null;         // 定时刷新槽位占用状态
const SLOT_NAMES = ['曲目 1', '曲目 2', '曲目 3'];   // 曲目号 1/2/3 -> 槽 0/1/2

// ---------------- 工具 ----------------
function log(msg, cls = '') {
    const area = $('logArea');
    const div = document.createElement('div');
    if (cls) div.className = cls;
    div.textContent = msg;
    area.appendChild(div);
    area.scrollTop = area.scrollHeight;
    while (area.childElementCount > 500) area.removeChild(area.firstChild);
}

function setConn(connected) {
    $('connDot').classList.toggle('on', connected);
    $('connText').textContent = connected ? '已连接' : '未连接';
    $('connectBtn').disabled = connected;
    $('disconnectBtn').disabled = !connected;
    $('refreshBtn').disabled = connected;
    $('portSelect').disabled = connected;
    $('recStartBtn').disabled = !connected;
    $('recStopBtn').disabled = true;
    $('recReadBtn').disabled = !connected;
}

const STAGE_TEXT = {
    decode: '解码 MP3 / 转 22050Hz…',
    transcribe: 'AI 识谱（约等于歌曲时长，请耐心）…',
    post: '整理谱面…'
};

// ---------------- 串口 ----------------
async function refreshPorts() {
    const ports = await api.getPorts();
    const sel = $('portSelect');
    sel.innerHTML = '<option value="">选择端口</option>';
    for (const p of ports) {
        const o = document.createElement('option');
        o.value = p.path;
        o.textContent = (p.isBluetooth ? '蓝牙 ' : '') + p.path + ' — ' + p.name;
        sel.appendChild(o);
    }
    if (ports.length === 0) log('未发现串口。若已配对 XLBT 仍无 COM 口，请检查 Windows 蓝牙设置。', 'err');
    else log(`发现 ${ports.length} 个串口`);
}

$('refreshBtn').onclick = () => refreshPorts().catch((e) => log('枚举串口失败: ' + e.message, 'err'));
$('connectBtn').onclick = async () => {
    const p = $('portSelect').value;
    if (!p) return log('请先选择端口', 'err');
    log('连接 ' + p + ' (115200 8N1)…');
    const r = await api.connect(p);
    if (r.success) {
        setConn(true);
        log('已连接 ' + p, 'ok');
        renderSlotBar();
        refreshSlotStatus();
    }
    else log('连接失败: ' + r.error, 'err');
};
$('disconnectBtn').onclick = async () => {
    await api.disconnect();
    setConn(false);
    log('已断开');
};

// ---------------- 手动乐谱（主功能） ----------------
async function loadScoreExample() {
    const text = await api.scoreExample();
    $('scoreInput').value = text;
    log('已载入示例乐谱（小星星）');
}

async function parseScore() {
    const text = $('scoreInput').value;
    if (!text.trim()) return log('请先输入乐谱', 'err');
    const btn = $('parseScoreBtn');
    btn.disabled = true;
    try {
        const res = await api.parseScore(text);
        if (res && res.error) {
            log('解析失败: ' + res.error, 'err');
            $('scoreInfo').innerHTML = `<span class="err">解析失败</span>`;
            $('scorePreview').textContent = '';
            currentSong = null;
            $('downloadBtn').disabled = true;
            $('scorePlayBtn').disabled = true;
            return;
        }
        currentSong = {
            events: res.events,
            encoded: res.encoded,
            meta: { source: 'score', eventCount: res.events.length, lineCount: res.lineCount },
            source: 'score'
        };
        $('scoreInfo').innerHTML = `已解析 <b>${res.events.length}</b> 个事件（${res.lineCount} 行）${res.warnings.length ? '，' + res.warnings.length + ' 处提示' : ''}`;
        $('scorePreview').textContent = '';
        renderScorePreview(res.events);
        $('downloadBtn').disabled = false;
        $('scorePlayBtn').disabled = false;
        log(`乐谱解析成功：${res.events.length} 个事件，可下载到 FPGA`, 'ok');
        if (res.warnings.length) {
            for (const w of res.warnings.slice(0, 5)) log('提示: ' + w, '');
            if (res.warnings.length > 5) log(`…共 ${res.warnings.length} 处提示（音名就近量化）`, '');
        }
    } catch (e) {
        log('解析失败: ' + e.message, 'err');
    } finally {
        btn.disabled = false;
    }
}

function renderScorePreview(events) {
    const lines = [`手动乐谱 ${events.length} 个事件（首事件为起始灯塔，之后按时值自动推进）`, ''];
    events.forEach((e, i) => {
        const keys = e.cnt1 ? `弦${e.strName}（${e.noteName}）` : `弦${e.s0}（${e.noteName}）`;
        lines.push(` #${String(i).padStart(2, '0')}  ${keys.padEnd(22)}  ${e.durMs}ms`);
    });
    $('scorePreview').textContent = lines.join('\n');
}

$('scoreExampleBtn').onclick = () => loadScoreExample().catch((e) => log('载入示例失败: ' + e.message, 'err'));
$('parseScoreBtn').onclick = () => parseScore().catch((e) => log('解析失败: ' + e.message, 'err'));

// ---------------- 选歌 / AI 转谱（次功能） ----------------
$('pickBtn').onclick = async () => {
    const p = await api.pickMp3();
    if (!p) return;
    selectedFile = p;
    $('transcribeBtn').disabled = false;
    $('notePreview').textContent = '';
    $('songInfo').textContent = '';
    const name = p.split(/[\\/]/).pop();
    $('songInfo').innerHTML = `已选择：<b>${name}</b>（点击「AI 转谱」开始）`;
    log('选择歌曲: ' + name);
};

$('transcribeBtn').onclick = async () => {
    if (!selectedFile) return;
    const btn = $('transcribeBtn');
    btn.disabled = true;
    $('transcribeBar').classList.remove('hidden');
    $('transcribeFill').style.width = '0%';
    $('transcribeLabel').textContent = '解码中…';
    log('开始 AI 转谱…');
    try {
        const res = await api.transcribe(selectedFile);
        if (res && res.error) throw new Error(res.error);
        currentSong = {
            events: res.events,
            encoded: res.encoded,
            meta: { ...res.meta, source: 'ai' },
            source: 'ai'
        };
        $('transcribeFill').style.width = '100%';
        $('transcribeLabel').textContent = '转谱完成';
        renderPreview(res);
        $('downloadBtn').disabled = false;
        $('aiPlayBtn').disabled = false;
        log(`转谱完成：识别 ${res.meta.rawNoteCount} 个音符，整理为 ${res.events.length} 个引导事件`, 'ok');
        if (res.meta.compressedDropped > 0)
            log(`歌曲较长，已自动压缩 ${res.meta.compressedDropped} 个装饰音到 255 事件以内`, 'err');
    } catch (e) {
        $('transcribeLabel').textContent = '转谱失败';
        log('转谱失败: ' + e.message, 'err');
    } finally {
        btn.disabled = false;
    }
};

api.onTranscribeProgress(({ stage, pct }) => {
    const txt = STAGE_TEXT[stage] || stage;
    $('transcribeLabel').textContent = `${txt} ${Math.round(pct * 100)}%`;
    $('transcribeFill').style.width = `${Math.round(pct * 100)}%`;
});

function renderPreview(res) {
    const { events, meta } = res;
    const lines = [`识别音符 ${meta.rawNoteCount} 个 → 引导事件 ${events.length} 个（歌曲 ${meta.sourceSec.toFixed(1)}s，转谱耗时 ${(meta.modelMs / 1000).toFixed(1)}s）`, ''];
    events.forEach((e, i) => {
        lines.push(` #${String(i).padStart(2, '0')}  ${e.noteName.padEnd(3)} 弦${String(e.s).padStart(2, '0')}（层${e.layer} 内${e.inner}）  ${e.durMs}ms`);
    });
    $('notePreview').textContent = lines.join('\n');
}

// ---------------- 下载槽位状态 ----------------
function renderSlotBar() {
    const bar = $('slotBar');
    if (!bar) return;
    bar.innerHTML = '';
    for (let s = 0; s < NUM_SLOTS; s++) {
        const info = slotInfo[s];
        const div = document.createElement('div');
        div.className = 'slot-cell' + (info ? ' used' : ' empty');
        div.id = 'slotCell' + s;
        const title = document.createElement('div');
        title.className = 'slot-title';
        title.textContent = '槽 ' + (s + 1);
        const sub = document.createElement('div');
        sub.className = 'slot-sub';
        if (info) {
            sub.textContent = slotSongs[s]
                ? SLOT_NAMES[s] + ' · ' + slotSongs[s] + ' · ' + info.cnt + ' 事件'
                : SLOT_NAMES[s] + ' · 已存 ' + info.cnt + ' 事件';
            div.title = '该槽已成功下载，F10 长按切曲可播放';
        } else {
            sub.textContent = '空（可写入）';
        }
        div.appendChild(title);
        div.appendChild(sub);
        bar.appendChild(div);
    }
}

async function refreshSlotStatus() {
    try {
        const st = await api.queryStatus();
        if (st && st.occ !== undefined) {
            for (let s = 0; s < NUM_SLOTS; s++) {
                const occBit = (st.occ >> s) & 1;
                if (occBit) {
                    if (!slotInfo[s]) slotInfo[s] = { cnt: 0 };
                    // 当前回读槽的 CNT 归到对应槽
                    if (st.slot === s) slotInfo[s].cnt = st.cnt;
                } else {
                    slotInfo[s] = null;
                    slotSongs[s] = '';
                }
            }
            renderSlotBar();
        }
    } catch (e) {
        // 回读失败不阻塞界面（例如连接刚断开）
    }
}

// ---------------- 下载 ----------------
$('downloadBtn').onclick = async () => {
    if (!currentSong) return;
    if (!(await api.isConnected())) return log('请先连接蓝牙串口', 'err');
    const btn = $('downloadBtn');
    btn.disabled = true;
    $('dlFill').style.width = '0%';
    $('dlProgress').textContent = '';
    const slot = dlCount % NUM_SLOTS;   // 0..2 循环：超过 3 首自动覆盖槽 0
    dlCount++;
    log(`开始下载曲目到 FPGA…（${currentSong.events.length} 个事件，来源：${currentSong.source === 'score' ? '手动乐谱' : 'AI 转谱'}）→ 槽 ${slot + 1}（第 ${dlCount} 首，曲目号 ${SLOT_NAMES[slot]}）`);
    try {
        const r = await api.download(currentSong.encoded, slot);
        if (r && r.error) throw new Error(r.error);
        $('dlFill').style.width = '100%';
        $('dlProgress').textContent = `完成：${r.eventCount} 个事件已下发到槽 ${slot + 1}，FPGA 开始播放`;
        slotInfo[slot] = { cnt: r.verifiedCnt };
        slotSongs[slot] = currentSong.source === 'score' ? '手动谱' : (currentSong.meta && currentSong.meta.fileName) || 'AI 谱';
        renderSlotBar();
        log(`下载完成！${r.eventCount} 个事件已写入槽 ${slot + 1}（曲目号 ${SLOT_NAMES[slot]}），已自动切换到下载曲目播放`, 'ok');
    } catch (e) {
        $('dlProgress').textContent = '下载失败';
        log('下载失败: ' + e.message, 'err');
    } finally {
        btn.disabled = false;
    }
};

api.onDownloadProgress((p) => {
    if (p.stage === 'data') {
        $('dlFill').style.width = `${Math.round((p.done / p.total) * 100)}%`;
        $('dlProgress').textContent = `DATA ${p.done}/${p.total}`;
    } else if (p.text) {
        log(p.text);
    }
});

// ---------------- 串口原始字节日志（调试用，节流） ----------------
api.onSerialData((bytes) => {
    rxLogAcc += bytes.length;
    if (rxLogAcc > 24) return;   // 下载时 ACK 洪泛不刷屏，仅显示前若干字节
    const hex = bytes.map((b) => b.toString(16).padStart(2, '0')).join(' ');
    log('RX ' + hex, 'rx');
});
api.onDisconnected(() => {
    setConn(false);
    log('串口断开', 'err');
});

// ---------------- 电脑端播放（Web Audio）----------------
function fmtTime(sec) {
    sec = Math.max(0, Math.floor(sec));
    const m = Math.floor(sec / 60), s = sec % 60;
    return `${m}:${String(s).padStart(2, '0')}`;
}

function ensurePlayer() {
    if (!player) {
        player = new HarpPlayer();
        player.onProgress = (cur, total) => {
            $('playerFill').style.width = total > 0 ? (cur / total * 100) + '%' : '0%';
            $('playerTime').textContent = `${fmtTime(cur)} / ${fmtTime(total)}`;
        };
        player.onEnded = () => {
            $('playerPlayBtn').textContent = '▶ 播放';
            $('playerStopBtn').disabled = true;
        };
    }
    return player;
}

// 载入并播放指定 encoded 事件数组（mode: 'pluck' 拨弦/竖琴 | 'bow' 拉弦/小提琴）
// rawGap=true 表示 dur 是"距上一事件"（录制数据原生语义），由播放器换算时间轴
function playEncoded(encoded, title, mode = 'pluck', rawGap = false) {
    const p = ensurePlayer();
    p.setMode(mode);
    const info = p.loadEvents(encoded, rawGap);
    $('playerTitle').textContent = title || '未命名';
    $('playerPlayBtn').textContent = '⏸ 暂停';
    $('playerPlayBtn').disabled = false;
    $('playerStopBtn').disabled = false;
    $('playerFill').style.width = '0%';
    $('playerTime').textContent = `0:00 / ${fmtTime(info.totalSec)}`;
    p.play();
}

$('playerPlayBtn').onclick = () => {
    if (!player) return;
    if (player.isPlaying && !player.isPaused) {
        player.pause();
        $('playerPlayBtn').textContent = '▶ 继续';
    } else {
        player.play();
        $('playerPlayBtn').textContent = '⏸ 暂停';
    }
};

$('playerStopBtn').onclick = () => {
    if (!player) return;
    player.stop();
    $('playerPlayBtn').textContent = '▶ 播放';
    $('playerStopBtn').disabled = true;
    $('playerFill').style.width = '0%';
};

// 录制播放
$('recPlayBtn').onclick = () => {
    if (!recordedSong || !recordedSong.encoded) return;
    const mode = recordedSong.mode ? 'bow' : 'pluck';
    playEncoded(recordedSong.encoded, '录制回放', mode, !!recordedSong.rawGap);
    log('开始播放录制内容（' + (recordedSong.mode ? '拉弦/小提琴' : '拨弦/竖琴') + '音色）');
};

// 乐谱播放
$('scorePlayBtn').onclick = () => {
    if (!currentSong || !currentSong.encoded) return;
    playEncoded(currentSong.encoded, currentSong.meta?.name || '乐谱播放');
    log('开始播放乐谱（电脑端合成音色）');
};

// AI 转谱播放
$('aiPlayBtn').onclick = () => {
    if (!currentSong || !currentSong.encoded) return;
    playEncoded(currentSong.encoded, currentSong.meta?.name || 'AI 转谱');
    log('开始播放 AI 转谱（电脑端合成音色）');
};

// ---------------- 录制 ----------------
let recPollTimer = null;

$('recStartBtn').onclick = async () => {
    try {
        const r = await api.startRecording();
        if (r && r.error) throw new Error(r.error);
        $('recStatus').textContent = '录制中…';
        $('recStatus').classList.add('rec-on');
        $('recStartBtn').disabled = true;
        $('recStopBtn').disabled = false;
        $('recReadBtn').disabled = true;
        log('开始录制：FPGA 正在记录按键事件', 'ok');
        // 定时查询录制状态，显示事件数
        recPollTimer = setInterval(async () => {
            try {
                const st = await api.queryRecording();
                if (st && !st.error) {
                    $('recStatus').textContent = st.busy ? `录制中… ${st.count} 事件` : `已录制 ${st.count} 事件`;
                }
            } catch (_) {}
        }, 1000);
    } catch (e) {
        log('开始录制失败: ' + e.message, 'err');
    }
};

$('recStopBtn').onclick = async () => {
    try {
        if (recPollTimer) { clearInterval(recPollTimer); recPollTimer = null; }
        const r = await api.stopRecording();
        if (r && r.error) throw new Error(r.error);
        $('recStatus').textContent = '已停止';
        $('recStatus').classList.remove('rec-on');
        $('recStartBtn').disabled = false;
        $('recStopBtn').disabled = true;
        $('recReadBtn').disabled = false;
        log('停止录制：FPGA 已结束录制', 'ok');
    } catch (e) {
        log('停止录制失败: ' + e.message, 'err');
    }
};

$('recReadBtn').onclick = async () => {
    const btn = $('recReadBtn');
    btn.disabled = true;
    log('读取录制数据…');
    try {
        const r = await api.readRecording();
        if (r && r.error) throw new Error(r.error);
        if (!r.events || r.events.length === 0) {
            log('录制数据为空', 'err');
            $('recInfo').textContent = '无录制数据';
            $('recPreview').textContent = '';
            recordedSong = null;
            $('recToScoreBtn').disabled = true;
            $('recPlayBtn').disabled = true;
            return;
        }
        // 保留原始 24 位事件（含拉弦释放事件，cnt1=2）。
        //   按下事件 dur = 距上一按下事件的间隔；释放事件 dur = 该弦实际按住时长。
        //   播放器按 rawGap 语义统一换算时间轴，并按键号把释放时长配到对应按下事件。
        const rawEvents = r.events;
        // 预览与「载入为乐谱」只取按下事件（cnt1 < 2），释放事件不构成谱面
        const pressEvents = rawEvents.filter((ev) => ((ev >> 22) & 0x3) < 2);
        const events = pressEvents.map((ev, i) => {
            const cnt1 = (ev >> 22) & 0x3;
            const n0 = (ev >> 17) & 0x1F;
            const n1 = (ev >> 12) & 0x1F;
            // 预览时值 = 到下一个按下事件的间隔（与播放时间轴一致）
            const dur = (i + 1 < pressEvents.length) ? (pressEvents[i + 1] & 0x0FFF) : 0;
            const durMs = dur * 10;
            const nNotes = cnt1 + 1;
            const strs = nNotes >= 2 ? `${n0},${n1}` : `${n0}`;
            return { s0: n0, s1: n1, cnt1, durMs, strs };
        });
        recordedSong = {
            events,
            encoded: rawEvents,
            rawGap: true,
            mode: r.mode ? 1 : 0,
            meta: { source: 'recorded', eventCount: events.length }
        };
        const modeName = (r.mode ? 1 : 0) ? '拉弦（小提琴）' : '拨弦（竖琴）';
        $('recInfo').innerHTML = `已读取 <b>${events.length}</b> 个录制事件 · 音色：<b>${modeName}</b>`;
        // 预览
        const lines = [`录制 ${events.length} 个事件`, ''];
        events.forEach((e, i) => {
            lines.push(` #${String(i).padStart(2, '0')}  弦${e.strs.padEnd(8)}  ${e.durMs}ms`);
        });
        $('recPreview').textContent = lines.join('\n');
        $('recToScoreBtn').disabled = false;
        $('recPlayBtn').disabled = false;
        log(`读取录制完成：${events.length} 个事件（音色：${(r.mode ? 1 : 0) ? '拉弦' : '拨弦'}）`, 'ok');
    } catch (e) {
        log('读取录制失败: ' + e.message, 'err');
    } finally {
        btn.disabled = false;
    }
};

// 载入为乐谱：把录制内容转成文本格式，填到手动乐谱输入框
$('recToScoreBtn').onclick = async () => {
    if (!recordedSong) return;
    const lines = ['# 录制回放（可编辑）', '# 格式：弦号[,弦号] 时值毫秒', ''];
    for (const e of recordedSong.events) {
        const strs = e.cnt1 ? `${e.s0},${e.s1}` : `${e.s0}`;
        lines.push(`${strs} ${e.durMs}`);
    }
    $('scoreInput').value = lines.join('\n');
    log('已载入为乐谱（可编辑后再解析）', 'ok');
    // 自动滚动到乐谱区
    $('scoreInput').scrollIntoView({ behavior: 'smooth', block: 'center' });
};

// ---------------- 启动 ----------------
renderSlotBar();
refreshPorts();
// 显示 APP 版本号（来自 package.json，用于识别每次 APP 修改）
api.getVersion()
    .then((v) => { $('appVersion').textContent = 'v' + v; })
    .catch(() => { $('appVersion').textContent = ''; });
log('就绪。请配对蓝牙模块（XLBT），然后选择端口连接。');
log('主功能：在「手动乐谱输入」中按格式输入谱子 → 解析并编码 → 下载播放。');
