// worker.js - 转录子进程：独立 Node 进程跑 MP3 解码 + basic-pitch 推理 + 后处理
// 通信协议（stdin/stdout 逐行 JSON）：
//   主进程 -> 本进程: {id, cmd:"transcribe", file}
//   本进程 -> 主进程: {id, type:"progress", stage, pct} / {id, type:"result", ok, data|error}
// 用独立进程是为了避免 tfjs CPU 推理阻塞 Electron 主进程（串口/UI）。
const readline = require('readline');
const { transcribeMp3 } = require('./transcribe.js');

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

function send(msg) {
    process.stdout.write(JSON.stringify(msg) + '\n');
}

// 预热：首次请求时加载模型（modelPromise 缓存），进度 0 触发一次即可
(async () => {
    await new Promise((r) => setTimeout(r, 10));   // 确保 stdin 监听已就绪
})();

rl.on('line', async (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch (_) { return; }
    if (msg.cmd !== 'transcribe') return;
    try {
        const res = await transcribeMp3(msg.file, {
            onStage: (stage, pct) => send({ id: msg.id, type: 'progress', stage, pct })
        });
        send({ id: msg.id, type: 'result', ok: true, data: res });
    } catch (e) {
        send({ id: msg.id, type: 'result', ok: false, error: e.message });
    }
});
