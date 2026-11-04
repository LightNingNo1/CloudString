// cdp_connect.js - 通过 CDP (WebSocket) 驱动 Electron 窗口：选 COM13 并点连接
// 用法: node cdp_connect.js start|status
const action = process.argv[2] || 'start';

async function main() {
    const targets = await (await fetch('http://127.0.0.1:9222/json')).json();
    const page = targets.find(t => t.type === 'page');
    if (!page) throw new Error('未找到 page 目标');
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

    let seq = 0;
    const pending = new Map();
    ws.onmessage = (ev) => {
        const msg = JSON.parse(ev.data);
        if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
    };
    const send = (method, params = {}) => {
        const id = ++seq;
        ws.send(JSON.stringify({ id, method, params }));
        return new Promise((res) => pending.set(id, res));
    };
    const evalJS = async (expression) => {
        const r = await send('Runtime.evaluate', { expression, returnByValue: true });
        return r.result ? r.result.result?.value ?? r.result.result?.description : JSON.stringify(r);
    };

    if (action === 'start') {
        // 1. 选 COM13
        const setPort = await evalJS(`(()=>{const s=document.getElementById('portSelect');const o=[...s.options].find(o=>o.value==='COM13');if(o){s.value=o.value;s.dispatchEvent(new Event('change',{bubbles:true}));}return s.value;})()`);
        console.log('SET_PORT:', setPort);
        await new Promise(r => setTimeout(r, 500));
        const portVal = await evalJS(`document.getElementById('portSelect').value`);
        console.log('PORT_VALUE:', portVal);
        // 2. 点连接
        const clicked = await evalJS(`(()=>{document.getElementById('connectBtn').click();return 'clicked';})()`);
        console.log('CLICK:', clicked);
        // 3. 等待建链后查状态
        await new Promise(r => setTimeout(r, 12000));
    }
    // 查询连接状态
    const status = await evalJS(`JSON.stringify({text:document.getElementById('connText').textContent,
        dot:document.getElementById('connDot').className,
        connectBtnDisabled:document.getElementById('connectBtn').disabled,
        lastLog:(()=>{const a=document.getElementById('logArea');return a?a.lastChild?.textContent:null})()})`);
    console.log('STATUS:', status);
    ws.close();
}
main().catch(e => { console.error('ERR:', e.message); process.exit(1); });