// cdp_download.js - 点击「下载」并监测下载进度
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

    const readState = async () => {
        const expr = `(()=>{const $=id=>document.getElementById(id);return JSON.stringify({
            dlText: $('dlProgress').textContent,
            dlFill: $('dlFill').style.width,
            downloadBtnDisabled: $('downloadBtn').disabled,
            lastLog: (()=>{const a=$('logArea');return a?a.lastChild?.textContent:null})()
        })})()`;
        const r = await ev(expr);
        return r.result ? r.result.result.value : '?';
    };

    // 点击下载
    const r = await ev(`(()=>{document.getElementById('downloadBtn').click();return 'clicked'})()`);
    console.log('CLICK:', r.result ? r.result.result.value : '?');

    // 监测 30 秒
    for (let k = 0; k < 10; k++) {
        await new Promise(res => setTimeout(res, 3000));
        const s = await readState();
        console.log('t+' + ((k + 1) * 3) + 's:', s);
        const obj = JSON.parse(s);
        if (obj.downloadBtnDisabled === false && obj.lastLog && obj.lastLog.includes('下载完成')) {
            console.log('===> 下载已完成，FPGA 开始播放');
            break;
        }
        if (obj.lastLog && obj.lastLog.includes('下载失败')) {
            console.log('===> 下载失败');
            break;
        }
    }
    ws.close();
})();