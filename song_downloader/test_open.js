// test_open.js - 最小化验证 serialport 打开蓝牙串口的行为（对比 .NET 方式）
const { SerialPort } = require('serialport');

const pathArg = process.argv[2] || 'COM13';
console.log('Node serialport 打开 ' + pathArg + ' ...');
const t0 = Date.now();
const port = new SerialPort({
    path: pathArg,
    baudRate: 115200,
    dataBits: 8,
    stopBits: 1,
    parity: 'none',
    autoOpen: false
});
const timer = setTimeout(() => {
    console.log('>>> 15秒无回调（挂起）');
    process.exit(2);
}, 15000);
port.open((err) => {
    clearTimeout(timer);
    const ms = Date.now() - t0;
    if (err) {
        console.log('>>> open 回调失败 [' + ms + 'ms]: ' + err.message);
        process.exit(1);
    }
    console.log('>>> open 成功 [' + ms + 'ms]，保持 8 秒观察灯...');
    setTimeout(() => {
        port.close();
        console.log('>>> 已关闭');
        process.exit(0);
    }, 8000);
});
