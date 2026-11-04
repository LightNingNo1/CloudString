// cdp_inspect.js - 通过 CDP 读取 APP 当前状态：乐谱输入、预览、日志
const TARGET = 'http://127.0.0.1:9222';

async function main() {
    const pages = await (await fetch(TARGET + '/json')).json();
    const page = pages.find(p => p.type === 'page');
    if (!page) { console.log('NO_PAGE'); return; }
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    let id = 0;
    const pending = new Map();
    ws.onmessage = (ev) => {
        const msg = JSON.parse(ev.data);
        if (msg.id && pending.has(msg.id)) {
            pending.get(msg.id)(msg);
            pending.delete(msg.id);
        }
    };
    const call = (method, params) => new Promise((resolve) => {
        const myId = ++id;
        pending.set(myId, resolve);
        ws.send(JSON.stringify({ id: myId, method, params }));
    });
    await new Promise((r) => ws.onopen = r);

    const expr = `(() => {
        const g = (id) => document.getElementById(id);
        const txt = (el) => el ? el.innerText || el.value || '' : '(null)';
        return JSON.stringify({
            scoreInput: g('scoreInput') ? g('scoreInput').value.slice(0, 2000) : '(null)',
            scoreInfo: txt(g('scoreInfo')),
            scorePreview: txt(g('scorePreview')),
            songInfo: txt(g('songInfo')),
            connText: txt(g('connText')),
            dlProgress: txt(g('dlProgress')),
            log: g('logArea') ? g('logArea').innerText.slice(-3000) : '(null)'
        });
    })()`;
    const r = await call('Runtime.evaluate', { expression: expr, returnByValue: true });
    const data = JSON.parse(r.result.result.value);
    console.log('===== scoreInput =====');
    console.log(data.scoreInput);
    console.log('===== scoreInfo =====');
    console.log(data.scoreInfo);
    console.log('===== scorePreview =====');
    console.log(data.scorePreview);
    console.log('===== connText / dlProgress =====');
    console.log(data.connText, '|', data.dlProgress);
    console.log('===== songInfo =====');
    console.log(data.songInfo);
    console.log('===== log (tail 3000) =====');
    console.log(data.log);
    ws.close();
    process.exit(0);
}
main().catch(e => { console.log('ERR', e.message); process.exit(1); });
