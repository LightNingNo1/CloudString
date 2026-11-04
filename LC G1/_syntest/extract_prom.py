src = r"D:\Gowin\Gowin_V1.9.10.02_x64\IDE\simlib\gw2a\prim_sim.v"
lines = open(src, encoding="utf-8", errors="replace").read().splitlines()
seg = lines[7415:7604]          # 1-based lines 7416..7604  (//pROM .. endmodule //pROM)
assert seg[0].startswith("//pROM"), seg[0]
assert seg[-1].startswith("endmodule"), seg[-1]
out = "\n".join(seg) + "\n"
dst = r"d:\Gowin\LC G1\_syntest\prom_model.v"
open(dst, "w", newline="\n").write(out)
print("wrote", dst, len(seg), "lines")