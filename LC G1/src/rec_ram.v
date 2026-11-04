// ============================================================================
// rec_ram.v - 用户弹奏录制的存储（256 事件槽，分布式 LUT RAM 实现）
// ----------------------------------------------------------------------------
// 事件格式与 song_ram.v 的下载曲目完全一致（24 位，最多 2 音混音）：
//   [23:22] cnt1 = 目标音数-1（00=1 音、01=2 音）
//   [21:17] n0、[16:12] n1：目标弦号 0..31
//   [11:0]  时值（10ms 单位；0 = 曲终标记）
// 地址 [7:0]，深度 256：最多 255 个真实事件 + 1 个曲终标记。
//
// 用分布式 LUT RAM 实现（不用 BRAM），占用 ~384 个 LUT，
// 好处：布局器可以把 RAM 放在 ble_link / song_recorder 附近，
//       减少长距离走线，避免 BRAM 位置固定导致的布线拥塞。
// ============================================================================
module rec_ram (
    input  wire        clk,
    input  wire        we,
    input  wire [7:0]  waddr,
    input  wire [23:0] wdata,
    input  wire [7:0]  raddr,
    output reg  [23:0] rdata
);
    (* syn_ramstyle = "select_ram" *)   // 提示综合器用分布式 LUT RAM，不用 BRAM
    reg [23:0] mem [0:255];
    integer i;

    initial begin
        for (i = 0; i < 256; i = i + 1)
            mem[i] = 24'h000000;
    end

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
