// test_worker.js - 验证转录子进程 stdin/stdout 协议（模拟 main.js 调用路径）
const { spawn } = require('child_process');
const readline = require('readline');
const path = require('path');

const worker = spawn(process.execPath, [path.join(__dirname, 'worker.js')], {
    stdio: ['pipe', 'pipe', 'pipe']
});

const FILE = 'D:\\桌面\\嵌赛高云\\LC G1\\LC G1\\_syntest\\ref\\vio_A4.mp3';

readline.createInterface({ input: worker.stdout, crlfDelay: Infinity }).on('line', (line) => {
    const msg = JSON.parse(line);
    if (msg.type === 'progress') {
        process.stdout.write(`\r  [${msg.stage} ${(msg.pct * 100).toFixed(0)}%]`);
    } else if (msg.type === 'result') {
        console.log('');
        if (msg.ok) {
            const d = msg.data;
            console.log('结果 OK: 事件数', d.events.length);
            for (const e of d.events.slice(0, 5))
                console.log(`  ${e.noteName} 弦${e.s} (层${e.layer} 内${e.inner}) ${e.durMs}ms code=0x${e.encoded ? '' : ''}`);
            console.log('encoded:', d.encoded.map((v) => v.toString(16)).join(','));
            console.log('meta:', JSON.stringify(d.meta));
            process.exit(0);
        } else {
            console.error('worker 报错:', msg.error);
            process.exit(1);
        }
    }
});

worker.stderr.on('data', (d) => console.error('[stderr]', d.toString().trim()));
worker.stdin.write(JSON.stringify({ id: 1, cmd: 'transcribe', file: FILE }) + '\n');
