// ============================================================================
// vibrato.v - 32 声部统一颤音调制（三角波 LFO + 深度平滑 + 共享串行乘法器）
// ----------------------------------------------------------------------------
// 调制必须是"相对频偏"（百分比），否则高音声部的颤音会变小：
//     inc_mod = inc_base × (1 + dsig/65536) = inc_base ± inc_base[31:16] × |dsig|
// 其中 inc_base[31:16] 就是 inc_base / 65536（相对精度 2^-16，足够）；
// 32 个声部共用同一个 dsig，于是颤音深度在任何音高上都一致（约 ±2.9% ≈ ±50 音分）。
//
// 资源：不例化并行乘法器，改用 1 个共享的"移位-相加"串行乘法器：
//       每声部 16 拍，32 声部共约 512 拍 << 采样周期 1250 拍（120MHz/96kHz），纯 LUT 实现。
//
// 时序：在 sample_en 那一拍同时锁存 32 路 inc_base（base_r）与调制量 dsig（dsig_lat），
//       保证所有声部用的是同一份快照；延时 200 拍后启动小状态机（见 vdly），
//       避开引擎帧头 S_PH 对 out_r 的读窗口。结果写回 inc_out，引擎在下一帧读取，
//       等效只有 1 个采样点（10.4us）的延迟，对 ~5.5Hz 的颤音无影响。
//
// LFO：32bit 相位累加器，用最高位判上下坡、次高 8 位做斜坡，折叠成 256 级三角波：
//      f_lfo = LFO_INC × fs / 2^32 = 246065 × 96000 / 2^32 ≈ 5.50 Hz
// 深度平滑：dep_filt 是 Q4 的"深度系数"（0..depth×16），每 2 个采样点走 1 步，
//      满档 0->240 约 5.5ms 爬升，按住/松开开关时音高不会台阶跳变。
// ============================================================================
module vibrato #(
    parameter [31:0] LFO_INC = 32'd246065      // ≈ 5.50 Hz @ fs=96kHz（f = INC × fs / 2^32）
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              sample_en,
    input  wire              vib_en,      // 按住编码器轴开关
    input  wire [3:0]        depth,       // 颤音深度 0..15
    input  wire [1023:0]     inc_in,      // {v31..v0} 未调制基波步长
    output wire [1023:0]     inc_out      // {v31..v0} 已调制基波步长
);

    // ---------------- LFO：256 级三角波，中心 0，范围 -128..+127 ----------------
    reg [31:0] lfo_acc;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)           lfo_acc <= 32'd0;
        else if(sample_en)   lfo_acc <= lfo_acc + LFO_INC;
    end

    wire [7:0]  ltri = lfo_acc[31] ? (8'd255 - lfo_acc[30:23]) : lfo_acc[30:23];
    wire signed [8:0] lfo = $signed({1'b0, ltri}) - $signed(9'sd128);

    // ---------------- 深度系数一阶平滑（Q4：0..depth×16） ----------------
    // fs=96kHz 下每 2 个采样点走 1 步，保持满档爬升约 5.5ms 与 48kHz 版一致
    reg [7:0] dep_filt;
    reg       dep_ph;
    wire [7:0] dep_tgt = vib_en ? {depth, 4'b0000} : 8'd0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            dep_filt <= 8'd0;
            dep_ph   <= 1'b0;
        end else if(sample_en) begin
            dep_ph <= ~dep_ph;
            if(dep_ph) begin
                if(dep_filt < dep_tgt)      dep_filt <= dep_filt + 8'd1;
                else if(dep_filt > dep_tgt) dep_filt <= dep_filt - 8'd1;
            end
        end
    end

    // ---------------- 调制量 dsig = lfo × dep_filt >>> 4 ----------------
    // 满深度：128 × 240 >>> 4 = 1920，即 ±1920/65536 ≈ ±2.93%（≈ ±50 音分）
    wire signed [16:0] dsig_p = lfo * $signed({1'b0, dep_filt});
    wire signed [12:0] dsig   = dsig_p[16:4];       // >>>4 后的 13bit 补码

    // ---------------- 32 路未调制基频（同一拍快照） ----------------
    wire [31:0] in_arr [0:31];
    genvar gk;
    generate
        for(gk=0; gk<32; gk=gk+1) begin: g_in
            assign in_arr[gk] = inc_in[32*gk +: 32];
        end
    endgenerate

    reg [31:0]        base_r [0:31];
    reg signed [12:0] dsig_lat;
    reg [31:0]        out_r  [0:31];
    integer k;

    // 【统一时钟后的启动延时】引擎与本模块同在 120MHz 域，同在帧头读/写 out_r：
    //   引擎在帧头 129 拍内（S_PH）通过 inc_all 把 out_r 读走，本模块的 TDM 写回
    //   必须排在其后，否则同一总线会被读到"半新半旧"。延时 200 拍启动后，
    //   写窗口约 214..680 拍，与引擎读窗口 1..129 拍完全错开。
    //   代价仅是调制量比引擎晚一帧生效（约 10.4µs），对 ~5.5Hz 颤音无影响。
    reg [8:0] vdly;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)            vdly <= 9'd0;
        else if(sample_en)    vdly <= 9'd200;
        else if(vdly != 9'd0) vdly <= vdly - 9'd1;
    end
    wire se_d = (vdly == 9'd1);      // 延时到期：启动本帧 TDM

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            for(k=0;k<32;k=k+1) base_r[k] <= 32'd0;
            dsig_lat <= 13'sd0;
        end else begin
            if(sample_en) begin
                for(k=0;k<32;k=k+1) base_r[k] <= in_arr[k];
                dsig_lat <= dsig;
            end
        end
    end

    // ---------------- 共享串行乘法器（每声部 12 拍移位相加） ----------------
    localparam [2:0] V_IDLE = 3'd0, V_LOAD = 3'd1, V_INIT = 3'd2, V_MUL = 3'd3,
                     V_WRC  = 3'd4, V_WR   = 3'd5;

    reg  [2:0]  vst;
    reg  [4:0]  vch;         // 声部号 0..31
    reg  [3:0]  vbit;
    reg  [27:0] vmcand;      // 被乘数：base[31:16]（≤12bit），左移 12 次
    reg  [11:0] vmplier;     // 乘数：|dsig|（≤12bit）
    reg  [27:0] vmacc;       // 积
    // 【120MHz 拆分】V_LOAD 拍就把 base_r[vch] 寄存下来（base_sel），
    //   V_WR 拍直接用它做 ±vmacc。否则"32:1 变址读 base_r[vch] + 32bit 加/减 +
    //   32:1 变址写 out_r[vch]"会挤在一拍里，约 10 级组合 -> 超 8.333ns。
    //   base_r 只在 sample_en 更新，帧内不变，故提前一拍取值等价。
    reg  [31:0] base_sel;    // 当前声部基波步长（寄存后的 base_r[vch]）
    reg  [31:0] res_r;       // V_WRC：base_sel ± vmacc 的寄存结果（32bit 加减与写译码拆开）

    wire        dl_neg = dsig_lat[12];
    wire [12:0] dl_abs = dl_neg ? (~dsig_lat + 13'd1) : dsig_lat;
    wire [11:0] dl_mag = dl_abs[11:0];

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            vst <= V_IDLE; vch <= 5'd0; vbit <= 4'd0;
            vmcand <= 28'd0; vmplier <= 12'd0; vmacc <= 28'd0;
            base_sel <= 32'd0; res_r <= 32'd0;
            for(k=0;k<32;k=k+1) out_r[k] <= 32'd0;
        end else begin
            case(vst)
            V_IDLE: if(se_d) begin
                        vch <= 5'd0;
                        vst <= V_LOAD;
                    end
            V_LOAD: begin
                        base_sel <= base_r[vch];                  // 变址读取一拍内完成
                        vmplier <= dl_mag;
                        vmacc   <= 28'd0;
                        vbit    <= 4'd0;
                        vst     <= V_INIT;
                    end
            V_INIT: begin
                        // 【120MHz 拆分】vmcand 改从已寄存的 base_sel 取高位，
                        //   不让"vch -> 32:1 变址读 base_r[vch] -> vmcand"挤在一拍
                        //   （原实测 slack -0.520ns）。base_sel 已在 V_LOAD 拍寄存，
                        //   这里只是位选，组合极短。每声部多 1 拍，32 声部共 +32 拍。
                        vmcand  <= {12'd0, base_sel[31:16]};
                        vst     <= V_MUL;
                    end
            V_MUL:  begin
                        if(vmplier[0]) vmacc <= vmacc + vmcand;
                        vmcand  <= vmcand  << 1;
                        vmplier <= vmplier >> 1;
                        if(vbit == 4'd11) vst <= V_WRC;
                        else              vbit <= vbit + 4'd1;
                    end
            // 【120MHz 拆分】V_WR 原来把"base_sel ± vmacc 的 32bit 加减"与
            //   "vch -> 32:1 写译码"挤在一拍（实测 7.7ns，为音频域最差路径）。
            //   这里插一级 V_WRC 把加减结果寄存到 res_r，V_WR 只做写回译码。
            V_WRC:  begin
                        res_r <= dl_neg ? (base_sel - vmacc)
                                        : (base_sel + vmacc);
                        vst   <= V_WR;
                    end
            V_WR:   begin
                        out_r[vch] <= res_r;
                        if(vch == 5'd31) vst <= V_IDLE;
                        else begin vch <= vch + 5'd1; vst <= V_LOAD; end
                    end
            default: vst <= V_IDLE;
            endcase
        end
    end

    wire [1023:0] out_pack;
    generate
        for(gk=0; gk<32; gk=gk+1) begin: g_out
            assign out_pack[32*gk +: 32] = out_r[gk];
        end
    endgenerate

    assign inc_out = out_pack;

endmodule