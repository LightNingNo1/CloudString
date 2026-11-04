// tb_adc_map.v - verify adc128s102.v 8-channel TDM channel mapping
// Set each INx to a distinct code; check adc_chx == INx; then change only IN0.
`timescale 1ns/1ps
module tb_adc_map;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                 // 50MHz

    wire        adc_cs_n, adc_sclk, adc_din, adc_dout;
    wire [11:0] c0,c1,c2,c3,c4,c5,c6,c7;
    wire [2:0]  cur_ch;
    wire        upd, scan_done;

    adc128s102 #(.CS_HIGH(16'd9), .CLK_HALF(16'd3), .SMOOTH_SH(5'd4)) dut (
        .clk(clk), .rst_n(rst_n),
        .adc_cs_n(adc_cs_n), .adc_sclk(adc_sclk), .adc_din(adc_din), .adc_dout(adc_dout),
        .adc_ch0(c0), .adc_ch1(c1), .adc_ch2(c2), .adc_ch3(c3),
        .adc_ch4(c4), .adc_ch5(c5), .adc_ch6(c6), .adc_ch7(c7),
        .cur_ch(cur_ch), .adc_upd(upd), .scan_done(scan_done));

    // ---------------- ADC128S102 behavioral model ----------------
    reg [11:0] vin [0:7];
    initial begin
        vin[0]=12'h100; vin[1]=12'h200; vin[2]=12'h300; vin[3]=12'h400;
        vin[4]=12'h500; vin[5]=12'h600; vin[6]=12'h700; vin[7]=12'h800;
    end

    reg [7:0]  ctrl = 8'h00;     // control register written by DIN last frame
    reg [7:0]  sh;               // DIN serial shift
    reg [3:0]  rise_cnt;
    reg [4:0]  fcnt;             // SCLK falling edges seen this frame
    reg [11:0] dsr;              // 12-bit data to output (MSB at [11])

    assign adc_dout = (!adc_cs_n && (fcnt >= 5'd5)) ? dsr[11] : 1'b0;

    always @(negedge adc_cs_n) begin
        dsr      <= vin[ctrl[5:3]];   // this frame converts the previous frame's address
        fcnt     <= 5'd0;
        rise_cnt <= 4'd0;
        sh       <= 8'd0;
    end
    always @(posedge adc_sclk) if (!adc_cs_n) begin
        sh = {sh[6:0], adc_din};      // MSB first
        rise_cnt = rise_cnt + 1'b1;
        if (rise_cnt == 4'd8) ctrl = sh;   // first 8 rising edges latch the address
    end
    always @(negedge adc_sclk) if (!adc_cs_n) begin
        fcnt <= fcnt + 1'b1;
        if (fcnt >= 5'd5) dsr <= {dsr[10:0], 1'b0};
    end

    task show;
        begin
            $display("adc = %4h %4h %4h %4h %4h %4h %4h %4h   expect %4h %4h %4h %4h %4h %4h %4h %4h",
                     c0,c1,c2,c3,c4,c5,c6,c7,
                     vin[0],vin[1],vin[2],vin[3],vin[4],vin[5],vin[6],vin[7]);
        end
    endtask

    function [11:0] abs12;
        input [11:0] a, b;
        begin
            abs12 = (a > b) ? (a - b) : (b - a);
        end
    endfunction

    integer nbad;
    task check;
        input [11:0] e0,e1,e2,e3,e4,e5,e6,e7;
        begin
            nbad = 0;
            if (abs12(c0,e0) > 8) begin $display("  FAIL ch0: got %0d want %0d", c0, e0); nbad=nbad+1; end
            if (abs12(c1,e1) > 8) begin $display("  FAIL ch1: got %0d want %0d", c1, e1); nbad=nbad+1; end
            if (abs12(c2,e2) > 8) begin $display("  FAIL ch2: got %0d want %0d", c2, e2); nbad=nbad+1; end
            if (abs12(c3,e3) > 8) begin $display("  FAIL ch3: got %0d want %0d", c3, e3); nbad=nbad+1; end
            if (abs12(c4,e4) > 8) begin $display("  FAIL ch4: got %0d want %0d", c4, e4); nbad=nbad+1; end
            if (abs12(c5,e5) > 8) begin $display("  FAIL ch5: got %0d want %0d", c5, e5); nbad=nbad+1; end
            if (abs12(c6,e6) > 8) begin $display("  FAIL ch6: got %0d want %0d", c6, e6); nbad=nbad+1; end
            if (abs12(c7,e7) > 8) begin $display("  FAIL ch7: got %0d want %0d", c7, e7); nbad=nbad+1; end
            if (nbad == 0) $display("  >> PASS");
            else           $display("  >> FAIL (%0d mismatched)", nbad);
        end
    endtask

    initial begin
        #200 rst_n = 1;

        #9000000;
        $display("[stage1] all channels fixed, after IIR settle:");
        show;
        check(12'h100,12'h200,12'h300,12'h400,12'h500,12'h600,12'h700,12'h800);

        $display("[stage2] change ONLY IN0: 0x100 -> 0xAAA:");
        vin[0] = 12'hAAA;
        #9000000;
        show;
        check(12'hAAA,12'h200,12'h300,12'h400,12'h500,12'h600,12'h700,12'h800);

        $display("[stage3] change ONLY IN0: -> 0x020 (near mute):");
        vin[0] = 12'h020;
        #9000000;
        show;
        check(12'h020,12'h200,12'h300,12'h400,12'h500,12'h600,12'h700,12'h800);

        $display("=== sim done ===");
        $finish;
    end
endmodule
