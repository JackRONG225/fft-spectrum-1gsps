# gen_vec4.py -- ROM images for the 4-lane chain + reference vectors.
#  iq4.mem   2048 x 96b : lane0..3, each {q[11:0],i[11:0]} for phase a
#  hann4.mem 2048 x 48b : lane0..3 hann[4*perm(a)+l]
#  wt1..3    2048 x 36b : {im[17:0], re[17:0]} = exp(-j*2pi*l*k/8192)
import numpy as np, os
# Output directory: this script's own folder (sim/), so the repo is relocatable.
# Override with the environment variable VEC_OUT if you need it elsewhere.
# NOTE: argv[1] is the VECTOR NAME (see the bottom of this file), not a path.
OUT = os.environ.get('VEC_OUT') or os.path.dirname(os.path.abspath(__file__))
N = 8192

def bitrev(x, w):
    r = 0
    for i in range(w):
        if (x >> i) & 1: r |= 1 << (w-1-i)
    return r

def perm(a):
    return (bitrev(a & 63, 6) << 5) | (a >> 6)

def make_vectors(name):
    n = np.arange(N)
    if name == 'rand':
        rng = np.random.default_rng(20261023)
        i = rng.integers(-2048, 2048, N)
        q = rng.integers(-2048, 2048, N)
    elif name == 'tone':
        # single tone at bin 1234, 40% full scale
        ph = 2*np.pi*1234*n/N
        i = np.round(0.40*2047*np.cos(ph)).astype(int)
        q = np.round(0.40*2047*np.sin(ph)).astype(int)
    else:  # cross-DC: two tones straddling bin 0
        ph1 = 2*np.pi*4*n/N
        ph2 = 2*np.pi*8188*n/N
        i = np.round(0.25*2047*(np.cos(ph1)+np.cos(ph2))).astype(int)
        q = np.round(0.25*2047*(np.sin(ph1)+np.sin(ph2))).astype(int)
    return np.clip(i, -2048, 2047), np.clip(q, -2048, 2047)

def hann():
    n = np.arange(N)
    return np.round(4095*(0.5 - 0.5*np.cos(2*np.pi*n/(N-1)))).astype(int)

h = hann()
for name in ['rand', 'tone', 'dc']:
    i, q = make_vectors(name)
    iq = (q.astype(np.int64) & 0xFFF) << 12 | (i.astype(np.int64) & 0xFFF)
    with open(f'{OUT}/iq4_{name}.mem', 'w') as f:
        for a in range(2048):
            p = a          # NATURAL order: fe4lane applies perm() on the ROM address
            w = 0
            for l in range(3, -1, -1):
                w = (w << 24) | int(iq[4*p+l])
            f.write('%024x\n' % w)
    np.savez(f'{OUT}/vec_{name}.npz', i=i, q=q, h=h, name=name)
    with open(f'{OUT}/iq4.mem', 'w') as f:
        for a in range(2048):
            p = a          # NATURAL order: fe4lane applies perm() on the ROM address
            w = 0
            for l in range(3, -1, -1):
                w = (w << 24) | int(iq[4*p+l])
            f.write('%024x\n' % w)
    with open(f'{OUT}/hann4.mem', 'w') as f:
        for a in range(2048):
            p = a          # NATURAL order: fe4lane applies perm() on the ROM address
            w = 0
            for l in range(3, -1, -1):
                w = (w << 12) | int(h[4*p+l])
            f.write('%012x\n' % w)

def wtab(l):
    k = np.arange(2048)
    th = -2*np.pi*l*k/8192
    re = np.clip(np.round(np.cos(th)*65536), -65536, 65535).astype(np.int64)
    im = np.clip(np.round(np.sin(th)*65536), -65536, 65535).astype(np.int64)
    with open(f'{OUT}/wt{l}.mem', 'w') as f:
        for x in range(2048):
            v = ((im[x] & 0x3FFFF) << 18) | (re[x] & 0x3FFFF)
            f.write('%09x\n' % v)
for l in (1, 2, 3): wtab(l)
import sys, shutil
sel = sys.argv[1] if len(sys.argv) > 1 else 'rand'
shutil.copy(f'{OUT}/iq4_{sel}.mem', f'{OUT}/iq4.mem')
print('mem written, frame =', sel)
