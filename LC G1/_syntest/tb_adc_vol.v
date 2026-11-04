`timescale 1ns/1ps
// 临时验证：ADC128S102 通道映射 + 混音器总音量响应
// 运行：iverilog -o tb_adc_vol.vvp tb_adc_vol.v ../src/adc128s102.v ../src/audio_mixer.v ../src/mul18_arb.v ../src/mul18_shared.v ; vvp tb_adc_vol.vvp

// ---------------- ADC128S102 行为模型（含一帧流水） ----------------
module adc128s102_model(
    input  wire cs_n, sclk, din,
    output reg  dout
);
    reg [7:0]  asr;                 // 串入的 8bit 控制寄存器
    reg [11:0] code_mem [0:7];      // 各通道模拟电压码
    reg [2:0]  cur_ch, pending_ch;
    reg [15:0] fr;
    reg [4:0]  rc, bc;
    integer i;
    initial begin
        for (i=0;i<8;i=i+1) code_mem[i] = (i+1)*100;   // IN0=100 ... IN7=800
        pending_ch=3'd0; cur_ch=3'd0; asr=8'd0; rc=5'd0; bc=5'd0; fr=16'd0; dout=1'b0;
    end
    // CS 下降沿：开始本帧；本帧读出的通道 = 上一帧 DIN 指定的通道（上电默认 IN0）
    always @(negedge cs_n) begin
        cur_ch <= pending_ch;
        fr     <= {4'b0000, code_mem[pending_ch]};
        rc <= 5'd0; bc <= 5'd0; asr <= 8'd0;
    end
    // 前 8 个上升沿锁存控制寄存器；ADD2:ADD0 = CR[5:3] = 第 3/4/5 个串入位
    always @(posedge sclk) if (!cs_n) begin
        asr <= {asr[6:0], din};
        rc  <= rc + 1'b1;
        if (rc == 5'd7) pending_ch <= asr[4:2];
    end
    // 下降沿移出 DOUT：4 前导 0 + 12bit 结果
    always @(negedge sclk) if (!cs_n) begin
        dout <= fr[15-bc];
        bc   <= bc + 1'b1;
    end
endmodule

module tb;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;          // 50MHz

    // ---------------- DUT: ADC ----------------
    wire        cs_n, sclk, din, dout;
    wire [11:0] c0,c1,c2,c3,c4,c5,c6,c7;
    wire [2:0]  cur_ch; wire upd, sdone;
    adc128s102 u_adc (.clk(clk), .rst_n(rst_n),
        .adc_cs_n(cs_n), .adc_sclk(sclk), .adc_din(din), .adc_dout(dout),
        .adc_ch0(c0), .adc_ch1(c1), .adc_ch2(c2), .adc_ch3(c3),
        .adc_ch4(c4), .adc_ch5(c5), .adc_ch6(c6), .adc_ch7(c7),
        .cur_ch(cur_ch), .adc_upd(upd), .scan_done(sdone));
    adc128s102_model u_model (.cs_n(cs_n), .sclk(sclk), .din(din), .dout(dout));

    // ---------------- DUT: 混音器 + 共享乘法器 ----------------
    reg               sample_en = 0;
    reg  [7:0]        scnt = 0;
    always @(posedge clk) begin
        scnt      <= scnt + 1'b1;
        sample_en <= (scnt == 8'd0);
    end
    wire [7:0] strv = 8'hFF;
    wire signed [15:0] s0 = 16'sd20000;
    wire [15:0] e0 = 16'd32767;
    wire [15:0] vol_t;
    wire [127:0] gain_all = {8{16'd10000}};
    wire [8:0]  mreq;                        // 只有混音器请求（bit8）
    assign mreq[7:0] = 8'd0;
    wire [161:0] ma_bus, mb_bus;
    wire [8:0]  mack;
    wire signed [35:0] mp;
    wire signed [23:0] mixout;
    mul18_arb u_arb (.clk(clk), .rst_n(rst_n), .m_req(mreq),
        .m_a(ma_bus), .m_b(mb_bus), .m_ack(mack), .m_p(mp));
    audio_mixer #(.CH_SHIFT(6'd7)) u_mix (.clk(clk), .rst_n(rst_n), .sample_en(sample_en),
        .str0(s0), .str1(0), .str2(0), .str3(0), .str4(0), .str5(0), .str6(0), .str7(0),
        .env0(e0), .env1(0), .env2(0), .env3(0), .env4(0), .env5(0), .env6(0), .env7(0),
        .gain(gain_all), .vol(vol_t), .str_valid(strv),
        .mul_a(ma_bus[161:144]), .mul_b(mb_bus[161:144]),
        .mul_req(mreq[8]), .mul_ack(mack[8]), .mul_p(mp), .mix(mixout));

    assign vol_t = volr;
    reg [15:0] volr = 16'd0;

    // ---------------- 激励 ----------------
    initial begin
        rst_n = 0;
        #200 rst_n = 1;

        // ADC 通道映射：跑满一圈，看各通道是否分别对应 IN0..IN7
        #2000000;   // 2ms（IIR 平滑时间常数 ~0.5ms，留足裕量）
        $display("[ADC] T0  c0=%0d c1=%0d c2=%0d c3=%0d c4=%0d c5=%0d c6=%0d c7=%0d (期望 100,200,...,800)",
                 c0,c1,c2,c3,c4,c5,c6,c7);
        u_model.code_mem[0] = 12'd3500;
        #2000000;
        $display("[ADC] IN0->3500 后 c0=%0d (期望 3500)", c0);
        u_model.code_mem[0] = 12'd0;
        #2000000;
        $display("[ADC] IN0->0 后 c0=%0d (期望 0)", c0);

        // 混音器总音量响应
        volr = 16'd32760; #8000; $display("[MIX] vol=%0d mix=%0d", volr, mixout);
        volr = 16'd16384; #8000; $display("[MIX] vol=%0d mix=%0d", volr, mixout);
        volr = 16'd8192;  #8000; $display("[MIX] vol=%0d mix=%0d", volr, mixout);
        volr = 16'd0;     #8000; $display("[MIX] vol=%0d mix=%0d", volr, mixout);
        $finish;
    end
endmodule