// 隔离复现 NL0002：纯组合叶子模块被展开
module ld_top (
    input  wire [15:0] e0, e1, e2, e3, e4, e5,
    input  wire        play_en,
    input  wire [5:0]  guide,
    output wire [5:0]  led
);
    wire [5:0] led_env;
    (* syn_noprune = 1 *) led_driver u_led (
        .env0(e0), .env1(e1), .env2(e2),
        .env3(e3), .env4(e4), .env5(e5), .led(led_env));
    assign led = play_en ? ~guide : led_env;
endmodule