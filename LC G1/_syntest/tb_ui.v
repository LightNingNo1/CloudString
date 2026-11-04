module tb_ui;
 reg [2:0] scr; reg [4:0] row,col; reg instr; reg [4:0] sel_v;
 reg [11:0] a1,a2,a3,a4,a5,a6; reg [2:0] cur; reg [1:0] page;
 wire [6:0] code; wire [1:0] attr;
 ui_text u(.scr(scr),.row(row),.col(col),.instr(instr),.sel_v(sel_v),
  .adc1(a1),.adc2(a2),.adc3(a3),.adc4(a4),.adc5(a5),.adc6(a6),.cur(cur),.page(page),.code(code),.attr(attr));
 integer r,c; integer nz;
 initial begin
  instr=0; sel_v=0; a1=2048;a2=2048;a3=2048;a4=2048;a5=2048;a6=2048; cur=0; page=3;
  for (scr=0; scr<7; scr=scr+1) begin
    nz=0;
    for (r=0;r<17;r=r+1) begin
      row=r;
      for (c=0;c<30;c=c+1) begin col=c; #1; if (code!=0) nz=nz+1; end
    end
    $display("scr=%0d nonzero_codes=%0d", scr, nz);
  end
  $finish;
 end
endmodule
