# cmp_all.py -- full acceptance compare: fields, per-bin spectrum, smem s[] vs model.
# usage: python cmp_all.py <vecname> <log> [spec_dump] [smem_dump]
#   dump columns are rX3 rX2 rX1 rX0  (lane 3 .. lane 0), line idx = {buf,row}
import sys, re, numpy as np
import model4

vec = sys.argv[1] if len(sys.argv) > 1 else 'tone'
log = sys.argv[2] if len(sys.argv) > 2 else f'../logs/base_{vec}.log'
specf = sys.argv[3] if len(sys.argv) > 3 else 'spec_dump.txt'
smemf = sys.argv[4] if len(sys.argv) > 4 else 'smem_rtl.txt'

r = model4.run(vec)
rf = dict(L=r['L'], R=r['R'], BW=r['bw'], C=r['C'], PK=r['peak'], TH=r['thr'])

done = []
for line in open(log, encoding='utf-8', errors='ignore'):
    if line.startswith('### DONE'):
        d = dict(re.findall(r'(\w+)=(-?\d+)', line))
        done.append((int(d['c2']), d))
uniq = {}
for c2, d in done:
    uniq.setdefault(c2, d)
oks = sorted(uniq)
last = uniq[oks[-1]]
bad = [f"{k}: rtl={int(last[k])} mdl={v}" for k, v in rf.items() if int(last[k]) != v]
print("### FIELD " + ("MATCH" if not bad else "MISMATCH " + ", ".join(bad)))
print(f"### FIELD_LINE L={last['L']} R={last['R']} BW={last['BW']} C={last['C']} PK={last['PK']} TH={last['TH']}"
      f" | model L={rf['L']} R={rf['R']} BW={rf['BW']} C={rf['C']} PK={rf['PK']} TH={rf['TH']}")
if len(oks) >= 2:
    diffs = [oks[i+1]-oks[i] for i in range(len(oks)-1)]
    print(f"### N_INTERVALS clk2={diffs} frames={[round(d/1024.0,2) for d in diffs]}")

spec = r['spec']
try:
    rows = [l.split() for l in open(specf) if l.strip() and 'x' not in l]
    d = np.zeros((4096, 4), dtype=np.int64)
    for row in rows:
        qq = int(row[0]); ii = int(row[1]); d[qq*1024+ii] = [int(x, 16) for x in row[2:6]]
    for buf in (0, 1):
        match = 0; tot = 0; diffs = []
        for a in range(512):
            for qq in range(4):
                c = d[qq*1024+buf*512+a]
                # columns rX3 rX2 rX1 rX0 -> lane3..lane0; lane0 in bits 15:0
                word = int(c[3]) | (int(c[2])<<16) | (int(c[1])<<32) | (int(c[0])<<48)
                md = model4.dump_word(spec, qq, a)
                for rr in range(4):
                    tot += 1
                    rv = (word >> (16*rr)) & 0xFFFF; mv = (md >> (16*rr)) & 0xFFFF
                    if rv == mv: match += 1
                    else: diffs.append((qq*2048+4*a+rr, mv, rv))
        print(f"### SPEC buf{buf}: exact={match}/{tot} ({100.0*match/tot:.2f}%) ndiff={len(diffs)}")
        if len(diffs) < 40: print("### SPEC_DIFF", diffs[:20])
except Exception as e:
    print("### SPEC_ERROR", repr(e))

try:
    m = np.zeros((4, 1024), dtype=np.int64)
    for line in open(smemf):
        f = line.split()
        if len(f) == 5 and 'x' not in line:
            i = int(f[0])
            for b in range(4): m[b][i] = int(f[1+b], 16)
    s = r['s']
    best = None
    for bank in (0, 1):
        rtl = np.zeros(2048, dtype=np.int64)
        for q in range(4):
            rtl[q*512:(q+1)*512] = m[q][bank*512:(bank+1)*512]
        eq = int((rtl == s).sum()); mx = int(np.abs(rtl-s).max())
        if best is None or eq > best[0]: best = (eq, mx, bank, rtl)
    eq, mx, bank, rtl = best
    print(f"### SMEM exact={eq}/2048 maxdiff={mx} bank={bank}")
    if eq != 2048:
        idx = np.where(rtl != s)[0]
        print("### SMEM_DIFF_FIRST", [(int(i), int(s[i]), int(rtl[i])) for i in idx[:8]])
except Exception as e:
    print("### SMEM_ERROR", repr(e))
