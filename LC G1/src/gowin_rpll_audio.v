//Copyright (C)2014-2022 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//说明：音频域 PLL，50MHz -> 120MHz，供 96kHz 音频合成链使用
//      （TDM 振荡器引擎 + 32 声部 ADSR + 512 泛音包络 + 混音 + I2S）
//
// 频率设计（依据 DS102 表 4-19 的 rPLL 开关特性）：
//   CLKOUT = FCLKIN × (FBDIV_SEL+1)/(IDIV_SEL+1) = 50 × 12/5 = 120.000MHz
//   PFD    = FCLKIN / (IDIV_SEL+1)               = 50 / 5    = 10.000MHz  （规内 3 ~ 500MHz）
//   VCO    = CLKOUT × ODIV_SEL                   = 120 × 8   = 960.000MHz （规内 500 ~ 1250MHz）
//   CLKOUT 120MHz 落在 3.90625 ~ 625MHz 内。
//
// 为什么是 120MHz：96kHz 要求 clk/fs 为整数拍数，且该拍数要装得下 512 个泛音的
//   TDM 扫描。120MHz/96kHz = 1250 拍/帧（整数），是 50MHz 参考下唯一既满足 PFD 下限
//   又满足帧整数的最佳解（96MHz 需 IDIV+1=25，PFD 只有 2MHz，超下限不可用）。
//
// 与 gowin_rpll.v（LCD 像素时钟 10MHz）互不影响：GW2A-18 共 4 个 rPLL，这是第 2 个。
module Gowin_rPLL_audio (clkout, lock, clkin);
output clkout;
output lock;
input  clkin;
wire clkoutp_o;
wire clkoutd_o;
wire clkoutd3_o;
wire gw_gnd;
assign gw_gnd = 1'b0;
rPLL rpll_inst (
    .CLKOUT(clkout),
    .LOCK(lock),
    .CLKOUTP(clkoutp_o),
    .CLKOUTD(clkoutd_o),
    .CLKOUTD3(clkoutd3_o),
    .RESET(gw_gnd),
    .RESET_P(gw_gnd),
    .CLKIN(clkin),
    .CLKFB(gw_gnd),
    .FBDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .IDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .ODSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .PSDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .DUTYDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .FDLY({gw_gnd,gw_gnd,gw_gnd,gw_gnd})
);
defparam rpll_inst.FCLKIN = "50";
defparam rpll_inst.DYN_IDIV_SEL = "false";
defparam rpll_inst.IDIV_SEL = 4;
defparam rpll_inst.DYN_FBDIV_SEL = "false";
defparam rpll_inst.FBDIV_SEL = 11;
defparam rpll_inst.DYN_ODIV_SEL = "false";
defparam rpll_inst.ODIV_SEL = 8;
defparam rpll_inst.PSDA_SEL = "0000";
defparam rpll_inst.DYN_DA_EN = "true";
defparam rpll_inst.DUTYDA_SEL = "1000";
defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL = "internal";
defparam rpll_inst.CLKOUT_BYPASS = "false";
defparam rpll_inst.CLKOUTP_BYPASS = "false";
defparam rpll_inst.CLKOUTD_BYPASS = "false";
defparam rpll_inst.DYN_SDIV_SEL = 2;
defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
defparam rpll_inst.DEVICE = "GW2AR-18C";
endmodule //Gowin_rPLL_audio