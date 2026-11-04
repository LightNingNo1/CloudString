import math

N = 4096
MAXA = 32767

def sval(A):
    x = MAXA * math.sin(2.0 * math.pi * A / N)
    if x >= 0:
        v = math.floor(x + 0.5)
    else:
        v = math.ceil(x - 0.5)
    return v & 0xFFFF

got = []
for ln in open(r"d:\Gowin\LC G1\_syntest\sin_dump.txt"):
    ln = ln.strip()
    if ln:
        got.append(int(ln, 16))

print("read", len(got), "values")
bad = 0
first = []
for A, g in enumerate(got):
    e = sval(A)
    if g != e:
        bad += 1
        if len(first) < 10:
            first.append((A, g, e))
print("mismatches:", bad)
for t in first:
    print("  A=%d got=%04X exp=%04X" % t)
print("spot: A=0 %04X | A=1024 %04X | A=2048 %04X | A=3072 %04X"
      % (got[0], got[1024], got[2048], got[3072]))
print("RESULT:", "PASS" if bad == 0 else "FAIL")