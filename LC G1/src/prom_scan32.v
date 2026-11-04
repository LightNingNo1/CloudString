// ============================================================================
// prom_scan32.v - 32 路地址分时复用 1 个 pROM 的扫描器
// ----------------------------------------------------------------------------
// 32 路 = 8 根弦 × 每弦 4 个分音。本模块只做"轮询调度 + 数据广播"，不含 pROM
// 本体（pROM 在顶层统一例化，见 tone_gen_top.v）。
//
// 每槽 5 拍：
//   拍0  slot_begin=1，被选中的弦把当前分音地址锁存到 rom_addr
//   拍1~2 地址保持（pROM 内部锁存/输出）
//   拍3  prom_dout 已稳定 -> 存入 data_r，拍4 置 scan_valid 广播回各弦
//   拍4  槽号 +1
// 32 槽共 160 拍，仍远小于采样周期 1152 拍，扫完即停（run=0）等下一个 sample_en。
//
// 关键点：slot_begin/scan_valid 期间 slot 不递增，所以 scan_str/scan_part 在
//         锁存地址时和取数时指向同一个槽，各弦不会串数据。
// ============================================================================
module prom_scan32 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_en,
    // 8 根弦已锁存的地址，{str7,...,str0}，每弦 12bit
    input  wire [95:0] str_addr_all,
    // 共享 pROM 接口（pROM 本体在顶层）
    input  wire [15:0] prom_dout,
    output wire [11:0] prom_addr,
    // 广播回 8 根弦
    output wire [2:0]  scan_str,
    output wire [1:0]  scan_part,
    output wire        slot_begin,
    output wire        scan_valid,
    output wire [15:0] scan_data
);
    localparam [4:0] LAST_SLOT = 5'd31;

    reg  [4:0]  slot;      // 0..31
    reg  [2:0]  ph;        // 0..4 单槽内相位
    reg         run;       // 本轮扫描进行中
    reg  [15:0] data_r;    // 取回的 LUT 采样
    reg         valid_r;   // data_r 有效

    wire [2:0] cur_s = slot[4:2];   // 弦号 0..7
    wire [1:0] cur_p = slot[1:0];   // 分音号 0..3

    // 8 选 1：把被选中弦的地址送到共享 pROM
    reg [11:0] addr_mux;
    always @(*) begin
        case (cur_s)
        3'd0:    addr_mux = str_addr_all[11:0];
        3'd1:    addr_mux = str_addr_all[23:12];
        3'd2:    addr_mux = str_addr_all[35:24];
        3'd3:    addr_mux = str_addr_all[47:36];
        3'd4:    addr_mux = str_addr_all[59:48];
        3'd5:    addr_mux = str_addr_all[71:60];
        3'd6:    addr_mux = str_addr_all[83:72];
        default: addr_mux = str_addr_all[95:84];
        endcase
    end

    assign prom_addr  = addr_mux;
    assign scan_str   = cur_s;
    assign scan_part  = cur_p;
    assign slot_begin = run && (ph == 3'd0);
    assign scan_valid = valid_r;
    assign scan_data  = data_r;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            slot   <= 5'd0;
            ph     <= 3'd0;
            run    <= 1'b0;
            data_r <= 16'd0;
            valid_r<= 1'b0;
        end else if(sample_en) begin        // 每个采样点重新开一轮扫描
            slot    <= 5'd0;
            ph      <= 3'd0;
            run     <= 1'b1;
            valid_r <= 1'b0;
        end else if(run) begin
            valid_r <= 1'b0;
            case(ph)
            3'd0: ph <= 3'd1;
            3'd1: ph <= 3'd2;
            3'd2: ph <= 3'd3;
            3'd3: begin
                data_r  <= prom_dout;       // 地址已稳定 3 拍，取数
                valid_r <= 1'b1;            // 下一拍广播给各弦
                ph      <= 3'd4;
            end
            3'd4: begin
                if(slot == LAST_SLOT) begin // 32 槽扫完，停到下一个 sample_en
                    slot <= 5'd0;
                    run  <= 1'b0;
                end else begin
                    slot <= slot + 1'b1;
                end
                ph <= 3'd0;
            end
            default: ph <= 3'd0;
            endcase
        end
    end
endmodule
