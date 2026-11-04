# 曲目下载器（FPGA 蓝牙版）

把任意 MP3 歌曲自动转成拨弦模式 32 弦引导曲目，通过 VG6328A 蓝牙模块下载到 FPGA 并物理发声播放。

## 运行

```bash
npm start
```

首次使用前先安装依赖：`npm install`。

## 使用流程

1. **配对蓝牙**：Windows 设置 → 蓝牙 → 搜索并配对 `XLBT`（SPP 设备）。
   配对成功后会出现蓝牙虚拟串口（注册表枚举识别为「蓝牙 COMx」）。
2. **连接**：点「刷新」列出串口 → 选择蓝牙 COM 口 → 点「连接」（115200 8N1）。
3. **选歌转谱**：点「选择 MP3…」→「AI 转谱」。
   - AI 识谱耗时约等于歌曲时长，进度条会实时显示，请耐心等待。
   - 转谱结果会列出每个引导事件对应的弦号、音名和时值。
4. **下载播放**：点「下载到 FPGA 并播放」。
   - 自动完成 BEGIN → DATA 分帧 → END → PLAY(曲目 4)，ACK 全部确认后 FPGA 开始指引播放。
   - 下载区 LED 会按谱面逐弦点亮，等你弹对才推进（拨弦模式）。

## 工作原理

| 环节 | 实现 |
| --- | --- |
| MP3 解码 | `mpg123-decoder`（WASM），任意采样率 → 混单声道 → 线性重采样 22050Hz |
| AI 转谱 | Spotify `basic-pitch`（TF.js CPU，模型内置），多音识别 → 时间格化取最强音提取主旋律 |
| 32 弦量化 | 按 FPGA 定弦（C3~C7 白键竖琴定弦，v0..31）量化到最近白键，越界吸附边界 |
| 事件编码 | 16 位 `{片内弦号[15:13], 八度层[12:11], 时值(10ms)[10:0]}`，弦号 = 层×8 + 片内号 |
| 下载协议 | `AA 55 \| LEN \| CMD \| PAYLOAD \| SUM`；BEGIN/DATA/END/PLAY 四步，DATA 带起始序号天然幂等，ACK 超时重发 3 次 |

## 已知限制

- **推理较慢**：basic-pitch CPU 推理约 1 倍实时（3 分钟的歌约等 3 分钟），UI 不卡顿（独立子进程）。
- **事件上限 64**：song_ram 深度限制。歌曲过长时自动压缩最短的装饰音并入邻居，保住旋律骨干。
- **只弹白键**：32 根弦是 C 大调白键定弦，升降号音符自动量化到最近白键。
- **音域 C3~C7**：超出 MIDI 48..96 的音符吸附到边界弦（v0 / v31）。

## 目录结构

```
song_downloader/
├── main.js          主进程：串口管理 + 下载驱动 + 转录子进程调度
├── worker.js        转录子进程（ELECTRON_RUN_AS_NODE 运行，不阻塞 UI）
├── transcribe.js    解码/混音/重采样/推理/主旋律提取/事件编码
├── download.js      ble_link 帧打包 + ACK 握手状态机
├── preload.js       IPC 安全桥
└── renderer/        UI（index.html / style.css / renderer.js）
```

测试脚本：`node test_pipeline.js`（真实 MP3 转谱）、`node test_download_seq.js`（模拟 FPGA 握手）、`node test_wasm.js`（后端性能对比，结果 1.0x 故默认用 cpu）。
