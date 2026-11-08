# scan7.py -- 7+ point single-tone scan against the fixed-point model.
# For each bin: build a low-amplitude tone (no saturation), run tb_sys4, compare
# fields L/R/BW/C/PK/TH and the per-bin spectrum.  This is the safety net for
# index/phase-chain changes (see docs/合并级索引对齐缺陷.md).
import numpy as np, subprocess, os, sys, shutil

# Repo-relative layout: this file lives in <repo>/sim/, logs go to <repo>/_sim_logs/.
# Set XSIM_BAT if xsim.bat is not on PATH, e.g.
#   set XSIM_BAT=%XILINX_VIVADO%\bin\xsim.bat
H    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM  = os.path.join(H, 'sim')
LOGS = os.path.join(H, '_sim_logs')
os.makedirs(LOGS, exist_ok=True)
XSIM = os.environ.get('XSIM_BAT', 'xsim.bat')
N = 8192
BINS = [1, 1023, 1234, 2047, 2049, 4095, 4096, 8191]
AMP = float(sys.argv[1]) if len(sys.argv) > 1 else 0.05
tag = sys.argv[2] if len(sys.argv) > 2 else 'scan7'

def gen(bin_):
    n = np.arange(N)
    ph = 2*np.pi*bin_*n/N
    i = np.clip(np.round(AMP*2047*np.cos(ph)), -2048, 2047).astype(np.int64)
    q = np.clip(np.round(AMP*2047*np.sin(ph)), -2048, 2047).astype(np.int64)
    h = np.round(4095*(0.5-0.5*np.cos(2*np.pi*n/(N-1)))).astype(np.int64)
    iq = ((q & 0xFFF) << 12) | (i & 0xFFF)
    with open(f'{SIM}/iq4_probe.mem','w') as f:
        for a in range(2048):
            w = 0
            for l in range(3,-1,-1): w = (w<<24) | int(iq[4*a+l])
            f.write('%024x\n' % w)
    np.savez(f'{SIM}/vec_probe.npz', i=i, q=q, h=h, name='probe')

rows = []
for b in BINS:
    gen(b)
    shutil.copy(f'{SIM}/iq4_probe.mem', f'{SIM}/iq4.mem')
    log  = os.path.join(LOGS, f'{tag}_{b}.log')
    specf = os.path.join(LOGS, f'{tag}_{b}_spec.txt')
    smemf = os.path.join(LOGS, f'{tag}_{b}_smem.txt')
    r = subprocess.run([XSIM,'tb_sys4','-runall'],
                       cwd=SIM, capture_output=True, text=True, shell=True)
    open(log,'w',encoding='utf-8').write(r.stdout + r.stderr)
    shutil.copy(f'{SIM}/spec_dump.txt', specf)
    shutil.copy(f'{SIM}/smem_rtl.txt', smemf)
    out = subprocess.run([sys.executable,'cmp_all.py','probe',log,specf,smemf],
                         cwd=SIM, capture_output=True, text=True).stdout
    field = '?' ; spec = '?'; smem='?'
    for l in out.splitlines():
        if l.startswith('### FIELD '): field = l[10:]
        if l.startswith('### SPEC buf0'): spec = l[10:]
        if l.startswith('### SMEM'): smem = l[7:]
    print(f'### SCAN bin={b:5d} {field} | {spec} | {smem}', flush=True)
    rows.append((b, field, spec))
print('### SCAN_DONE')
