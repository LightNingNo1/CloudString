import math

# ---------------- pluck pitches: 32 strings C3..C7, 4 octave layers x 8 white keys -------
# Layer L (v>>3) base = C(L+3); degree g (v&7) = C D E F G A B C(octave up)
PLK = [23409859, 26276679, 29494575, 31248413, 35075158, 39370534, 44191930, 46819719]
# C4..C5 (already used in the current design, fs=48kHz)
names = ["C", "D", "E", "F", "G", "A", "B", "C'"]

print("// ---- PLK32 : 32 fixed pluck steps (voice v = layer*8 + degree) ----")
for v in range(32):
    L = v >> 3
    g = v & 7
    if L == 0:
        inc = PLK[g] >> 1
    else:
        inc = PLK[g] << (L - 1)
    octv = 3 + L
    nm = names[g]
    print("localparam [31:0] PLK%02d = 32'd%-8d;  // %s%s" % (v, inc, nm, octv))

# ---------------- violin open strings (6 strings) ---------------------------------------
def INC(f):
    return int(math.floor(f * (2**32) / 48000.0 + 0.5))

violin = [("F2", 87.30705786), ("C3", 130.8127827), ("G3", 195.9977176),
          ("D4", 293.6647679), ("A4", 440.0), ("E5", 659.2551138)]
print()
print("// ---- violin open-string base steps (bow mode, fs=48kHz) ----")
for i, (nm, f) in enumerate(violin):
    print("localparam [31:0] VIO%d = 32'd%-8d;  // %s %.4f Hz" % (i, INC(f), nm, f))

# ---------------- additive weights W[n] = round(32768/(n*H16)) --------------------------
H16 = sum(1.0 / n for n in range(1, 17))
print()
print("// H16 = %.12f" % H16)
W = []
for n in range(1, 17):
    W.append(int(math.floor(32768.0 / (n * H16) + 0.5)))
print("// ---- W[n], n=1..16 (Q15); sum = %d ----" % sum(W))
print("W:", W)

# ---------------- decay shift SH[n] = 16 - round(log2(n)) -------------------------------
SH = []
for n in range(1, 17):
    SH.append(16 - int(math.floor(math.log2(n) + 0.5)))
print("// ---- SH[n] = 16 - round(log2(n)); tau = 2^SH/48000 ----")
print("SH:", SH)
print("tau_ms:", [round((2**s) / 48000.0 * 1000, 1) for s in SH])

# pack into 80-bit / 64-bit constants for the verilog tables
shpack = 0
for i, s in enumerate(SH):
    shpack |= (s & 0x1F) << (5 * i)
wpack = 0
for i, w in enumerate(W):
    wpack |= (w & 0xFFFF) << (16 * i)
print()
print("SH_TBL 80'h%020X" % shpack)
print("W_TBL 256'h%064X" % wpack)
print("(SH_TBL bit [5*n-5 +: 5] = SH[n-1] ; W_TBL bit [16*n-16 +: 16] = W[n-1])")