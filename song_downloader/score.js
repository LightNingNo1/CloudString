// score.js - 手动乐谱解析与编码（新主功能，取代 AI 转谱成为主入口）
// 文本谱格式（每行一个事件）：
//   <弦号[,弦号]> <时值毫秒>
//     - 弦号 0..31（与 FPGA 32 弦定弦编号一致，v0=C3 ... v31=F7 连续白键）
//     - 也可用音名（C3..F7 白键，支持 #/b，如 A#3）自动就近量化到最近白键弦号
//     - 最多 2 个弦号（逗号分隔）= 2 音混音
//     - 时值毫秒 10..40950：本事件在乐曲中的时长窗口（LED 窗口开头闪 200ms 提示，
//       到时自动跳下一事件；首事件为起始灯塔：常亮等你按下才开始计时）
//   - '#' 开头为注释行；空行忽略
// 例：
//   7 500        # C4，500ms
//   7,11 960     # C4+E4 双音，960ms
//   0 320
// 事件编码（24 位，与 FPGA song_ram.v / ble_link.v 一致）：
//   {cnt1[1:0], n0[4:0], n1[4:0], dur[11:0]}
//   单音：cnt1=0、n1=0；双音：cnt1=1、n1=第二弦号。
const MAX_EVENTS = 255;   // song_ram 深度：255 音符 + 1 曲终标记

// ---- 32 弦定弦：v0..31 = C3~F7 连续白键（十二平均律，与 FPGA pitch_32v.v 一致） ----
const WHITE_SEMIS = [0, 2, 4, 5, 7, 9, 11];   // 白键相对本八度 C 的半音数
const STRING_MIDI = [];
for (let s = 0; s < 32; s++)
    STRING_MIDI.push(48 + 12 * Math.floor(s / 7) + WHITE_SEMIS[s % 7]);

const NOTE_SEMI = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
const NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
function midiName(m) { return NOTE_NAMES[m % 12] + (Math.floor(m / 12) - 1); }

// MIDI 音高 -> 弦号：量化到最近白键（平分取低音弦），越界吸附边界弦
function midiToString(midi) {
    if (midi <= 48) return 0;
    if (midi >= 102) return 31;
    let best = 0, bestDist = Infinity;
    for (let s = 0; s < 32; s++) {
        const d = Math.abs(midi - STRING_MIDI[s]);
        if (d < bestDist) { bestDist = d; best = s; }
    }
    return best;
}

// 音名 -> MIDI（C3=48，支持 #/b）
function noteNameToMidi(name) {
    const m = /^([A-G])([#b]?)(-?\d+)$/.exec(name.trim());
    if (!m) return null;
    let semi = NOTE_SEMI[m[1]];
    if (m[2] === '#') semi += 1;
    else if (m[2] === 'b') semi -= 1;
    return (parseInt(m[3], 10) + 1) * 12 + semi;
}

// 解析单个"音符"记号：整数 = 弦号，音名 = 量化弦号
// 返回 { ok, s, name, isNum, msg }
function parseNote(tok) {
    const t = tok.trim();
    if (!t) return { ok: false, msg: '空记号' };
    if (/^\d+$/.test(t)) {
        const s = parseInt(t, 10);
        if (s < 0 || s > 31) return { ok: false, msg: `弦号 ${s} 超出 0..31` };
        return { ok: true, s, name: midiName(STRING_MIDI[s]), isNum: true };
    }
    const midi = noteNameToMidi(t);
    if (midi === null) return { ok: false, msg: `无法识别"${t}"（应为弦号 0..31 或音名如 C4）` };
    if (midi < 48 || midi > 101) return { ok: false, msg: `音名 ${t} 超出 C3..F7 可弹范围` };
    const s = midiToString(midi);
    const shifted = STRING_MIDI[s] !== midi;
    return { ok: true, s, name: midiName(STRING_MIDI[s]), isNum: false, shifted, inMidi: midi };
}

// ---- 解析整份乐谱：返回 { events, warnings, errors, lineCount } ----
// events: [{ s0, s1, cnt1, durMs, noteName }]
function parseScore(text) {
    const events = [];
    const warnings = [];
    const errors = [];
    const lines = String(text).split(/\r?\n/);
    let lineCount = 0;
    for (let i = 0; i < lines.length; i++) {
        const raw = lines[i];
        const line = raw.replace(/#.*$/, '').trim();   // 去掉注释与首尾空白
        if (!line) continue;
        lineCount++;
        const toks = line.split(/\s+/);
        const notesTok = toks[0];
        const durTok = toks.length >= 2 ? toks[toks.length - 1] : null;
        const notes = notesTok.split(',').map(x => x.trim()).filter(Boolean);
        if (notes.length === 0) { errors.push(`第 ${i + 1} 行：缺少音符`); continue; }
        if (notes.length > 2) { errors.push(`第 ${i + 1} 行：最多 2 音混音（收到 ${notes.length} 个）`); continue; }
        if (!durTok || !/^\d+$/.test(durTok)) { errors.push(`第 ${i + 1} 行：缺少时值（毫秒整数）`); continue; }
        const durMs = parseInt(durTok, 10);
        if (durMs < 10 || durMs > 40950) { errors.push(`第 ${i + 1} 行：时值 ${durMs}ms 超出 10..40950`); continue; }
        const parsed = notes.map(n => parseNote(n));
        const bad = parsed.find(p => !p.ok);
        if (bad) { errors.push(`第 ${i + 1} 行：${bad.msg}`); continue; }
        for (const p of parsed) {
            if (p.shifted) warnings.push(`第 ${i + 1} 行：${p.inMidi === undefined ? '' : midiName(p.inMidi) + ' '}量化到 ${p.name}`);
        }
        events.push({
            s0: parsed[0].s,
            s1: parsed.length > 1 ? parsed[1].s : null,
            cnt1: parsed.length > 1 ? 1 : 0,
            durMs,
            noteName: parsed.map(p => p.name).join('+'),
            strName: parsed.map(p => String(p.s)).join('+')
        });
    }
    if (errors.length === 0 && events.length === 0)
        errors.push('乐谱为空：请至少输入一个事件');
    if (errors.length === 0 && events.length > MAX_EVENTS)
        errors.push(`事件数 ${events.length} 超过上限 ${MAX_EVENTS}（FPGA 下载容量），请删减或合并短音`);
    return { events, warnings, errors, lineCount };
}

// ---- 24 位事件编码：{cnt1, n0, n1, dur[11:0]} ----
function encodeEvent(s0, s1, durMs) {
    const dur = Math.min(4095, Math.max(1, Math.round(durMs / 10)));
    const cnt1 = s1 === null || s1 === undefined ? 0 : 1;
    const n1 = cnt1 ? s1 : 0;
    return (cnt1 << 22) | (s0 << 17) | (n1 << 12) | dur;
}
function encodeScoreEvents(events) {
    return events.map(e => encodeEvent(e.s0, e.s1, e.durMs));
}

// 示例乐谱：《小星星》第一段（示范手动乐谱格式与节奏音游行为）
const EXAMPLE_SCORE = `# 《小星星》第一段（手动乐谱示范）
# 格式：<弦号[,弦号]> <时值毫秒>；# 开头为注释
# 弦号速查：C4=7  D4=8  E4=9  F4=10  G4=11  A4=12  B4=13  C5=14
7 500
7 500
11 500
11 500
12 500
12 500
11 1000
10 500
10 500
9 500
9 500
8 500
8 500
7 1000
7,11 960
9,12 960
`;

module.exports = { MAX_EVENTS, STRING_MIDI, midiToString, noteNameToMidi, midiName,
                   parseScore, parseNote, encodeEvent, encodeScoreEvents, EXAMPLE_SCORE };
