// bridge.cs - 串口桥：用 .NET SerialPort 打开串口（蓝牙虚拟串口），
// 通过标准输入/输出与宿主（Electron 主进程）双向透传。
// 用途：绕过 serialport(Node) 打开蓝牙串口失败的问题。
// 用法: bridge.exe <COM口> [波特率]
using System;
using System.IO;
using System.IO.Ports;
using System.Threading;

class Bridge
{
    static void Main(string[] args)
    {
        string portName = args.Length > 0 ? args[0] : "COM13";
        int baud = args.Length > 1 ? int.Parse(args[1]) : 115200;
        SerialPort sp = new SerialPort(portName, baud, Parity.None, 8, StopBits.One);
        sp.Handshake = Handshake.None;
        sp.DtrEnable = true;
        sp.RtsEnable = true;
        sp.ReadTimeout = 200;
        try
        {
            sp.Open();
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("BRIDGE_OPEN_FAIL: " + e.Message);
            Environment.Exit(1);
        }
        // 打开成功标志走 stderr，stdout 完全留给串口数据透传
        Console.Error.WriteLine("BRIDGE_OPEN_OK");
        Stream stdin = null;
        Stream stdout = null;
        try
        {
            stdin = Console.OpenStandardInput();
            stdout = Console.OpenStandardOutput();
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("BRIDGE_STDIO_FAIL: " + e.Message);
            Environment.Exit(2);
        }
        bool running = true;
        Thread reader = new Thread(delegate ()
        {
            byte[] buf = new byte[4096];
            while (running)
            {
                try
                {
                    int n = sp.Read(buf, 0, buf.Length);
                    if (n > 0)
                    {
                        stdout.Write(buf, 0, n);
                        stdout.Flush();
                    }
                }
                catch (TimeoutException) { }
                catch (Exception) { break; }
            }
        });
        reader.IsBackground = true;
        reader.Start();
        try
        {
            byte[] ibuf = new byte[4096];
            while (true)
            {
                int n = stdin.Read(ibuf, 0, ibuf.Length);
                if (n <= 0) break;
                sp.Write(ibuf, 0, n);
            }
        }
        catch (Exception) { }
        running = false;
        try { sp.Close(); } catch (Exception) { }
        Environment.Exit(0);
    }
}
