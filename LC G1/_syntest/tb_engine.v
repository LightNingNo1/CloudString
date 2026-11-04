`timescale 1ns/1ps
// ============================================================================
// tb_engine.v - additive_engine 独立仿真验证
//   1) 拨弦重装：henv_mem[k] 应等于 W[h+1]<<16（校验 W_TBL 打包与写回路径）
//   2) 拨弦衰减：henv_mem[k] 应等于 hold - ((hold>>SH[h+1]) | 1)（校验 SH_TBL）
//   3) 拉弦混音：phase[0]=1024<<20 -> 地址恒为 {0,1024,2048,3072}，正弦取
//      {0,+32767,0,-32767}，逐条手算 16 泛音和，再经声部包络/总音量，
//      与 mix 比较（校验 TDM 流水、ROM 寻址、2 个 DSP 的握手时序与定点）
// ============================================================================
module tb_engine;

    reg clk = 1'b0;
    always #4 clk = ~clk;                 // 125MHz，功能仿真与频率无关

    reg          rst_n = 1'b0;
    reg          sample_en = 1'b0;
    reg          mode = 1'b0;
    reg [1023:0] inc_all = 1024'd0;
    reg [31:0]   note_on = 32'd0;
    reg [15:0]   env_wdata = 16'd0;
    reg [4:0]    env_waddr = 5'd0;
    reg          env_we = 1'b0;
    reg [15:0]   master_vol = 16'd32767;
    wire signed [23:0] mix;

    additive_engine u_dut (
        .clk(clk), .rst_n(rst_n), .sample_en(sample_en), .mode(mode),
        .inc_all(inc_all), .note_on(note_on),
        .env_wdata(env_wdata), .env_waddr(env_waddr), .env_we(env_we),
        .master_vol(master_vol), .mix(mix)
    );

    integer Wn [1:16];
    integer k, n, errs;
    integer vacc_exp;
    integer hold, sh, exp_x;
    reg signed [63:0] sum_exp, mix_exp;
    reg signed [15:0] sn;
    reg [31:0] pbo [0:31];
    integer q;
    reg signed [63:0] vw2_exp;

    initial begin
        Wn[ 1]=15456; Wn[ 2]=5465; Wn[ 3]=2975; Wn[ 4]=1932;
        Wn[ 5]=1382;  Wn[ 6]=1052; Wn[ 7]= 835; Wn[ 8]= 683;
        Wn[ 9]= 572;  Wn[10]= 489; Wn[11]= 424; Wn[12]= 372;
        Wn[13]= 330;  Wn[14]= 295; Wn[15]= 266; Wn[16]= 242;
        errs = 0;
    end

    task frame; begin
        @(posedge clk); sample_en = 1'b1;
        @(posedge clk); sample_en = 1'b0;
        repeat(700) @(posedge clk);
    end endtask

    task check; input reg signed [63:0] got; input reg signed [63:0] exp; input [255:0] tag; begin
        if (got !== exp) begin
            $display("  FAIL %0s: got=%0d exp=%0d", tag, got, exp);
            errs = errs + 1;
        end
    end endtask

    initial begin
        // ---------------- 复位 ----------------
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        u_dut.phase_mem[0] = 32'h40000000; // 1024<<20：inc_all 全程为 0，相位保持不变
        // 主包络改为串行写口：经 {env_waddr, env_wdata, env_we} 写入引擎侧 env_mem[0]
        env_wdata = 16'd32767; env_waddr = 5'd0; env_we = 1'b1;
        @(posedge clk); env_we = 1'b0;
        master_vol     = 16'd32767;

        // ================= 1) 拨弦：note_on 触发重装 =================
        mode = 1'b0;
        @(posedge clk); note_on = 32'd1; sample_en = 1'b1;
        @(posedge clk); sample_en = 1'b0; note_on = 32'd0;
        repeat(700) @(posedge clk);
        $display("[1] 拨弦重装 henv_mem[k] == W[k+1]<<16");
        for (k=0;k<16;k=k+1)
            check(u_dut.henv_mem[k], Wn[k+1]<<16, "reload");

        // ================= 2) 拨弦：指数泄漏衰减一步 =================
        frame;                              // 无 note_on，衰减一步
        $display("[2] 拨弦衰减一步");
        for (k=0;k<16;k=k+1) begin
            hold = Wn[k+1]<<16;
            case(k+1)
                1: sh=17;  2: sh=16;  3: sh=15;  4: sh=15;  5: sh=14;
                6: sh=14;  7: sh=13;  8: sh=13;  9: sh=13; 10: sh=12;
               11: sh=12; 12: sh=12; 13: sh=11; 14: sh=11; 15: sh=11;
              default: sh=11;
            endcase
            exp_x = hold - ((hold>>sh) | 1);
            check(u_dut.henv_mem[k], exp_x, "decay");
        end

        // ================= 3) 拉弦混音总校验 =================
        mode = 1'b1;
        frame;                              // 拉弦第 1 帧：写入满幅（输出用旧值）
        frame;                              // 拉弦第 2 帧：输出即为满幅结果

        // 逐条手算 16 泛音
        vacc_exp = 0;
        for (n=1;n<=16;n=n+1) begin
            case((n*1024) & 4095)
                1024:    sn =  16'sd32767;
                3072:    sn = -16'sd32767;
                default: sn =  16'sd0;
            endcase
            vacc_exp = vacc_exp + (($signed(sn) * Wn[n]) >>> 15);
        end
        sum_exp = ($signed({32'd0,vacc_exp[31:0]}) * 64'sd32767) >>> 9;
        mix_exp = (sum_exp * 64'sd32767) >>> 15;

        $display("[3] 拉弦：vw_arr[0]=%0d (exp %0d)  mix=%0d (exp %0d)",
                 u_dut.vw_arr[0], vacc_exp, mix, mix_exp);
        check(u_dut.vw_arr[0], vacc_exp, "vw");
        check(mix, mix_exp, "mix");

        // ---- 3a) 其余声部相位为 0：各声部波形必须为 0（跨声部相位泄漏会立刻暴露）----
        $display("[3a] 相位隔离：其余 31 个声部 vw_arr 必须全 0");
        for (q=1;q<32;q=q+1) check(u_dut.vw_arr[q], 0, "vw_rest");

        // ================= 3b) 声部 2 单独有相位：块首条目必须取 phase[2] =================
        //   phase 全清、仅 phase_mem[2]=0xC0000000（= -2^30 mod 2^32，正弦表奇对称 ->
        //   地址取负），期望 vw_arr[2] = 逐项手算值，其余声部波形全 0。
        //   若读地址只前瞻 1 拍，块首条目会取到 phase[1]=0，整块地址被污染，必 FAIL。
        for (q=0;q<32;q=q+1) u_dut.phase_mem[q] = 32'd0;
        u_dut.phase_mem[2] = 32'hC0000000;
        frame; frame;
        vw2_exp = 0;
        for (n=1;n<=16;n=n+1) begin
            case(((((n * 64'hC0000000) & 64'hFFFF_FFFF) >> 20) & 64'hFFF))
                64'd1024: sn =  16'sd32767;
                64'd3072: sn = -16'sd32767;
                default:  sn =  16'sd0;
            endcase
            vw2_exp = vw2_exp + (($signed(sn) * Wn[n]) >>> 15);
        end
        $display("[3b] 声部2 隔离（phase=-2^30）：vw_arr[2]=%0d (exp %0d)",
                 u_dut.vw_arr[2], vw2_exp);
        check(u_dut.vw_arr[2], vw2_exp, "vw v2");
        for (q=0;q<32;q=q+1) if (q!=2) check(u_dut.vw_arr[q], 0, "vw2_rest");

        // ================= 3c) 声部 7 = D11 测试音键（引擎级保证） =================
        //   仅 phase_mem[7]=0x40000000、env_mem[7]=32767（env_mem[0] 清零），note_on
        //   给 bit7 单拍脉冲（同 D11 按下时顶层产生的 note_on）。期望：
        //   vw_arr[7]==13236（= 测试 3 的声部 0 结果）、其余 vw 全 0、mix==测试 3 的 mix_exp。
        for (q=0;q<32;q=q+1) u_dut.phase_mem[q] = 32'd0;
        u_dut.phase_mem[7] = 32'h40000000;
        u_dut.env_mem[0] = 16'd0;
        u_dut.env_mem[7] = 16'd32767;
        @(posedge clk); note_on = (32'd1 << 7); sample_en = 1'b1;
        @(posedge clk); sample_en = 1'b0; note_on = 32'd0;
        repeat(700) @(posedge clk);
        frame;                                // 第二帧：输出满幅结果
        $display("[3c] D11 声部7：vw_arr[7]=%0d (exp %0d)  mix=%0d (exp %0d)",
                 u_dut.vw_arr[7], vacc_exp, mix, mix_exp);
        check(u_dut.vw_arr[7], vacc_exp, "vw v7 D11");
        for (q=0;q<32;q=q+1) if (q!=7) check(u_dut.vw_arr[q], 0, "vw7_rest");
        check(mix, mix_exp, "mix D11");
        if (mix === 24'sd0) begin
            $display("  FAIL mix D11: 输出为 0（测试键无声）");
            errs = errs + 1;
        end

        // ================= 4) 相位串行 TDM 更新：每路 += 自己的 inc =================
        //   帧内用 1 个共享加法器串行 RMW 32 路；给 32 个声部各一个"互不相同、
        //   高位也各不相同"的步长，逐一核对 —— 3 级流水 mux 的位序/地址错位
        //   （把别路的步长写到本路）会在某一路上立刻暴露。
        mode    = 1'b0;
        inc_all = 1024'd0;
        for (q=0;q<32;q=q+1)
            inc_all[32*q +: 32] = 32'h00200000 + q*32'h00011111;
        for (q=0;q<32;q=q+1) pbo[q] = u_dut.phase_mem[q];
        frame;
        $display("[4] 相位串行 TDM 更新（32 路各自步进）");
        for (q=0;q<32;q=q+1)
            check(u_dut.phase_mem[q], pbo[q] + (32'h00200000 + q*32'h00011111), "phase step");
        inc_all = 1024'd0;

        if (errs == 0) $display("RESULT: ALL PASS");
        else           $display("RESULT: %0d FAILURES", errs);
        $finish;
    end

endmodule