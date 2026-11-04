// cdp_state.js - 读取 APP 界面关键状态
const { fetch } = global;
(async () => {
    const t = await (await fetch('http://127.0.0.1:9222/json')).json();
    const p = t.find(x => x.type === 'page');
    if (!p) { console.log('NO_PAGE'); return; }
    const ws = new WebSocket(p.webSocketDebuggerUrl);
    await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
    let i = 0; const pend = new Map();
    ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } };
    const ev = expr => { const id = ++i; ws.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression: expr, returnByValue: true } })); return new Promise(r => pend.set(id, r)); };
    const expr = `(()=>{
        const $ = id => document.getElementById(id);
        return JSON.stringify({
            conn: $('connText').textContent,
            songInfo: $('songInfo').textContent,
            transcribeBtnDisabled: $('transcribeBtn').disabled,
            downloadBtnDisabled: $('downloadBtn').disabled,
            transcribeLabel: $('transcribeLabel').textContent,
            transcribeShown: !$('transcribeBar').classList.contains('hidden'),
            transcribeFill: $('transcribeFill').style.width,
            dlText: $('dlProgress').textContent,
            lastLog: (()=>{const a=$('logArea');return a?a.lastChild?.textContent:null})()
        });
    })()`;
    const r = await ev(expr);
    console.log(r.result ? r.result.result.value : JSON.stringify(r.result));
    ws.close();
})();