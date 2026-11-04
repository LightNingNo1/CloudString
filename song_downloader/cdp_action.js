// cdp_action.js - 通过 CDP 对 APP 界面执行动作
// 用法: node cdp_action.js disconnect|connect|clickDownload|query
const action = process.argv[2] || 'query';
const { fetch } = global;

async function main() {
    const t = await (await fetch('http://127.0.0.1:9222/json')).json();
    const p = t.find(x => x.type === 'page');
    if (!p) { console.log('NO_PAGE, 请确认 APP 以 --remote-debugging-port=9222 启动'); return; }
    const ws = new WebSocket(p.webSocketDebuggerUrl);
    await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
    let i = 0; const pend = new Map();
    ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } };
    const ev = expr => { const id = ++i; ws.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression: expr, returnByValue: true } })); return new Promise(r => pend.set(id, r)); };
    const click = async (sel, label) => {
        const expr = `(()=>{const b=document.querySelector(${JSON.stringify(sel)});if(!b)return 'not found';if(b.disabled)return 'disabled';b.click();return 'clicked'})()`;
        const r = await ev(expr);
        console.log(`${label}:`, r.result ? r.result.result.value : '?');
    };
    const stateExpr = `(()=>{const $=id=>document.getElementById(id);return JSON.stringify({
        conn:$('connText').textContent, connDot:$('connDot').className,
        connectDisabled:$('connectBtn').disabled, disconnectDisabled:$('disconnectBtn').disabled,
        log:(()=>{const a=$('logArea');const tags=[...a.children].slice(-3);return tags.map(x=>x.textContent).join(' | ')})()
    })})()`;

    switch (action) {
        case 'disconnect':
            await click('#disconnectBtn', '断开');
            await new Promise(r => setTimeout(r, 1000));
            break;
        case 'connect':
            // 先选中 COM13（若存在），再点击连接
            await ev(`(()=>{const s=document.getElementById('portSelect');const o=[...s.options].find(o=>o.value==='COM13');if(o){s.value='COM13';s.dispatchEvent(new Event('change'));}return 'port='+(s.value||'<空>')})()`);
            await new Promise(r => setTimeout(r, 300));
            await click('#connectBtn', '连接');
            break;
        case 'clickDownload':
            await click('#downloadBtn', '下载');
            await new Promise(r => setTimeout(r, 1000));
            break;
        case 'query':
        default:
            break;
    }
    const r = await ev(stateExpr);
    console.log('STATE:', r.result ? r.result.result.value : '?');
    ws.close();
}
main().catch(e => { console.error('ERR:', e.message); process.exit(1); });