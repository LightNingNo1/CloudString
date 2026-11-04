// ============================================================================
// tb_domain.v -【统一时钟改造】针对本次两个改动模块的定点/时序验证
// ----------------------------------------------------------------------------
//   验证对象（仅本次改动，其余模块未变）：
//     1) pitch_32v : 32x32 乘法拆成 S_WAIT(寄存 prod_r) + S_MUL(取 [47:16]) 两级流水，
//                    验证 6 路串行 TDM 的每路结果 == (定弦基频 * ratio) >> 16，
//                    且 mode=0 时输出恒等于 PLK_ALL。
//     2) vibrato   : 新增 200 拍启动延时（vdly），使 TDM 写回窗口 214..648 拍
//                    与引擎 S_PH 读窗口 1..129 拍完全错开。
//                    验证：帧内读窗口(<=129拍)内 inc_out 绝不变化，
//                          帧末（t=2000，全部写回完成后）数值符合闭式推导。
//
//   参考模型：pitch_map / pitch_tbl 本次未改动，直接层次化读 ROM 做插值参考。
//   时钟：功能验证用周期 10ns，与真实 120MHz 无关（DUT 无频率相关逻辑）。
//   驱动约定：所有激励都在 posedge 之后 #1 施加，避免与 DUT 非阻塞赋值竞争。
// ============================================================================
`timescale 1ns/1ps

module tb_domain;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg     rst_n;
    integer errs = 0;

    // ------------------------------------------------------------------ pitch
    reg           p_scan;
    reg           p_mode, p_slide;
    reg  [95:0]   p_code;
    wire [1023:0] p_inc;

    pitch_32v u_pitch (
        .clk      (clk),
        .rst_n    (rst_n),
        .scan_done(p_scan),
        .mode     (p_mode),
        .slide_en (p_slide),
        .code_all (p_code),
        .inc_all  (p_inc)
    );

    // 拨弦固定音表（与 pitch_32v.PLK_ALL 逐位一致，此处独立复制作为黄金参考）
    localparam [1023:0] PLK =
        1024'h0b29a61a0a8942e70962fc96085cd15707734075070834ba0643cd1b0594d30d0594d30d0544a17304b17e4b042e68ac03b9a03a03841a5d0321e68d02ca698702ca698702a250ba0258bf260217345601dcd01d01c20d2f0190f347016534c3016534c30151285d012c5f93010b9a2b00ee680f00e1069700c879a300b29a62;

    // ---------------------------------------------------------------- vibrato
    reg  [11:0]   t;            // 帧内计数 0..2499
    reg           v_sen;        // sample_en
    reg           v_en;
    reg  [3:0]    v_depth;
    reg  [1023:0] v_in;
    wire [1023:0] v_out;

    vibrato u_vib (
        .clk      (clk),
        .rst_n    (rst_n),
        .sample_en(v_sen),
        .vib_en   (v_en),
        .depth    (v_depth),
        .inc_in   (v_in),
        .inc_out  (v_out)
    );

    always @(posedge clk) begin
        if (!rst_n)                  t <= 12'd0;
        else if (t == 12'd2499)      t <= 12'd0;
        else                         t <= t + 12'd1;
    end
    always @(*) v_sen = rst_n && (t == 12'd0);

    // ------------------------------------------------------------------ utils
    function [31:0] lane;
        input [1023:0] bus;
        input integer  k;
        begin lane = bus[32*k +: 32]; end
    endfunction

    // 参考乘法：prod = base * ratio（64bit 中间宽），取 [47:16]
    function [31:0] mul_ref;
        input [31:0] base;
        input [31:0] ratio;
        reg   [63:0] p;
        begin
            p = base * ratio;
            mul_ref = p[47:16];
        end
    endfunction

    // 参考 ratio：直读 pitch_tbl ROM + pitch_map 同式插值
    function [31:0] ref_ratio;
        input [11:0] c;
        reg [63:0] row;
        reg [31:0] t0, t1, diff;
        begin
            row  = u_pitch.u_map.u_tbl.rom[c[11:6]];
            t0   = row[31:0];
            t1   = row[63:32];
            diff = t1 - t0;
            ref_ratio = t0 + (((diff >> 2) * {26'd0, c[5:0]}) >> 4);
        end
    endfunction

    task chk_lane;
        input [1023:0]   bus;
        input integer    k;
        input [31:0]     exp;
        input [8*40-1:0] nm;
        reg   [31:0]     got;
        begin
            got = bus[32*k +: 32];
            if (got !== exp) begin
                $display("  FAIL [%0s] lane%0d got=%08x exp=%08x", nm, k, got, exp);
                errs = errs + 1;
            end else begin
                $display("  ok   [%0s] lane%0d = %08x", nm, k, got);
            end
        end
    endtask

    task chk_bus;
        input [1023:0]   bus;
        input [1023:0]   exp;
        input [8*40-1:0] nm;
        begin
            if (bus !== exp) begin
                $display("  FAIL [%0s] 1024bit mismatch: got=%h exp=%h", nm, bus, exp);
                errs = errs + 1;
            end else begin
                $display("  ok   [%0s] 1024bit 逐位相等", nm);
            end
        end
    endtask

    task step;                      // 前进 n 拍（在 posedge 之后 #1 施加/采样）
        input integer n;
        integer i;
        begin for (i=0; i<n; i=i+1) begin @(posedge clk); #1; end end
    endtask

    task pulse_scan;                // ADC 一轮扫描完成：1 拍脉冲
        begin
            @(posedge clk); #1; p_scan = 1'b1;
            @(posedge clk); #1; p_scan = 1'b0;
        end
    endtask

    task wait_t;                    // 等到本帧（或下一帧）内 t == tt
        input [11:0] tt;
        begin
            @(posedge clk); #1;
            while (t !== tt) begin @(posedge clk); #1; end
        end
    endtask

    // ============================================================ 主流程
    reg [31:0] rref;
    initial begin
        rst_n   = 1'b0;
        p_scan  = 1'b0; p_mode = 1'b0; p_slide = 1'b0; p_code = 96'd0;
        v_en    = 1'b0; v_depth = 4'd0; v_in   = 1024'd0;

        // ======================= 1) pitch_32v =======================
        step(5);
        #1 rst_n = 1'b1;
        step(5);
        $display("== pitch_32v ==");

        // T1: 拉弦 + 滑音 + code=2048 → ratio = 2.0（表内精确值）→ inc = 2*VIO_k
        p_mode = 1'b1; p_slide = 1'b1; p_code = {8{12'd2048}};
        pulse_scan; step(100);
        chk_lane(p_inc,  0, 32'd15624206,  "T1.v0=2*VIO0");
        chk_lane(p_inc,  1, 32'd23409858,  "T1.v1=2*VIO1");
        chk_lane(p_inc,  2, 32'd35075158,  "T1.v2=2*VIO2");
        chk_lane(p_inc,  3, 32'd52553370,  "T1.v3=2*VIO3");
        chk_lane(p_inc,  4, 32'd78741068,  "T1.v4=2*VIO4");
        chk_lane(p_inc,  5, 32'd117978298, "T1.v5=2*VIO5");
        chk_lane(p_inc,  6, 32'd0,         "T1.v6=0");
        chk_lane(p_inc, 31, 32'd0,         "T1.v31=0");

        // T2: 滑音关闭 → 直接取定弦基频（走 base_lat 分支）
        p_slide = 1'b0;
        pulse_scan; step(100);
        chk_lane(p_inc, 0, 32'd7812103,  "T2.v0=VIO0");
        chk_lane(p_inc, 5, 32'd58989149, "T2.v5=VIO5");

        // T3: code=4095（段内插值，ratio≈3.998）→ 与参考插值模型逐路一致
        p_slide = 1'b1; p_code = {8{12'd4095}};
        pulse_scan; step(100);
        rref = ref_ratio(12'd4095);
        $display("  ref ratio(4095) = %0d (0x%08x)", rref, rref);
        chk_lane(p_inc, 0, mul_ref(32'd7812103,  rref), "T3.v0");
        chk_lane(p_inc, 3, mul_ref(32'd26276685, rref), "T3.v3");
        chk_lane(p_inc, 5, mul_ref(32'd58989149, rref), "T3.v5");

        // T4: 拨弦模式 → 输出恒等于 PLK_ALL
        p_mode = 1'b0;
        step(3);
        chk_bus(p_inc, PLK, "T4.mode0=PLK_ALL");

        // ======================= 2) vibrato =======================
        // 重新复位，使 vibrato 从干净的第 1 帧开始（t=0 即 sample_en）
        rst_n = 1'b0; step(5);
        v_in    = {32{32'h00100000}};   // 32 路同值，便于闭式推导
        v_en    = 1'b1;
        v_depth = 4'd15;
        #1 rst_n = 1'b1;                // 释放：下一拍 t=0 → 帧1 的 sample_en
        step(3);
        $display("== vibrato (base=0x00100000, depth=15) ==");

        // 帧1：dsig_lat 锁存的是复位后的 lfo/dep（=0）→ 无调制
        wait_t(12'd2000);
        chk_lane(v_out,  0, 32'h00100000, "F1.lane0 无调制");
        chk_lane(v_out, 31, 32'h00100000, "F1.lane31");

        // 帧2：dep=1, lfo=-128 → dsig=-8 → vmacc = 16*8 = 128
        wait_t(12'd130);                 // 引擎读窗口内（<=129 拍之后）仍须是上一帧值
        chk_lane(v_out, 0, 32'h00100000, "F2.t130 读窗口内不变");
        wait_t(12'd2000);
        chk_lane(v_out,  0, 32'h000FFF80, "F2.lane0 -128");
        chk_lane(v_out, 31, 32'h000FFF80, "F2.lane31 -128");

        // 帧3：dsig=-16 → -256
        wait_t(12'd130);
        chk_lane(v_out, 0, 32'h000FFF80, "F3.t130 读窗口内不变");
        wait_t(12'd2000);
        chk_lane(v_out, 0, 32'h000FFF00, "F3.lane0 -256");

        // 帧4：dsig=-24 → -384
        wait_t(12'd130);
        chk_lane(v_out, 0, 32'h000FFF00, "F4.t130 读窗口内不变");
        wait_t(12'd2000);
        chk_lane(v_out, 0, 32'h000FFE80, "F4.lane0 -384");

        // 帧5：dsig=-32 → -512（同时确认 32 路 TDM 全部写到位）
        wait_t(12'd130);
        chk_lane(v_out, 0, 32'h000FFE80, "F5.t130 读窗口内不变");
        wait_t(12'd2000);
        chk_lane(v_out,  0, 32'h000FFE00, "F5.lane0 -512");
        chk_lane(v_out, 31, 32'h000FFE00, "F5.lane31 -512");

        if (errs == 0) $display("\nRESULT: ALL PASS");
        else           $display("\nRESULT: %0d FAIL", errs);
        $finish;
    end

endmodule