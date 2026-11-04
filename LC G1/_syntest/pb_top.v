// 隔离复现用顶层：只保留 pitch_bank8 及其顶层用法（base_all 由 mode 常量选择）
module pb_top (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         scan_done,
    input  wire [95:0]  code_all,
    input  wire         mode,
    input  wire         slide_en,
    output reg  [255:0] inc_o
);
    localparam [31:0] PLK0 = 32'd8333333,  BOW0 = 32'd8000000;
    localparam [31:0] PLK1 = 32'd9250000,  BOW1 = 32'd8990000;
    localparam [31:0] PLK2 = 32'd10400000, BOW2 = 32'd10090000;
    localparam [31:0] PLK3 = 32'd11020000, BOW3 = 32'd10690000;
    localparam [31:0] PLK4 = 32'd12370000, BOW4 = 32'd12000000;
    localparam [31:0] PLK5 = 32'd13890000, BOW5 = 32'd13470000;
    localparam [31:0] PLK6 = 32'd15600000, BOW6 = 32'd15130000;
    localparam [31:0] PLK7 = 32'd17500000, BOW7 = 32'd16980000;

    wire [31:0] b0 = mode ? BOW0 : PLK0;
    wire [31:0] b1 = mode ? BOW1 : PLK1;
    wire [31:0] b2 = mode ? BOW2 : PLK2;
    wire [31:0] b3 = mode ? BOW3 : PLK3;
    wire [31:0] b4 = mode ? BOW4 : PLK4;
    wire [31:0] b5 = mode ? BOW5 : PLK5;
    wire [31:0] b6 = mode ? BOW6 : PLK6;
    wire [31:0] b7 = mode ? BOW7 : PLK7;
    wire [255:0] inc_base_all = {b7, b6, b5, b4, b3, b2, b1, b0};

    wire [255:0] inc_all;
    pitch_bank8 u_pitch (
        .clk(clk), .rst_n(rst_n), .scan_done(scan_done),
        .code_all(code_all), .base_all(inc_base_all), .inc_all(inc_all));

    // 模拟顶层用法：inc_all 参与选择后再寄存输出
    wire [31:0] inc_u0 = (mode & slide_en) ? inc_all[31:0] : b0;
    wire [255:0] inc_unmod = {inc_all[255:224], inc_all[223:192], inc_all[191:160],
                              inc_all[159:128], inc_all[127:96], inc_all[95:64],
                              inc_all[63:32], inc_u0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) inc_o <= 256'd0;
        else        inc_o <= inc_unmod;
    end
endmodule