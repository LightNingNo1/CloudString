// preload.js - contextBridge 安全暴露主进程能力给渲染进程
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
    // 版本
    getVersion: () => ipcRenderer.invoke('get-version'),

    // 串口
    getPorts: () => ipcRenderer.invoke('get-ports'),
    connect: (portPath) => ipcRenderer.invoke('connect', portPath),
    disconnect: () => ipcRenderer.invoke('disconnect'),
    isConnected: () => ipcRenderer.invoke('is-connected'),
    send: (bytes) => ipcRenderer.invoke('send', bytes),
    onSerialData: (cb) => ipcRenderer.on('serial-data', (_e, d) => cb(d)),
    onDisconnected: (cb) => ipcRenderer.on('serial-disconnected', () => cb()),

    // 转录
    pickMp3: () => ipcRenderer.invoke('pick-mp3'),
    transcribe: (filePath) => ipcRenderer.invoke('transcribe-mp3', filePath),
    onTranscribeProgress: (cb) => ipcRenderer.on('transcribe-progress', (_e, d) => cb(d)),

    // 手动乐谱（主功能）
    parseScore: (text) => ipcRenderer.invoke('parse-score', text),
    scoreExample: () => ipcRenderer.invoke('score-example'),

    // 下载
    download: (encodedEvents, slot) => ipcRenderer.invoke('download-song', encodedEvents, slot),
    queryStatus: () => ipcRenderer.invoke('query-status'),
    onDownloadProgress: (cb) => ipcRenderer.on('dl-progress', (_e, d) => cb(d)),

    // 录制
    startRecording: () => ipcRenderer.invoke('rec-start'),
    stopRecording: () => ipcRenderer.invoke('rec-stop'),
    queryRecording: () => ipcRenderer.invoke('rec-query'),
    readRecording: () => ipcRenderer.invoke('rec-read')
});
