# gen_u100.py -- "unconditional 100%" worst-case vectors.
#
# Why these vectors: b8 walks 2 groups/clk2 on BOTH sides, but its limit was counted
# in CYCLES (bc>1300 => 2600 groups) while model4.py caps each side at 1300 GROUPS
# (`for _ in range(1300)`).  A frame whose whole band is above thr never terminates:
# b8 then runs 1301 clk2 (> 1024 => N=2) and reports pl=pr=pg (BW=8192) instead of
# the model's capped pl=pg-1300 / pr=pg+1300 (BW=2204).  These vectors guard that:
#
#   u100_full : all 8192 bins at power 1 (full 1 GHz band), peak pinned at bin 1
#               (=> PA peak group 0, the low band edge).  Every group >= thr, so the
#               walk never sees a boundary: model cap is the result.
#   u100_q1   : same flat full band, peak pinned at bin 2048 (25% of the band ->
#               group 512).  Both walks unterminated, asymmetric start.
#   u100_half : single-sided 0..500 MHz: 0..20 MHz pedestal 1.0, 20..500 MHz plateau
#               0.8, >500 MHz zero.  Peak at the low edge (group ~68), right walk
#               ~985 groups -> a long but TERMINATING one-sided walk.
#
# Pin trick: the 256-bin sliding window means one boosted bin raises 64 neighbouring
# groups equally, so the peak lands on whichever of those 64 has the largest flat-band
# ripple.  The seeds below were searched so that group 0 / group 512 already has the
# largest ripple among its 64 candidates; the single-bin boost (x112 / x80) then lifts
# that group above the rest without pushing peak above 2*min (thr keeps every group
# above the threshold, which is what makes the walk unterminated).
#
# Output: sim/iq4_u100_*.mem (2048 x 96 bit), sim/vec_u100_*.npz (i/q/h).
# This script neither reads nor overwrites sim/iq4.mem.
import numpy as np, os

# Output directory: this script's own folder (sim/), so the repo is relocatable.
# Override with the environment variable VEC_OUT if you need it elsewhere.
OUT = os.environ.get('VEC_OUT') or os.path.dirname(os.path.abspath(__file__))
N = 8192
FS = 1.0e9
DF = FS / N
AMP = 1600

k = np.arange(N)
fr = k * DF                      # 0..1 GHz "single-sided ruler" (same as gen_dc780)


def write_iq(name, P, seed):
    rng = np.random.default_rng(seed)
    mag = np.sqrt(P)
    ph = rng.uniform(0, 2 * np.pi, N)
    X = mag * np.exp(1j * ph)
    x = np.fft.ifft(X)
    x = x / np.max(np.abs(x)) * AMP
    i = np.round(x.real).astype(np.int64)
    q = np.round(x.imag).astype(np.int64)
    i = np.clip(i, -2048, 2047)
    q = np.clip(q, -2048, 2047)
    n = np.arange(N)
    h = np.round(4095 * (0.5 - 0.5 * np.cos(2 * np.pi * n / (N - 1)))).astype(int)
    iq = ((q.astype(np.int64) & 0xFFF) << 12) | (i.astype(np.int64) & 0xFFF)
    with open(f'{OUT}/iq4_{name}.mem', 'w') as fh:
        for a1 in range(2048):
            w = 0
            for l in range(3, -1, -1):
                w = (w << 24) | int(iq[4 * a1 + l])
            fh.write('%024x\n' % w)
    np.savez(f'{OUT}/vec_{name}.npz', i=i, q=q, h=h, name=name)
    print(f"### {name}: amp I={int(np.max(np.abs(i)))} Q={int(np.max(np.abs(q)))}"
          f"  P>0 bins={int((P > 0).sum())}")


# ---- 1. full band (1 GHz), peak pinned at bin 1 => PA peak group 0 ----
P = np.ones(N)
P[1] = 112.0
write_iq('u100_full', P, 222)

# ---- 2. full band, peak pinned at bin 2048 (25%) => PA peak group 512 ----
P = np.ones(N)
P[2048] = 97.0
write_iq('u100_q1', P, 567)

# ---- 3. single-sided 0..500 MHz, peak at the low edge ----
P = np.zeros(N)
P[fr <= 20e6] = 1.0
P[(fr > 20e6) & (fr <= 500e6)] = 0.8
write_iq('u100_half', P, 8)

# ---- model prediction (model4.py is the acceptance criterion) ----
import model4

print("\n### MODEL PREDICTIONS (walk groups from the model's pg/pl/pr)")
for name in ('u100_full', 'u100_q1', 'u100_half'):
    r = model4.run(name)
    pg = int(np.argmax(r['s']))
    s = r['s']; thr = r['thr']
    def walk(p, st):
        k = 0
        for _ in range(2600):
            if s[p % 2048] >= thr:
                p += st; k += 1
            else:
                break
        return k
    left = min(walk(pg, -1), 2048)
    right = min(walk(pg, +1), 2048)
    full = (left >= 2048) or (right >= 2048)
    # v10: 4 groups/clk2 both sides; PB ~ 1 prime + ceil(max(l,r)/4) + pre(<=3) + 2
    pb = 1 + (max(left, right) + 3) // 4 + 3 + 2
    tag = " FULL_BAND" if full else ""
    print(f"### MODEL {name} L={r['L']} R={r['R']} BW={r['bw']} C={r['C']} "
          f"PK={r['peak']} TH={r['thr']} pg={pg} left={left} right={right}{tag} PB~{pb}")
print("### WROTE iq4_u100_full/q1/half.mem + vec_u100_*.npz (iq4.mem untouched)")
