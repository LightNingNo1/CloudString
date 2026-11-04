// main.js - 主进程：串口（蓝牙 SPP 虚拟串口）管理 + 转录子进程 + 曲目下载
// 串口方案跟随 wheelchair 示例：SerialPort.list + 注册表枚举蓝牙 COM 口
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { spawn } = require('child_process');
const readline = require('readline');
const { SerialPort } = require('serialport');
const { attachPort, abortDownload, feedRx, downloadSong, queryStatus,
    startRecording, stopRecording, queryRecording, readRecording } = require('./download.js');
const score = require('./score.js');   // 手动乐谱解析（主功能）

// ---------------- 转录子进程（避免推理阻塞主进程串口/UI） ----------------
let worker = null;
let workerSeq = 0;
const pendingTranscribe = new Map();   // id -> {resolve, reject}

function ensureWorker() {
    if (worker) return worker;
    // electron.exe 以纯 Node 模式跑 worker.js
    worker = spawn(process.execPath, [path.join(__dirname, 'worker.js')], {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' }
    });
    worker.stdout.setEncoding('utf8');
    readline.createInterface({ input: worker.stdout, crlfDelay: Infinity }).on('line', (line) => {
        let msg;
        try { msg = JSON.parse(line); } catch (_) { return; }
        const pend = pendingTranscribe.get(msg.id);
        if (!pend) return;
        if (msg.type === 'progress') {
            if (mainWindow && !mainWindow.isDestroyed())
                mainWindow.webContents.send('transcribe-progress', { stage: msg.stage, pct: msg.pct });
        } else if (msg.type === 'result') {
            pendingTranscribe.delete(msg.id);
            msg.ok ? pend.resolve(msg.data) : pend.reject(new Error(msg.error));
        }
    });
    worker.stderr.setEncoding('utf8');
    worker.stderr.on('data', (d) => console.error('[worker]', d.trim()));
    worker.on('exit', (code) => {
        console.error('[worker] 退出 code=' + code);
        for (const [, p] of pendingTranscribe) p.reject(new Error('转录进程异常退出'));
        pendingTranscribe.clear();
        worker = null;
    });
    return worker;
}

function requestTranscribe(filePath) {
    const id = ++workerSeq;
    return new Promise((resolve, reject) => {
        const w = ensureWorker();
        pendingTranscribe.set(id, { resolve, reject });
        w.stdin.write(JSON.stringify({ id, cmd: 'transcribe', file: filePath }) + '\n');
    });
}

let mainWindow = null;
let serialPort = null;    // 串口包装对象 {isOpen, write}，供 download.js 使用
let serialChild = null;   // bridge.exe 子进程（.NET SerialPort 桥）
let connecting = false;

// ---------------- 窗口 ----------------

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 960,
        height: 760,
        minWidth: 760,
        minHeight: 620,
        title: '曲目下载器 (FPGA 蓝牙)',
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            preload: path.join(__dirname, 'preload.js')
        }
    });
    mainWindow.loadFile('renderer/index.html');
    mainWindow.on('closed', () => { closePort(); app.quit(); });
}

// ---------------- 串口 ----------------

function closePort() {
    abortDownload();
    const child = serialChild;
    serialChild = null;
    serialPort = null;
    if (child) {
        try { child.removeAllListeners(); } catch (_) {}
        try { child.stdin.end(); } catch (_) {}
        try { child.kill(); } catch (_) {}
    }
    attachPort(null);
    connecting = false;
}
// kill 所有 bridge 进程并等待 COM 口句柄释放（避免新 bridge 打开被拒）
// 蓝牙 SPP 虚拟串口同一时刻只能被单一进程持有；上一个句柄未释放，新打开必然 Access denied
function purgeBridgeAndWait(waitMs = 800) {
    return new Promise((resolve) => {
        try {
            // 终结本会话已知 + 系统里所有残留 bridge 子进程
            const { execSync, spawnSync } = require('child_process');
            try { spawnSync('taskkill', ['/F', '/IM', 'bridge.exe', '/T']); } catch (_) {}
        } catch (_) {}
        setTimeout(resolve, waitMs);   // 给 OS 释放串口句柄留足时间
    });
}

// 枚举 COM 口（含注册表里的蓝牙虚拟串口，仿 wheelchair 示例）
async function getAvailablePorts() {
    const ports = await SerialPort.list();
    const portMap = new Map();
    for (const p of ports) {
        portMap.set(p.path, {
            path: p.path,
            name: p.productName || p.manufacturer || p.path,
            isBluetooth: (p.manufacturer || '').includes('Bluetooth') ||
                         (p.productName || '').includes('HC-05') ||
                         (p.productName || '').includes('BC')
        });
    }
    try {
        const { execSync } = require('child_process');
        const output = execSync('reg query "HKLM\\HARDWARE\\DEVICEMAP\\SERIALCOMM" 2>nul', { encoding: 'utf8', timeout: 3000 });
        for (const line of output.split('\n')) {
            const m = line.match(/\\Device\\(\S+)\s+REG_SZ\s+(COM\d+)/);
            if (m) {
                const devName = m[1];
                const comName = m[2];
                if (!portMap.has(comName)) {
                    const isBT = devName.toLowerCase().includes('bth');
                    portMap.set(comName, {
                        path: comName,
                        name: isBT ? `蓝牙 ${comName} (${devName})` : `${comName} (${devName})`,
                        isBluetooth: isBT
                    });
                }
            }
        }
    } catch (_) {}
    return Array.from(portMap.values());
}

// 用 bridge.exe(.NET SerialPort) 打开蓝牙虚拟串口：打开蓝牙 SPP 会触发链路建立，
// 耗时可达数秒；bridge 成功时 stderr 打印 BRIDGE_OPEN_OK，失败打印 BRIDGE_OPEN_FAIL 后退出
function connectPort(portPath) {
    return new Promise((resolve, reject) => {
        if (connecting) return reject(new Error('正在连接中'));
        connecting = true;
        closePort();
        const MAX_ATTEMPTS = 5;
        const RETRY_DELAYS = [3000, 4000, 5000, 6000];   // 失败后指数退避，给蓝牙 RFCOMM 释放时间
        const OPEN_TIMEOUT = 25000;                        // 单次链路建立最长等待
        let attempt = 0;
        const tryOpen = () => {
            attempt++;
        let settled = false;
        let child = null;
        let timeout = null;
        let stderrBuf = '';
        const done = (result) => {
            if (settled) return;
            settled = true;
            if (timeout) clearTimeout(timeout);
            if (result.success) {
                serialChild = child;
                serialPort = {
                    get isOpen() { return child.exitCode === null && !child.killed; },
                    write(buf, cb) {
                        try { child.stdin.write(buf, cb); }
                        catch (e) { cb && cb(e); }
                    }
                };
                attachPort(serialPort);
                connecting = false;
                resolve({ success: true });
            } else {
                if (child) { try { child.kill(); } catch (_) {} }
                if (attempt < MAX_ATTEMPTS) {
                    // 失败重试前同样清场等待，确保上一个 bridge 的 COM 句柄彻底释放
                    purgeBridgeAndWait().then(() => { setTimeout(tryOpen, RETRY_DELAYS[attempt - 1] || 5000); });
                    return;
                }
                connecting = false;
                resolve({ success: false, error: result.error });
            }
        };
        try {
            child = spawn(path.join(__dirname, 'bridge.exe'), [portPath, '115200'], { stdio: ['pipe', 'pipe', 'pipe'] });
        } catch (e) {
            return done({ success: false, error: e.message });
        }
        timeout = setTimeout(() => done({ success: false, error: '连接超时' }), OPEN_TIMEOUT);
            // stdout 是串口数据透传（原始字节，勿设文本编码）
            child.stdout.on('data', (buf) => {
                for (const b of buf) feedRx(b);   // 先喂给下载应答匹配
                if (mainWindow && !mainWindow.isDestroyed()) {
                    mainWindow.webContents.send('serial-data', Array.from(buf));
                }
            });
            // stderr 承载打开成功/失败标志
            child.stderr.setEncoding('utf8');
            child.stderr.on('data', (d) => {
                stderrBuf += d;
                if (!settled && stderrBuf.includes('BRIDGE_OPEN_OK')) done({ success: true });
            });
            child.on('error', (err) => done({ success: false, error: err.message }));
            child.on('exit', (code) => {
                if (!settled) {
                    const m = stderrBuf.match(/BRIDGE_OPEN_FAIL:\s*(.+)/);
                    done({ success: false, error: m ? m[1].trim() : `串口打开失败 (code=${code})` });
                } else if (serialChild === child) {
                    // 已连上后子进程退出 = 串口断开
                    abortDownload();
                    serialChild = null;
                    serialPort = null;
                    if (mainWindow && !mainWindow.isDestroyed()) {
                        mainWindow.webContents.send('serial-disconnected');
                    }
                }
            });
        };
        // 清场确保旧 bridge 全部退出、COM 口句柄释放后，才开始首次连接
        purgeBridgeAndWait().then(tryOpen);
    });
}

function sendData(bytes) {
    return new Promise((resolve, reject) => {
        if (!serialPort || !serialPort.isOpen) return reject(new Error('未连接'));
        serialPort.write(Buffer.from(bytes), (err) => err ? reject(err) : resolve({ success: true }));
    });
}

// ---------------- IPC ----------------

ipcMain.handle('get-version', () => app.getVersion());   // 读取 package.json 的 version 字段（版号唯一数据源）
ipcMain.handle('get-ports', async () => { try { return await getAvailablePorts(); } catch (e) { return []; } });
ipcMain.handle('connect', async (_, portPath) => {
    try { return await connectPort(portPath); }
    catch (e) { return { success: false, error: e.message }; }
});
ipcMain.handle('send', async (_, bytes) => {
    try { return await sendData(bytes); }
    catch (e) { return { success: false, error: e.message }; }
});
ipcMain.handle('disconnect', () => { closePort(); return true; });
ipcMain.handle('is-connected', () => serialPort !== null && serialPort.isOpen);

ipcMain.handle('pick-mp3', async () => {
    const r = await dialog.showOpenDialog(mainWindow, {
        title: '选择 MP3 歌曲',
        filters: [{ name: 'MP3 音频', extensions: ['mp3'] }],
        properties: ['openFile']
    });
    return r.canceled ? null : r.filePaths[0];
});

ipcMain.handle('transcribe-mp3', async (_, filePath) => {
    try {
        return await requestTranscribe(filePath);
    } catch (e) {
        return { error: e.message };
    }
});

ipcMain.handle('parse-score', async (_, text) => {
    try {
        const { events, warnings, errors, lineCount } = score.parseScore(text);
        if (errors.length > 0)
            return { error: `乐谱有 ${errors.length} 处错误，请修正后再解析` + '\n' + errors.join('\n'), errors };
        const encoded = score.encodeScoreEvents(events);
        return { events, encoded, warnings, lineCount };
    } catch (e) {
        return { error: e.message };
    }
});

ipcMain.handle('score-example', () => score.EXAMPLE_SCORE);

ipcMain.handle('download-song', async (_, encodedEvents, slot) => {
    try {
        return await downloadSong(encodedEvents, slot, (p) => {
            if (mainWindow && !mainWindow.isDestroyed())
                mainWindow.webContents.send('dl-progress', p);
        });
    } catch (e) {
        return { error: e.message };
    }
});

ipcMain.handle('query-status', async () => {
    try {
        return await queryStatus();
    } catch (e) {
        return { error: e.message };
    }
});

// ---- 录制 ----
ipcMain.handle('rec-start', async () => {
    try { await startRecording(); return { success: true }; }
    catch (e) { return { error: e.message }; }
});
ipcMain.handle('rec-stop', async () => {
    try { await stopRecording(); return { success: true }; }
    catch (e) { return { error: e.message }; }
});
ipcMain.handle('rec-query', async () => {
    try { return await queryRecording(); }
    catch (e) { return { error: e.message }; }
});
ipcMain.handle('rec-read', async () => {
    try {
        const r = await readRecording();
        return { success: true, events: r.events, mode: r.mode };
    } catch (e) { return { error: e.message }; }
});

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { closePort(); if (worker) worker.kill(); app.quit(); });
process.on('uncaughtException', (err) => { console.error('未捕获异常:', err.message); });
