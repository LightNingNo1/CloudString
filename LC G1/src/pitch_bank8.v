// ============================================================================
// pitch_bank8.v - 八路电压码 -> 八个基波相位步长（共享一个 pitch_map）
// ----------------------------------------------------------------------------
// 每路的"当前定弦基频步长"由顶层在 base_all 里按模式给出（拨弦 PLK / 拉弦 BOW），
// 因此同一份 ADC 滑音压控可以作用在两种定弦上，不需要改本模块。
// ADC 电压映射为比例因子 ratio = 2^(code/2048)，范围 1.0~4.0：
//   code = 0 (0V) -> 1.0（该弦定弦音）... code = 4095 (VA) -> ~4.0（定弦 +2 八度）
// 即滑音区间 = 该弦定弦音高 ~ 向上两个八度（只升不降）。
// 最终 inc_k = (base_k * ratio) >> 16。
// base_k 按 fs = 21.7014kHz 的十二平均律给出（fs 由 50MHz 经 i2s_tx 分频得到）。
//
// 注：顶层只用 ch0~ch5 驱动弦0~弦5 的滑音（ch6=总音量、ch7=丢弃），
//     ch6/ch7 的输出 inc6/inc7 由顶层忽略。
//
// 【综合约束（重要）】Gowin 工艺映射会把本模块报成"逻辑环"
//   （WARN AG0101 "netlist is not one directed acyclic graph" + 上百条
//    AG0100 "Find logical loop signal : inc0[n]"）。实测（隔离工程二分）确认根因是：
//   Gowin 的寄存器只有"异步清零/置位到常量"，没有"异步装载任意数据"。若在
//       always @(posedge clk or negedge rst_n) ... inc0 <= base_all[31:0];
//   里用异步复位去装载非恒定值 base_all，工具只能拼出 rst_n 参与的组合结构，
//   随后被误判成自环（与乘法器、位宽、读写方式都无关）。
//   解决办法：本块的复位改为"同步复位"——always @(posedge clk) + if(!rst_n)，
//   复位值仍可照常取 base_all（同步装载只是普通组合逻辑）。
//   实测：改成同步复位后 AG0100/AG0101 由 344 条降为 0 条。
//   另：八个输出寄存器用独立标量 inc0..inc7，不用 reg 数组、不做变址读写，
//   对工具更友好（本模块的 8 路输出本来也不需要数组语义）。
// ============================================================================
module pitch_bank8 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         scan_done,
    input  wire [95:0]  code_all,      // {ch7,...,ch0}
    input  wire [255:0] base_all,      // 各弦当前定弦基频步长，base_all[32*k +: 32]
    output wire [255:0] inc_all        // 每路 32bit 相位步长
);
    localparam [1:0] S_IDLE  = 2'd0,
                     S_LATCH = 2'd1,
                     S_REQ   = 2'd2,
                     S_WAIT  = 2'd3;

    reg  [1:0] st;
    reg  [2:0] idx;          // 通道号 0..7
    reg        vin;

    // ---- 当前通道的 ADC 码 / 定弦基频：用 case 做组合多路选择（全是常量位段）----
    reg  [11:0] code_sel;
    reg  [31:0] base_sel;
    always @(*) begin
        case (idx)
        3'd0: begin code_sel = code_all[11:0];    base_sel = base_all[31:0];    end
        3'd1: begin code_sel = code_all[23:12];   base_sel = base_all[63:32];   end
        3'd2: begin code_sel = code_all[35:24];   base_sel = base_all[95:64];   end
        3'd3: begin code_sel = code_all[47:36];   base_sel = base_all[127:96];  end
        3'd4: begin code_sel = code_all[59:48];   base_sel = base_all[159:128]; end
        3'd5: begin code_sel = code_all[71:60];   base_sel = base_all[191:160]; end
        3'd6: begin code_sel = code_all[83:72];   base_sel = base_all[223:192]; end
        default: begin code_sel = code_all[95:84]; base_sel = base_all[255:224]; end
        endcase
    end

    // ---- 锁存成标量：后续乘法与写回都不再依赖 idx ----
    reg  [11:0] code_lat;
    reg  [31:0] base_lat;
    reg  [2:0]  idx_lat;

    wire        vout;
    wire [31:0] ratio;       // 16.16 定点比例因子

    pitch_map u_map (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (vin),
        .code      (code_lat),
        .valid_out (vout),
        .ratio     (ratio)
    );

    // inc = (base_lat * ratio) >> 16
    // base_lat 最大 ~52M (26bit, C5)，ratio 最大 ~262144 (18bit, +2 八度)，乘积 44bit
    // （pitch_map 输出的 ratio 恒 >= 1.0，所以滑音只会把音高往上推）
    wire [63:0] prod    = base_lat * ratio;
    wire [31:0] inc_val = prod[47:16];

    // ---- 八个独立标量寄存器（不用 reg 数组、不做变址读写）----
    reg [31:0] inc0, inc1, inc2, inc3, inc4, inc5, inc6, inc7;

    // 【同步复位】不能用 always @(posedge clk or negedge rst_n)：异步复位装载
    // 非常量 base_all 会被 Gowin 误判成逻辑环（见文件头说明）。此处复位是同步的。
    always @(posedge clk) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            idx      <= 3'd0;
            vin      <= 1'b0;
            code_lat <= 12'd0;
            base_lat <= 32'd0;
            idx_lat  <= 3'd0;
            // 上电默认 = 各弦定弦基频（ratio = 1.0）
            inc0 <= base_all[31:0];
            inc1 <= base_all[63:32];
            inc2 <= base_all[95:64];
            inc3 <= base_all[127:96];
            inc4 <= base_all[159:128];
            inc5 <= base_all[191:160];
            inc6 <= base_all[223:192];
            inc7 <= base_all[255:224];
        end else begin
            vin <= 1'b0;
            case (st)
            S_IDLE: begin
                if (scan_done) begin idx <= 3'd0; st <= S_LATCH; end
            end
            // 把本通道的码/基频锁存成标量，之后整条运算链与 idx 无关
            S_LATCH: begin
                code_lat <= code_sel;
                base_lat <= base_sel;
                idx_lat  <= idx;
                st       <= S_REQ;
            end
            // 启动 pitch_map（3 拍流水）
            S_REQ: begin
                vin <= 1'b1;
                st  <= S_WAIT;
            end
            // 等 ratio 有效后按锁存下来的通道号写回（常量下标逐个赋值）
            S_WAIT: begin
                if (vout) begin
                    case (idx_lat)
                    3'd0:    inc0 <= inc_val;
                    3'd1:    inc1 <= inc_val;
                    3'd2:    inc2 <= inc_val;
                    3'd3:    inc3 <= inc_val;
                    3'd4:    inc4 <= inc_val;
                    3'd5:    inc5 <= inc_val;
                    3'd6:    inc6 <= inc_val;
                    default: inc7 <= inc_val;
                    endcase
                    if (idx_lat == 3'd7) st <= S_IDLE;
                    else begin idx <= idx_lat + 1'b1; st <= S_LATCH; end
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    assign inc_all = {inc7, inc6, inc5, inc4, inc3, inc2, inc1, inc0};

endmodule