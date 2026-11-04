// tb_sin.v - verify Gowin_pROM_sin address->data mapping against the analytic sine
// Dumps 4096 read values; the Python checker compares them with the expected table.
`timescale 1ns/1ps
module tb_sin;
    reg         clk = 0;
    reg         oce = 1;
    reg         ce  = 1;
    reg         reset = 1;
    reg  [11:0] ad = 12'd0;
    wire [15:0] dout;

    integer fd;
    integer A;

    Gowin_pROM_sin dut (
        .dout(dout), .clk(clk), .oce(oce), .ce(ce), .reset(reset), .ad(ad)
    );

    always #5 clk = ~clk;

    initial begin
        // release synchronous reset
        repeat(4) @(posedge clk);
        reset = 0;
        repeat(4) @(posedge clk);

        fd = $fopen("sin_dump.txt", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open sin_dump.txt");
            $finish;
        end

        for (A = 0; A < 4096; A = A + 1) begin
            ad = A[11:0];
            repeat(3) @(posedge clk);
            #1;
            $fdisplay(fd, "%04X", dout);
        end

        $fclose(fd);
        $display("DUMP_DONE 4096 values");
        $finish;
    end
endmodule