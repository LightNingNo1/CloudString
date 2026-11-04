// test_bridge_conn.js - 用 bridge.exe(.NET SerialPort) 测试蓝牙虚拟串口连接
// 用法: node test_bridge_conn.js [COM口] [保持秒数]
const { spawn } = require('child_process');
const path = require('path');

const port = process.argv[2] || 'COM13';
const holdMs = (parseFloat(process.argv[3]) || 8) * 1000;
const exe = path.join(__dirname, 'bridge.exe');

const child = spawn(exe, [port, '115200'], { stdio: ['pipe', 'pipe', 'pipe'] });
let stdout = '', stderr = '';
child.stdout.on('data', d => { stdout += d.toString(); });
child.stderr.on('data', d => { stderr += d.toString(); });
child.on('exit', code => console.log(`[bridge exit] code=${code}`));

setTimeout(() => { try { child.stdin.end(); } catch (_) {} }, holdMs);
setTimeout(() => {
  const alive = child.exitCode === null && !child.killed;
  const opened = alive || stderr.includes('BRIDGE_OPEN_OK');
  console.log('--- 测试结果 ---');
  console.log(`端口: ${port} @ 115200`);
  console.log(`保持时间: ${holdMs / 1000}s`);
  console.log(`进程存活: ${alive}（关闭后桥应正常退出 code=0）`);
  console.log(`stdout 字节数: ${stdout.length}`);
  console.log(`stderr: ${stderr || '(无错误输出)'}`);
  if (opened) {
    console.log('结论: 蓝牙虚拟串口打开成功，链路建立');
  } else {
    console.log('结论: 打开失败或提前退出');
  }
  if (child.exitCode === null) { try { child.kill(); } catch (_) {} }
  process.exit(0);
}, holdMs + 2000);
