// 按键消抖模块【适配Tang Nano20K板载按键：按下=低电平】
// 固定50MHz，20ms消抖，两级同步防亚稳态
module debounce(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key_in,    // Tang Nano20K板载按键：松开=1，按下=0
    output reg         key_out,   // 消抖后电平
    output reg         key_press, // 按下单周期脉冲（下降沿）
    output reg         key_release// 松开单周期脉冲（上升沿）
);
parameter CNT_MAX = 20'd1000000 - 1; // 50MHz 20ms
reg [19:0] cnt;
reg sync1, sync2;

// 两级同步
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sync1 <= 1'b1;
        sync2 <= 1'b1;
    end else begin
        sync1 <= key_in;
        sync2 <= sync1;
    end
end

// 消抖计数
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cnt <= 20'd0;
        key_out <= 1'b1;
    end else begin
        if(sync2 != key_out) begin
            cnt <= cnt + 1'b1;
            if(cnt == CNT_MAX) begin
                key_out <= sync2;
                cnt <= 20'd0;
            end
        end else begin
            cnt <= 20'd0;
        end
    end
end

// 边沿检测：按下=下降沿脉冲，松开=上升沿脉冲
reg key_q;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        key_q <= 1'b1;
        key_press <= 1'b0;
        key_release <= 1'b0;
    end else begin
        key_q <= key_out;
        key_press <= key_q & ~key_out;
        key_release <= ~key_q & key_out;
    end
end
endmodule
