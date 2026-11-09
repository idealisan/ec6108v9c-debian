#!/usr/bin/env python3
"""
annotate.py -- reusable, kallsyms-aware ARM disassembler for p11_vmlinux.bin.
Resolves: BL/BLX targets -> symbol names; ldr-literal -> value; movw/movt -> 32-bit const;
and flags MMIO writes (str) with computed offsets. Read-only; stdout only.

Usage: python3 annotate.py <funcName|0xVA> [nInsns] [--raw]
"""
import struct, sys, os, bisect
from capstone import *
from capstone.arm_const import *

HERE=os.path.dirname(os.path.abspath(__file__))
VML=os.path.normpath(os.path.join(HERE,"..","extracted","p11_vmlinux.bin"))
d=open(VML,'rb').read();N=len(d);BASE=0x80008000
def u32(o):return struct.unpack_from('<I',d,o)[0] if o+4<=N else 0
def u16(o):return struct.unpack_from('<H',d,o)[0] if o+2<=N else 0

# ---- kallsyms reconstruction (validated: base=0x80008000, DELTA=0, oracle 80/80) ----
TOKTAB=0xcf3360;TOI=0xcf36f0;NAMES=0xc36200;NUMSYM=62959;A=0xbf8a30
val=[u16(TOI+2*i) for i in range(256)];toks=[]
for i in range(256):
    e=d.find(b'\0',TOKTAB+val[i]);toks.append(d[TOKTAB+val[i]:e].decode('latin1'))
p=NAMES;names=[]
for i in range(NUMSYM):
    L=d[p];names.append(''.join(toks[t] for t in d[p+1:p+1+L]));p+=1+L
addrs=[u32(A+4*i) for i in range(NUMSYM)]
ADDR2NAME={};SYM={}
for i,n in enumerate(names):
    ADDR2NAME.setdefault(addrs[i],n[1:])   # strip type letter
    SYM.setdefault(n[1:],addrs[i])
ALLSORT=sorted(ADDR2NAME)
def encl(va):
    i=bisect.bisect_right(ALLSORT,va)-1
    return ADDR2NAME.get(ALLSORT[i],'?') if i>=0 else '?'
def s_at(va):
    off=va-BASE
    if 0<=off<N-64:
        e=d.find(b'\0',off,off+64)
        if e>off:
            s=d[off:e]
            if len(s)>=3 and all(32<=b<127 for b in s):return s.decode('latin1')
    return None

md=Cs(CS_ARCH_ARM,CS_MODE_ARM|CS_MODE_LITTLE_ENDIAN);md.detail=True;md.skipdata=True

def _reg0(ins):
    # first register operand name from op_str (e.g. "r3, #0x8600" -> "r3")
    s=ins.op_str.split(',')[0].strip()
    return s

def annotate(va,n=120):
    off=va-BASE
    lo={}  # reg -> (low16, addr) of last movw
    out=[]
    for ins in md.disasm(d[off:off+4*n],va):
        if ins.id==0:
            out.append('0x%08x  .word  0x%08x'%(ins.address,u32(ins.address-BASE)));continue
        ann=[]
        ops=list(ins.operands)
        # movw/movt reconstruction (pair by register)
        if ins.mnemonic=='movw':
            for o in ops:
                if o.type==ARM_OP_IMM: lo[_reg0(ins)]=(o.imm&0xffff,ins.address)
        if ins.mnemonic=='movt':
            for o in ops:
                if o.type==ARM_OP_IMM:
                    hi=o.imm&0xffff; reg=_reg0(ins)
                    if reg in lo:
                        lv,wa=lo[reg]
                        if 0<=ins.address-wa<=20:
                            c=(hi<<16)|lv;ann.append('CONST=0x%08x'%c)
                            ss=s_at(c)
                            if ss:ann.append('STR="%s"'%ss[:40])
        # BL/BLX target
        if ins.mnemonic.startswith('bl'):
            for o in ops:
                if o.type==ARM_OP_IMM:
                    t=o.imm&0xffffffff
                    ann.append('call %s'%ADDR2NAME.get(t,'sub_%08x'%t))
                    break
        # ldr literal
        if ins.mnemonic.startswith('ldr'):
            for o in ops:
                if o.type==ARM_OP_MEM and o.mem.base==ARM_REG_PC:
                    t=ins.address+8+o.mem.disp
                    if 0<=t-BASE<N-3:
                        w=u32(t-BASE);ann.append('LIT=0x%08x'%w)
                        ss=s_at(w)
                        if ss:ann.append('STR="%s"'%ss[:40])
        # str with immediate offset (MMIO candidate)
        if ins.mnemonic.startswith('str') and not ins.mnemonic.startswith('strd'):
            for o in ops:
                if o.type==ARM_OP_MEM and o.mem.base!=ARM_REG_PC:
                    disp=o.mem.disp
                    if disp: ann.append('OFF=+0x%x'%disp if disp>=0 else 'OFF=-0x%x'%(-disp))
        out.append('0x%08x  %-9s %-40s ; %s'%(ins.address,ins.mnemonic,ins.op_str,' '.join(ann)))
    return '\n'.join(out)

if __name__=='__main__':
    arg=sys.argv[1]
    n=int(sys.argv[2]) if len(sys.argv)>2 else 120
    if arg.startswith('0x'):
        va=int(arg,16);name=encl(va)
    else:
        name=arg;va=SYM[arg]
    print('### %s @0x%08x (encl=%s) ###'%(name,va,encl(va)))
    print(annotate(va,n))
