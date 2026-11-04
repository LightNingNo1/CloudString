# LC G1 命令行流程（绕开 IDE GUI）
# 用法：  gw_sh _syntest/run_flow.tcl syn    仅综合
#         gw_sh _syntest/run_flow.tcl pnr    仅布局布线
#         gw_sh _syntest/run_flow.tcl all    综合 + 布局布线 + 出比特流
set prj "D:/Gowin/LC G1/LC G1.gprj"
open_project $prj

set stage "all"
if { $argc > 0 } { set stage [lindex $argv 0] }

switch -- $stage {
    syn { run syn }
    pnr { run pnr }
    default { run all }
}