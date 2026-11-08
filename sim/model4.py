# model4.py -- fixed-point model of the 4-lane 8192-pt chain + RTL compare.
import numpy as np, sys
N=8192
def i24(x): return np.clip(np.round(x), -8388608, 8388607).astype(np.int64)
def mag16(re, im):
    # 2026-10-25 FIX: the delivered RTL (rtl/mag_sq24.v, "single DSP / 13 bit" version)
    # squares the 13-bit slice i[12:0] (precise for |i| <= 4095) and saturates when
    # |i| >= 4096 or the sum >= 2^24.  The old model truncated to 12 bit signed
    # (precise only below 2048) and therefore disagreed with the RTL for any bin whose
    # |X| is in 2048..4095 -- which is exactly what a low-amplitude single tone hits.
    big = (np.abs(re) >= 4096) | (np.abs(im) >= 4096)
    r = re & 0x1FFF; qq = im & 0x1FFF
    r = np.where(r >= 4096, r-8192, r); qq = np.where(qq >= 4096, qq-8192, qq)
    s = r*r + qq*qq
    o = (s >> 8)
    o = np.where(s >= (1<<24), 0xFFFF, o)
    return np.where(big, 0xFFFF, o).astype(np.int64)

def run(name):
    d=np.load(f'vec_{name}.npz'); i=d['i'].astype(np.int64); q=d['q'].astype(np.int64); h=d['h'].astype(np.int64)
    xwi=(i*h)>>12; xwq=(q*h)>>12
    m=np.arange(2048); Y=[]
    for l in range(4):
        y=xwi[4*m+l]+1j*xwq[4*m+l]
        F=np.fft.fft(y)/32.0
        Y.append(i24(F.real)+1j*i24(F.imag))
    Y.append(None)
    k=np.arange(2048)
    def wt(l):
        th=-2*np.pi*l*k/8192
        wr=np.clip(np.round(np.cos(th)*65536),-65536,65535).astype(np.int64)
        wi=np.clip(np.round(np.sin(th)*65536),-65536,65535).astype(np.int64)
        return wr,wi
    Z=[Y[0]]
    for l in (1,2,3):
        wr,wi=wt(l); yr=Y[l].real.astype(np.int64); yi=Y[l].imag.astype(np.int64)
        zr=(yr*wr-yi*wi+32768)>>16; zi=(yr*wi+yi*wr+32768)>>16
        Z.append(zr+1j*zi)
    Zr=[z.real.astype(np.int64) for z in Z]; Zi=[z.imag.astype(np.int64) for z in Z]
    Are=Zr[0]+Zr[2]; Aim=Zi[0]+Zi[2]; Bre=Zr[0]-Zr[2]; Bim=Zi[0]-Zi[2]
    Cre=Zr[1]+Zr[3]; Cim=Zi[1]+Zi[3]; Dre=Zr[1]-Zr[3]; Dim=Zi[1]-Zi[3]
    Xr=[Are+Cre, Bre+Dim, Are-Cre, Bre-Dim]
    Xi=[Aim+Cim, Bim-Dre, Aim-Cim, Bim+Dre]
    spec=np.zeros(N,dtype=np.int64)
    for qq in range(4):
        xr=(Xr[qq]>>2); xi=(Xi[qq]>>2)
        xr=np.clip(xr,-8388608,8388607); xi=np.clip(xi,-8388608,8388607)
        mg=mag16(xr,xi)
        bins=k+2048*qq
        spec[bins]=mg
    # ---- downstream ----
    g=np.arange(2048)
    s=np.zeros(2048,dtype=np.int64)
    for gg in g:
        end=4*gg+3
        idx=(end-255+np.arange(256))%N
        s[gg]=spec[idx].sum()>>8
    pg=int(np.argmax(s)); pk=int(s[pg]); thr=pk>>1
    # 2026-10-27 (experiment u100): the walk limit is the implementation RANGE, not
    # the algorithm.  The old limit was 1300 GROUPS, so any real -3 dB boundary more
    # than 1300 groups from the peak was reported as a wrapped pointer (wrong BW).
    # The limit is now 2600 groups (> one full circle of 2048), and a walk that has
    # tested a whole circle without finding a below-thr group means the entire 8192-bin
    # band is occupied: that frame is FULL BAND (L=0, R=8191, BW=8192, C=4096).  This
    # is the correct reading for the only case with no -3 dB boundary; the stop rule
    # for every frame that does have one is unchanged.
    def walk(p, step):
        k = 0
        for _ in range(2600):
            if s[p % 2048] >= thr:
                p += step; k += 1
            else:
                break
        return p, k
    pl, kl = walk(pg, -1)
    pr, kr = walk(pg, +1)
    if kl >= 2048 or kr >= 2048:
        L, R, bw, C = 0, 8191, 8192, 4096
    else:
        L=((pl+1)%2048)*4; R=((pr-1)%2048)*4+3
        bw=((R-L)%N)+1; C=(L+bw//2)%N
    return dict(spec=spec,s=s,peak=pk,thr=thr,L=L,R=R,bw=bw,C=C)

def dump_word(spec,q,a):
    return sum(int(spec[q*2048+4*a+r])<<(16*r) for r in range(4))

if __name__=='__main__':
    name=sys.argv[1] if len(sys.argv)>1 else 'rand'
    r=run(name)
    print(f"### MODEL {name} L={r['L']} R={r['R']} BW={r['bw']} C={r['C']} PK={r['peak']} TH={r['thr']}")
    try:
        rows=[l.split() for l in open('spec_dump.txt') if l.strip()]
        d=np.zeros((4096,4),dtype=np.int64)
        for r in rows:
            qq=int(r[0]); ii=int(r[1]); d[qq*1024+ii]=[int(x,16) for x in r[2:]]
        # file has 1024 lines x 4 words: columns are qr0..qr3, rows are addr (buf in bit9)
        best=None
        for buf in (0,1):
            match=0; tot=0; mx=0
            for a in range(512):
                for qq in range(4):
                    rtl=int(d[buf*512+a][qq]); mdl=dump_word(r['spec'],qq,a)
                    for rr in range(4):
                        rv=(rtl>>(16*rr))&0xFFFF; mv=(mdl>>(16*rr))&0xFFFF
                        tot+=1
                        if rv==mv: match+=1
                        mx=max(mx,abs(rv-mv))
            print(f"### SPEC buf{buf}: exact={match}/{tot} ({100.0*match/tot:.2f}%) maxdiff={mx}")
    except Exception as e:
        print("no dump:",e)
