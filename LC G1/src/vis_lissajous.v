// ============================================================================
// vis_lissajous.v - 任选两根弦波形的李萨如图（X=弦A, Y=弦B）
// ----------------------------------------------------------------------------
// 位图 256×256bit × 2 bank（8 片 512×32 真双口 RAM = DPB 拼成，共 128Kbit）：
//   A 口(clk)：帧初整片清零，随后在 512 个采样点上做"读-改-写"打点；
//   B 口(pclk)：屏幕扫描时按行读出整行 256bit，再按列选 1bit。
//
// 【为什么改成 256×256】原 128×128 位图在屏上要 2 倍最近邻放大，斜线会呈现
//   2×2 的方块台阶（肉眼看到的"锯齿"）。改成 256×256、屏幕上 1 位图点 = 1 像素
//   （x112..367 / y8..263），斜线不再有台阶。
//
// 双缓冲：每帧 start 时翻转 wbank，清零+打点写入新 bank，像素侧始终读
//   上一帧已完成的 bank（rbank = ~wbank 同步到 pclk）。
//
// 一帧时序（start 由 lcd 在帧消隐期发出，画完约 12.1ms < 一帧 16.3ms）：
//   CLEAR 256 拍 -> 每来一个 sample_en 采一个样点，相邻样点间做 32 段线性
//   插值（除以 32 用算术右移，无乘法器），每个插值点一次读-改-写。
//   单点 3 拍 × 32 = 96 拍，远小于一个采样间隔。
//
// 坐标：弦波是 vis_pair_src 输出的正弦（满幅 ±127，已做表内线性插值，量化误差 <1），
//   直接限幅 ±127 后 +128 落到 1..255，256×256 位图 1:1 铺满（量化台阶 = 1 像素）。
//
// 读流水：py/px 给出后 2 个 pclk 像素有效（T0 行地址 -> T1 行数据+锁列号
//   -> T2 选中像素），lcd 顶层的几何坐标按 2 拍延迟对齐。
// ============================================================================

// 单页 512×32 真双口 RAM（{bank,行} 寻址）：
//   A 口可读可写（音频侧读改写），B 口只读（像素侧）
module vis_lis_ram (
    input  wire        clka,
    input  wire        wea,
    input  wire [8:0]  aa,        // {wbank, row}
    input  wire [31:0] da,
    output reg  [31:0] qa,
    input  wire        clkb,
    input  wire [8:0]  ab,        // {rbank, row}
    output reg  [31:0] qb
);
    reg [31:0] mem [0:511];
    always @(posedge clka) begin
        if (wea)
            mem[aa] <= da;          // 写周期 qa 保持（Normal 模式），
        else                        // DPB 硬件不支持写穿透(WRITE_MODE=10)
            qa <= mem[aa];
    end
    always @(posedge clkb)
        qb <= mem[ab];
endmodule

module vis_lissajous (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_en,
    input  wire               start,      // 帧采集启动（clk 域单周期脉冲）
    input  wire signed [15:0] a,          // X 轴弦波
    input  wire signed [15:0] b,          // Y 轴弦波
    input  wire               pclk,
    input  wire [7:0]         px,         // 位图列 0..255
    input  wire [7:0]         py,         // 位图行 0..255
    output reg                pixel       // 2 拍 pclk 流水
);
    localparam [2:0] L_IDLE = 3'd0, L_CLR = 3'd1, L_WAIT = 3'd2,
                     L_RD = 3'd3, L_WR = 3'd4, L_STEP = 3'd5;
    localparam [9:0] NPTS  = 10'd512;     // 一帧采样点数（×32 插值 = 16384 打点）

    reg [2:0]  st;
    reg [8:0]  ci;         // 清零行地址（{bank,row} 直接用）
    reg [9:0]  cnt;        // 已采样点数
    reg [7:0]  aa_r;       // A 口行地址（清零/读改写共用，只取 row）
    reg        wbank;      // 当前帧写入 bank
    reg [7:0]  we_a;       // 8 页写使能（独热）
    reg [31:0] da_r;

    reg signed [15:0] ax, ay;
    reg [7:0]  cx_r, cy_r;  // 前一样点坐标（插值线段起点）
    reg [7:0]  cx_n, cy_n;  // 本样点坐标（插值线段终点）
    reg [7:0]  cx_p, cy_p;  // 当前待打插值点
    reg signed [8:0]  dx_r, dy_r;    // 样点间坐标差（±255 以内）
    reg signed [13:0] acc_x, acc_y;  // 插值累加器（最大 32×255=8160）
    reg [4:0]  sub_cnt;              // 插值点序号 0..31

    // ---- 坐标：SIN64 满幅 ±127，直接限幅 ±127，+128 -> 1..255 ----
    wire signed [9:0] avc = (ax > 10'sd127) ? 10'sd127 :
                            (ax < -10'sd127) ? -10'sd127 : ax;
    wire signed [9:0] bvc = (ay > 10'sd127) ? 10'sd127 :
                            (ay < -10'sd127) ? -10'sd127 : ay;
    // 先+128再做截断（低 8 位），避免负数直接取低位绕回高位。
    wire signed [9:0] avc_off = avc + 10'sd128;
    wire signed [9:0] bvc_off = bvc + 10'sd128;
    wire [7:0] cxw = avc_off[7:0];
    wire [7:0] cyw = bvc_off[7:0];

    // A 口完整地址 = {写 bank, 行}
    wire [8:0] aa_full = {wbank, aa_r};

    // ---- 8 页 RAM（列 0..31 / 32..63 / ... / 224..255），每页双 bank ----
    wire [31:0] qa0, qa1, qa2, qa3, qa4, qa5, qa6, qa7;
    wire [31:0] qb0, qb1, qb2, qb3, qb4, qb5, qb6, qb7;
    wire [8:0]  rb_row;                  // {rbank, py}，见 B 口同步
    vis_lis_ram u_r0 (.clka(clk), .wea(we_a[0]), .aa(aa_full), .da(da_r), .qa(qa0),
                      .clkb(pclk), .ab(rb_row), .qb(qb0));
    vis_lis_ram u_r1 (.clka(clk), .wea(we_a[1]), .aa(aa_full), .da(da_r), .qa(qa1),
                      .clkb(pclk), .ab(rb_row), .qb(qb1));
    vis_lis_ram u_r2 (.clka(clk), .wea(we_a[2]), .aa(aa_full), .da(da_r), .qa(qa2),
                      .clkb(pclk), .ab(rb_row), .qb(qb2));
    vis_lis_ram u_r3 (.clka(clk), .wea(we_a[3]), .aa(aa_full), .da(da_r), .qa(qa3),
                      .clkb(pclk), .ab(rb_row), .qb(qb3));
    vis_lis_ram u_r4 (.clka(clk), .wea(we_a[4]), .aa(aa_full), .da(da_r), .qa(qa4),
                      .clkb(pclk), .ab(rb_row), .qb(qb4));
    vis_lis_ram u_r5 (.clka(clk), .wea(we_a[5]), .aa(aa_full), .da(da_r), .qa(qa5),
                      .clkb(pclk), .ab(rb_row), .qb(qb5));
    vis_lis_ram u_r6 (.clka(clk), .wea(we_a[6]), .aa(aa_full), .da(da_r), .qa(qa6),
                      .clkb(pclk), .ab(rb_row), .qb(qb6));
    vis_lis_ram u_r7 (.clka(clk), .wea(we_a[7]), .aa(aa_full), .da(da_r), .qa(qa7),
                      .clkb(pclk), .ab(rb_row), .qb(qb7));

    reg [31:0] qa_sel;
    always @(*) begin
        case (cx_p[7:5])
        3'd0:    qa_sel = qa0;
        3'd1:    qa_sel = qa1;
        3'd2:    qa_sel = qa2;
        3'd3:    qa_sel = qa3;
        3'd4:    qa_sel = qa4;
        3'd5:    qa_sel = qa5;
        3'd6:    qa_sel = qa6;
        default: qa_sel = qa7;
        endcase
    end

    // ---- 32 段线性插值：第 i 点 = 起点 + (dx·i)/32，累加+算术右移，无乘法器 ----
    wire signed [13:0] acc_x_n = acc_x + {{5{dx_r[8]}}, dx_r};
    wire signed [13:0] acc_y_n = acc_y + {{5{dy_r[8]}}, dy_r};
    wire signed [13:0] sh_x    = acc_x_n >>> 5;
    wire signed [13:0] sh_y    = acc_y_n >>> 5;
    // 起点 + 偏移，全程有符号计算；插值点必须钳位到 0..255，
    // 防止截断折叠（例如 258 -> 2）在边界形成假线。
    wire signed [13:0] tx_s = $signed({6'd0, cx_r}) + sh_x;
    wire signed [13:0] ty_s = $signed({6'd0, cy_r}) + sh_y;
    wire [7:0] tx_w = (tx_s > 14'sd255) ? 8'd255 :
                      (tx_s < 14'sd0)   ? 8'd0   : tx_s[7:0];
    wire [7:0] ty_w = (ty_s > 14'sd255) ? 8'd255 :
                      (ty_s < 14'sd0)   ? 8'd0   : ty_s[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= L_IDLE;
            ci    <= 9'd0;
            cnt   <= 10'd0;
            aa_r  <= 8'd0;
            wbank <= 1'b0;
            we_a  <= 8'h00;
            da_r  <= 32'd0;
            ax    <= 16'sd0;
            ay    <= 16'sd0;
            cx_r  <= 8'd128;
            cy_r  <= 8'd128;
            cx_n  <= 8'd128;
            cy_n  <= 8'd128;
            cx_p  <= 8'd128;
            cy_p  <= 8'd128;
            dx_r  <= 9'sd0;
            dy_r  <= 9'sd0;
            acc_x <= 14'sd0;
            acc_y <= 14'sd0;
            sub_cnt <= 5'd0;
        end else begin
            we_a <= 8'h00;
            case (st)
            L_IDLE:
                if (start) begin
                    wbank <= ~wbank;    // 新帧写另一个 bank
                    ci    <= 9'd0;
                    st    <= L_CLR;
                end

            L_CLR: begin
                    aa_r <= ci[7:0];
                    da_r <= 32'd0;
                    we_a <= 8'hFF;              // 8 页同行清零
                    if (ci == 9'd255) begin
                        cnt   <= 10'd0;
                        cx_r  <= 8'd128;        // 第一帧起点放中心
                        cy_r  <= 8'd128;
                        acc_x <= 14'sd0;
                        acc_y <= 14'sd0;
                        sub_cnt <= 5'd0;
                        st    <= L_WAIT;
                    end else begin
                        ci <= ci + 9'd1;
                    end
                end

            L_WAIT:
                if (sample_en) begin
                    ax   <= a;
                    ay   <= b;
                    cx_n <= cxw;
                    cy_n <= cyw;
                    if (cnt == 10'd0) begin
                        // 每帧第一个采样点：cx_n 还是上一帧残留值，
                        // 强制线段起终点都为当前点（插值点重合），
                        // 否则会从上帧末点画一条横贯位图的线。
                        cx_r <= cxw;
                        cy_r <= cyw;
                        cx_p <= cxw;
                        cy_p <= cyw;
                        aa_r <= cyw;
                        dx_r <= 9'sd0;
                        dy_r <= 9'sd0;
                    end else begin
                        // 锁存上一采样点（线段起点）和本采样点（线段终点）
                        cx_r <= cx_n;
                        cy_r <= cy_n;
                        cx_p <= cx_n;       // 先打线段起点（i=0）
                        cy_p <= cy_n;
                        aa_r <= cy_n;       // 下一拍按 Y 行读
                        // 坐标差（有符号 9bit，范围 ±255）
                        dx_r <= $signed({1'b0, cxw}) - $signed({1'b0, cx_n});
                        dy_r <= $signed({1'b0, cyw}) - $signed({1'b0, cy_n});
                    end
                    acc_x <= 14'sd0;
                    acc_y <= 14'sd0;
                    sub_cnt <= 5'd0;
                    st   <= L_RD;
                end

            L_RD:
                st <= L_WR;                    // qa_sel 此时已稳定

            L_WR: begin
                    aa_r <= cy_p;
                    da_r <= qa_sel | (32'd1 << cx_p[4:0]);
                    we_a <= 8'h01 << cx_p[7:5]; // 只回写该点所在的页
                    if (sub_cnt == 5'd31) begin // 32 段插值完成
                        if (cnt == NPTS - 10'd1)
                            st <= L_IDLE;
                        else begin
                            cnt <= cnt + 10'd1;
                            st  <= L_WAIT;
                        end
                    end else begin
                        st <= L_STEP;
                    end
                end

            L_STEP: begin                      // 计算下一个插值点
                    acc_x <= acc_x_n;
                    acc_y <= acc_y_n;
                    cx_p  <= tx_w;
                    cy_p  <= ty_w;
                    aa_r  <= ty_w;             // 预置行地址（下一拍 L_RD 用）
                    sub_cnt <= sub_cnt + 5'd1;
                    st    <= L_RD;
                end

            default: st <= L_IDLE;
            endcase
        end
    end

    // ---- B 口：读 bank 同步到 pclk，行地址拼 {rbank, py} ----
    reg rb_s1, rb_s2;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            rb_s1 <= 1'b0;
            rb_s2 <= 1'b0;
        end else begin
            rb_s1 <= ~wbank;            // 像素侧读上一帧完成的 bank
            rb_s2 <= rb_s1;
        end
    end
    assign rb_row = {rb_s2, py};

    // ---- B 口读流水：T1 锁列选择，T2 输出像素 ----
    reg [2:0]  qsel;
    reg [4:0]  qbit;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            qsel  <= 3'd0;
            qbit  <= 5'd0;
            pixel <= 1'b0;
        end else begin
            qsel  <= px[7:5];
            qbit  <= px[4:0];
            case (qsel)
            3'd0:    pixel <= qb0[qbit];
            3'd1:    pixel <= qb1[qbit];
            3'd2:    pixel <= qb2[qbit];
            3'd3:    pixel <= qb3[qbit];
            3'd4:    pixel <= qb4[qbit];
            3'd5:    pixel <= qb5[qbit];
            3'd6:    pixel <= qb6[qbit];
            default: pixel <= qb7[qbit];
            endcase
        end
    end
endmodule
