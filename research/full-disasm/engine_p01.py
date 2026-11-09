#!/usr/bin/env python3
"""
engine_p01.py -- FULL, no-skip linear disassembly + function/callgraph/xref extraction
for p01_fastboot.img (1 MiB bare ARM hiboot).

Discipline (per task spec):
  - capstone 5.0.7 linear sweep is the primary engine (r2 aaa finds 0 functions on raw blob).
  - EVERY 4-byte word in CODE regions is disassembled; DATA/STR/FILL regions are
    skipped FOR INSTRUCTION DECODING but explicitly recorded as intervals (no silent gaps).
  - strings are used ONLY to locate candidate function entries (literal-pool xrefs),
    never as evidence of behaviour. Behaviour is read from instructions.
  - No repository writes. All output under TMP/stock-rom-research/full-disasm/.

Outputs:
  disasm_p01.txt     full linear sweep (VA-coded), region-tagged, skipped intervals listed
  functions_p01.tsv  complete function list (addr/size/name/is_display/analyzed/evidence)
  calls_p01.tsv      full BL/B call-edge list (caller -> target)
  analysis_p01.json  machine-readable ledger for the .md deliverables
"""
import struct, json, re, os, hashlib
from collections import defaultdict
from capstone import *
from capstone.arm_const import *

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "extracted", "p01_fastboot.img")
SRC = os.path.normpath(SRC)
OUT = HERE
BASE = 0x00C00000            # [观察] from 0x204c/0x2044 literals (0x00c00000 / 0x00c00040)
SZ   = 0x100000

d = open(SRC, "rb").read()
assert len(d) == SZ, len(d)

# ---------------------------------------------------------------- region map
# classify each 4 KiB block; record SKIPPED (non-code) intervals explicitly
REGION = []
def classify(chunk):
    n = len(chunk) // 4
    words = [struct.unpack_from("<I", chunk, i*4)[0] for i in range(n)]
    zr = sum(1 for w in words if w == 0) / n
    ffr = sum(1 for b in chunk if b == 0xFF) / len(chunk)
    asc = sum(1 for b in chunk if 32 <= b < 127 or b in (0,9,10,13)) / len(chunk)
    if ffr > 0.5 or zr > 0.6: return "FILL"
    if asc > 0.75: return "STR"
    return "CODE"
for blk in range(0, SZ, 0x1000):
    REGION.append((blk, blk+0x1000, classify(d[blk:blk+0x1000])))
# merge runs
runs = []
for a,b,t in REGION:
    if runs and runs[-1][2]==t and runs[-1][1]==a: runs[-1]=(runs[-1][0],b,t)
    else: runs.append((a,b,t))
CODE = [(a,b) for a,b,t in runs if t=="CODE"]
SKIP = [(a,b,t) for a,b,t in runs if t!="CODE"]

def in_code(off):
    return any(a<=off<b for a,b in CODE)

# ---------------------------------------------------------------- full sweep
md = Cs(CS_ARCH_ARM, CS_MODE_ARM | CS_MODE_LITTLE_ENDIAN)
md.detail = True
md.skipdata = True

INSN = {}          # VA -> (mnemonic, op_str, bytes, id, groups, regs_read/write)
ALL_INSNS = []     # ordered (va, mnemonic, op_str)
for a,b in CODE:
    blob = d[a:b]
    va = BASE + a
    for ins in md.disasm(blob, va):
        if ins.id == 0:       # skipdata pseudo
            INSN[ins.address] = (".word", ins.op_str, ins.bytes, 0, [], [])
            ALL_INSNS.append((ins.address, ".word", ins.op_str))
            continue
        grp = list(ins.groups)
        ops = []
        for o in ins.operands:
            if o.type == ARM_OP_IMM: ops.append(("imm", o.imm & 0xFFFFFFFF))
            elif o.type == ARM_OP_REG: ops.append(("reg", o.reg))
            elif o.type == ARM_OP_MEM: ops.append(("mem", o.mem.base, o.mem.index, o.mem.disp))
        INSN[ins.address] = (ins.mnemonic, ins.op_str, ins.bytes, ins.id, grp, ops)
        ALL_INSNS.append((ins.address, ins.mnemonic, ins.op_str))

# ---------------------------------------------------------------- literal pool
# every word in CODE that is a 32-bit value (captured via ldr [pc,#imm] targets)
LIT = {}           # VA of literal word -> u32 value
LIT_XREF = defaultdict(list)   # literal VA -> [ldr instruction VAs]
pc_lit_pairs = []
for va,(mn,op,by,id_,grp,ops) in INSN.items():
    if mn.startswith("ldr") and any(o[0]=="mem" and o[1]==ARM_REG_PC for o in ops):
        # compute target: PC = va+8 ; disp from op_str when possible
        for o in ops:
            if o[0]=="mem" and o[1]==ARM_REG_PC:
                disp=o[3]
                t=(va+8+disp)
                if t%4==0 and in_code(t-BASE):
                    w=struct.unpack_from("<I",d,t-BASE)[0]
                    LIT[t]=w; LIT_XREF[t].append(va); pc_lit_pairs.append((va,t,w))

# ---------------------------------------------------------------- call edges & function entries
CALL = []          # (caller_va, target_va, mnemonic)
ENTRY = set()
# vector table targets
for off in range(0x20,0x40,4):
    w=struct.unpack_from("<I",d,off)[0]
    if BASE<=w<BASE+SZ: ENTRY.add(w)
# reset vector B target
rv=struct.unpack_from("<I",d,0)[0]
if (rv>>24)&0x0F==0x0A: pass
# decode reset branch: b #imm
bimm=rv & 0xFFFFFF
if bimm & 0x800000: bimm-=0x1000000
reset_t = BASE + 8 + (bimm<<2)
ENTRY.add(reset_t)

CALLMN = {"bl","blx","b","bx"}
for va,(mn,op,by,id_,grp,ops) in sorted(INSN.items()):
    base_mn = mn.split(".")[0] if "." in mn else mn
    # conditional suffixes: ble, bne, bleq, blxne ...
    core = mn
    for suf in ("eq","ne","cs","hs","cc","lo","mi","pl","vs","vc","hi","ls","ge","lt","gt","le","al"):
        if core.endswith(suf) and len(core)>2+suf.__len__()-suf.__len__():
            cand=core[:-len(suf)]
            if cand in ("b","bl","blx","bx"): core=cand; break
    is_call = core in ("bl","blx")
    is_jump = core in ("b","bx")
    if is_call or is_jump:
        for o in ops:
            if o[0]=="imm":
                t=o[1]
                if is_call:
                    CALL.append((va,t,mn))
                    if BASE<=t<BASE+SZ: ENTRY.add(t)
                break

# ARM prologue detection in code regions (STMDB/PUSH with LR, or mov ip,sp; stmdb)
PROLOGUE = []
for va,(mn,op,by,id_,grp,ops) in sorted(INSN.items()):
    if id_ in (ARM_INS_STMDB, ARM_INS_PUSH) and "lr" in op:
        PROLOGUE.append(va)
        ENTRY.add(va)
    if mn in ("mov",) and "ip, sp" in op:
        PROLOGUE.append(va)
        ENTRY.add(va)

ENTRY = sorted(e for e in ENTRY if BASE<=e<BASE+SZ and e%4==0)

# ---------------------------------------------------------------- function extents
# function = from entry to next entry, clipped at a return (ldm..pc / bx lr / mov pc,lr)
RET_IDS = {ARM_INS_POP, ARM_INS_LDM, ARM_INS_LDMDB, ARM_INS_BX, ARM_INS_MOV}
def ret_at(va):
    if va not in INSN: return False
    mn,op,by,id_,grp,ops=INSN[va]
    if id_==ARM_INS_BX and "lr" in op: return True
    if id_==ARM_INS_MOV and "pc, lr" in op: return True
    if id_ in (ARM_INS_POP,ARM_INS_LDM) and ("pc" in op): return True
    return False

FUNCS=[]
for i,e in enumerate(ENTRY):
    nxt = ENTRY[i+1] if i+1<len(ENTRY) else BASE+SZ
    # clip to first return after >= 4 instructions (avoid over-run into literal pools)
    end=nxt
    cnt=0
    for va in range(e,nxt,4):
        if va not in INSN: continue
        cnt+=1
        if cnt>=4 and ret_at(va) and (nxt-va)<=0x400:
            end=va+4; break
    FUNCS.append((e,end))

# ---------------------------------------------------------------- display-related location
# ONLY locating: find literal-pool xrefs whose value points at known display symbol strings.
# Behaviour is NOT inferred from names; these are candidate functions to disassemble fully.
DISPLAY_TOKENS = [b"PRODUCT_DisplayInit", b"Logo_Main", b"HI_UNF_HDMI", b"HDMI_Display",
                  b"hdmi_Disp2EncFmt", b"TX_SetHDMIMode", b"TX_PHY_WriteRegister",
                  b"SW_ResetHDMITX", b"HW_ResetHDMITX", b"siiSetVideoPath",
                  b"pdm_tag", b"HIFB_DispBuf", b"fastapp_entry", b"HI_GFX_ShowLogo",
                  b"HI_DRV_PDM", b"DISP_Init", b"HDMI_DRV", b"set_param_data",
                  b"Logo", b"logo", b"DISP", b"HDMI", b"VO_", b"VDP_", b"hifb"]
TOK_ADDR = {}      # VA of token -> token bytes
for tok in DISPLAY_TOKENS:
    start=0
    while True:
        j=d.find(tok,start)
        if j<0: break
        TOK_ADDR.setdefault(BASE+j,tok)
        start=j+1
# literal pools pointing at these tokens
TOK_XREF = defaultdict(list)   # token_va -> [ (ldr_va, lit_va) ]
for ldr_va,lit_va,w in pc_lit_pairs:
    if (w-BASE)>=0 and (w-BASE)<SZ:
        fo=w-BASE
        # token may start exactly at fo
        if BASE+fo in TOK_ADDR: TOK_XREF[BASE+fo].append((ldr_va,lit_va))
# also: any literal whose value == a token VA
DISPLAY_LITFUNCS=set()
for tv,refs in TOK_XREF.items():
    for ldr_va,lit_va in refs:
        # find enclosing function of ldr_va
        for e,end in FUNCS:
            if e<=ldr_va<end: DISPLAY_LITFUNCS.add(e); break
# MMIO constant detection: functions whose code contains 0xf8cc0000/0xf8ce0000/0xf9000000 literals
MMIO_FUNCS=set()
MMIO_HITS=[]
for ldr_va,lit_va,w in pc_lit_pairs:
    if w in (0xf8cc0000,0xf8ce0000,0xf8ce1800,0xf9000000,0xf8a20000,0xf8a22000) or (0xf8000000<=w<0xf9000000):
        MMIO_HITS.append((ldr_va,lit_va,w))
        for e,end in FUNCS:
            if e<=ldr_va<end: MMIO_FUNCS.add(e); break

# ---------------------------------------------------------------- outputs
# 1) disasm_p01.txt -- full linear sweep
dis_lines=[]
dis_lines.append("# disasm_p01.txt -- FULL capstone linear sweep of p01_fastboot.img")
dis_lines.append("# load base VA=0x00C00000 (file off + base). capstone 5.0.7 ARM/LE, skipdata=True")
dis_lines.append("# sha256=%s size=%d"%(hashlib.sha256(d).hexdigest(),len(d)))
dis_lines.append("# CODE regions disasm'd per instruction; non-CODE regions listed as SKIPPED intervals below.")
dis_lines.append("#")
dis_lines.append("# ===== SKIPPED (non-code) INTERVALS (explicit, no silent gaps) =====")
for a,b,t in SKIP:
    dis_lines.append("# SKIP 0x%05x..0x%05x (VA 0x%08x..0x%08x) type=%s len=0x%x"%(a,b,BASE+a,BASE+b,t,b-a))
dis_lines.append("#")
dis_lines.append("# ===== CODE REGION REGIONS =====")
for a,b in CODE:
    dis_lines.append("# CODE 0x%05x..0x%05x (VA 0x%08x..0x%08x)"%(a,b,BASE+a,BASE+b))
dis_lines.append("#")
dis_lines.append("# ===== FULL INSTRUCTION LISTING =====")
cur_region=None
for va,mn,op in ALL_INSNS:
    off=va-BASE
    tag=None
    for a,b,t in runs:
        if a<=off<b: tag=t; break
    if tag!=cur_region:
        dis_lines.append("; ---- region %s @ VA 0x%08x ----"%(tag,va)); cur_region=tag
    by=INSN[va][2]
    hexb=''.join('%02x'%x for x in by)
    ann=""
    # annotate BL targets that are function entries
    dis_lines.append("0x%08x: %-10s %-10s %-40s ; %s"%(va,hexb,mn,op,("lit=%08x"%struct.unpack_from('<I',d,off)[0]) if mn==".word" else ""))
open(os.path.join(OUT,"disasm_p01.txt"),"w").write("\n".join(dis_lines)+"\n")

# 2) functions_p01.tsv
frows=["#addr\tVA\tendVA\tsize\tname\tis_display_candidate\tanalyzed\tentry_evidence"]
name_map={}
for e,end in FUNCS:
    ev=[]
    if e in PROLOGUE: ev.append("prologue")
    for c,t,m in CALL:
        if t==e: ev.append("BLtarget"); break
    for off in range(0x20,0x40,4):
        if struct.unpack_from("<I",d,off)[0]==e: ev.append("vector"); break
    if e==reset_t: ev.append("reset")
    isdisp = "MMIO" if e in MMIO_FUNCS else ("LITXREF" if e in DISPLAY_LITFUNCS else "")
    frows.append("0x%05x\t0x%08x\t0x%08x\t0x%x\tsub_%08x\t%s\t%s\t%s"%(
        e-BASE,e,end,end-e,e,isdisp,"",("+".join(sorted(set(ev))) or "BLtarget")))
open(os.path.join(OUT,"functions_p01.tsv"),"w").write("\n".join(frows)+"\n")

# 3) calls_p01.tsv
crows=["#callerVA\ttargetVA\tmnemonic\ttarget_off"]
for c,t,m in CALL:
    crows.append("0x%08x\t0x%08x\t%s\t%s"%(c,t,m,("0x%x"%(t-BASE) if BASE<=t<BASE+SZ else "outside")))
open(os.path.join(OUT,"calls_p01.tsv"),"w").write("\n".join(crows)+"\n")

# 4) analysis ledger json
ledger={
 "file":"p01_fastboot.img","sha256":hashlib.sha256(d).hexdigest(),"size":SZ,"base":hex(BASE),
 "engine":"capstone 5.0.7 ARM LE linear sweep (detail+skipdata)",
 "total_words":SZ//4,
 "code_regions":[[a,b] for a,b in CODE],
 "skip_intervals":[[a,b,t] for a,b,t in SKIP],
 "instructions_decoded":len(ALL_INSNS),
 "literal_pool_words":len(LIT),
 "pc_relative_ldr":len(pc_lit_pairs),
 "call_edges":len(CALL),
 "distinct_call_targets":len(set(t for c,t,m in CALL)),
 "function_entries":len(ENTRY),
 "functions":len(FUNCS),
 "prologues":len(PROLOGUE),
 "mmio_literal_hits":[[hex(a),hex(b),hex(w)] for a,b,w in MMIO_HITS],
 "mmio_functions":["0x%08x"%x for x in sorted(MMIO_FUNCS)],
 "display_token_lit_funcs":["0x%08x"%x for x in sorted(DISPLAY_LITFUNCS)],
 "display_tokens_found":{("%08x"%(k-BASE)):v.decode("latin1") for k,v in TOK_ADDR.items()},
 "reset_target":hex(reset_t),
 "functions_raw":[{"entry":hex(e),"end":hex(end)} for e,end in FUNCS],
}
json.dump(ledger,open(os.path.join(OUT,"analysis_p01.json"),"w"),indent=1)

print("instructions_decoded =",len(ALL_INSNS))
print("code_regions =",len(CODE),"skip_intervals =",len(SKIP))
print("pc_relative_ldr =",len(pc_lit_pairs),"literal words =",len(LIT))
print("call_edges =",len(CALL),"distinct targets =",len(set(t for c,t,m in CALL)))
print("prologues =",len(PROLOGUE),"function_entries =",len(ENTRY),"functions =",len(FUNCS))
print("mmio literal hits =",len(MMIO_HITS),"mmio funcs =",len(MMIO_FUNCS))
print("display token lit funcs =",len(DISPLAY_LITFUNCS))
print("reset target =",hex(reset_t))
print("display tokens found =",len(TOK_ADDR))
