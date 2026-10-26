import Base
import ../lib/u64.bend as U
import ../lib/dec.bend as X
import ../arm64/psci.bend as P
import ../dev/pl011.bend as Uart
import ../dev/pl031.bend as Rtc
import ../dev/pflash.bend as Pf
import ../net/nat.bend as Nt
import ../virtio/mmio.bend as M
import ../virtio/queue.bend as Q
import ../virtio/device.bend as D
import ../fs/p9.bend as F
import ../virtio/vsock.bend as Vs
import ../virtio/input.bend as In
import ./machine.bend as Mc

# The machine's device state as a stream of 32-bit words, for snapshots.
# Snap.encode and Snap.decode are inverses (laws/snapshot.bend). The stream
# starts with the magic 1112428109 ("BVMS" read as a little-endian word, 0x534d5642)
# and the format version 2 (2 added the UEFI flash state); lists and strings are length-prefixed; a sum type
# writes its constructor's index first. The host stores this next to guest
# RAM, vCPU registers and the GIC state (host/hvf.c, "Snapshots").

def Snap.magic() -> U32:
  1112428109

def Snap.version() -> U32:
  2

# Encoders
# ========

def Enc.bools(bs: +List<Bool>) -> +List<U32>:
  match bs:
    case Nil{}:
      []
    case Con{b, rest}:
      Bool.to_u32(b) <> Enc.bools(rest)

def Enc.frames(fs: +List<+List<U32>>) -> +List<U32>:
  match fs:
    case Nil{}:
      []
    case Con{f, rest}:
      List.append(&2, U32, X.Enc.bytes(f), Enc.frames(rest))

def Enc.len(-A: Data, +xs: +List<A>) -> U32:
  U32.from_nat(List.length(&2, A, xs))

def Enc.psci(s: P.PsciState) -> +List<U32>:
  match s:
    case P.PsciState{+on}:
      Enc.len(Bool, on) <> Enc.bools(on)

def Enc.pl011(s: Uart.Pl011) -> +List<U32>:
  match s:
    case Uart.Pl011{i, f, l, c, fl, m, rx}:
      List.append(&2, U32, [i, f, l, c, fl, m], X.Enc.bytes(rx))

def Enc.pl031(s: Rtc.Pl031) -> +List<U32>:
  match s:
    case Rtc.Pl031{o, mr, lr, im, ris}:
      [o, mr, lr, im, ris]

def Enc.conns(cs: +List<Nt.Conn>) -> +List<U32>:
  match cs:
    case Nil{}:
      []
    case Con{Nt.Conn{id, gp, rip, rp, st, gs, hs}, rest}:
      List.append(&2, U32, [id, gp, rip, rp, st, gs, hs], Enc.conns(rest))

def Enc.slirp(s: Nt.Slirp) -> +List<U32>:
  match s:
    case Nt.Slirp{+cs, next}:
      List.append(&2, U32, [Enc.len(Nt.Conn, cs), next], Enc.conns(cs))

def Enc.qcfgs(qs: +List<M.QueueCfg>) -> +List<U32>:
  match qs:
    case Nil{}:
      []
    case Con{M.QueueCfg{mx, n, r, d, dr, dv}, rest}:
      List.append(&2, U32, [mx, n, Bool.to_u32(r)], List.append(&2, U32, X.Enc.u64(d), List.append(&2, U32, X.Enc.u64(dr), List.append(&2, U32, X.Enc.u64(dv), Enc.qcfgs(rest)))))

def Enc.mmio(s: M.VirtioMmio) -> +List<U32>:
  match s:
    case M.VirtioMmio{id, df, drf, dsel, drsel, qsel, +qs, st, ist, cg, cfg}:
      +head = {List.append(&2, U32, [id], List.append(&2, U32, X.Enc.u64(df), X.Enc.u64(drf))) : +List<U32>}
      +mid = {[dsel, drsel, qsel, Enc.len(M.QueueCfg, qs)] : +List<U32>}
      List.append(&2, U32, head, List.append(&2, U32, mid, List.append(&2, U32, Enc.qcfgs(qs), List.append(&2, U32, [st, ist, cg], X.Enc.bytes(cfg)))))

def Enc.vqs(qs: +List<Q.Vq>) -> +List<U32>:
  match qs:
    case Nil{}:
      []
    case Con{Q.Vq{n, d, dr, dv, na, nu}, rest}:
      List.append(&2, U32, [n], List.append(&2, U32, X.Enc.u64(d), List.append(&2, U32, X.Enc.u64(dr), List.append(&2, U32, X.Enc.u64(dv), List.append(&2, U32, [na, nu], Enc.vqs(rest))))))

def Enc.kind(k: D.DevKind) -> +List<U32>:
  match k:
    case D.RngKind{}:
      [0]
    case D.BlkKind{d, s}:
      List.append(&2, U32, [1, d], X.Enc.u64(s))
    case D.BlkRoKind{d, s}:
      List.append(&2, U32, [2, d], X.Enc.u64(s))
    case D.ConsoleKind{}:
      [3]
    case D.NetKind{mac}:
      4 <> X.Enc.bytes(mac)
    case D.P9Kind{sh, tag}:
      List.append(&2, U32, [5, sh], X.Enc.string(tag))
    case D.VsockKind{cid}:
      6 <> X.Enc.u64(cid)
    case D.InputKind{tablet}:
      [7, Bool.to_u32(tablet)]

def Enc.fids(fs: +List<F.Fid>) -> +List<U32>:
  match fs:
    case Nil{}:
      []
    case Con{F.Fid{fid, path, open}, rest}:
      List.append(&2, U32, fid <> X.Enc.string(path), List.append(&2, U32, [Bool.to_u32(open)], Enc.fids(rest)))

def Enc.vconns(cs: +List<Vs.VConn>) -> +List<U32>:
  match cs:
    case Nil{}:
      []
    case Con{Vs.VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof}, rest}:
      List.append(&2, U32, [id, gp, hp, st, tx, pa, pf, fwd, lf], List.append(&2, U32, X.Enc.bytes(pend), Bool.to_u32(eof) <> Enc.vconns(rest)))

def Enc.vsock(v: Vs.Vsock) -> +List<U32>:
  match v:
    case Vs.Vsock{cid, +cs, nid, np, +out}:
      List.append(&2, U32, X.Enc.u64(cid), List.append(&2, U32, [nid, np, Enc.len(Vs.VConn, cs)], List.append(&2, U32, Enc.vconns(cs), Enc.len(+List<U32>, out) <> Enc.frames(out))))

def Enc.state(s: D.DevState) -> +List<U32>:
  match s:
    case D.NoState{}:
      [0]
    case D.ConState{input}:
      1 <> X.Enc.bytes(input)
    case D.NetState{+fs}:
      List.append(&2, U32, [2, Enc.len(+List<U32>, fs)], Enc.frames(fs))
    case D.P9Dev{F.P9State{ms, +fids}}:
      List.append(&2, U32, [3, ms, Enc.len(F.Fid, fids)], Enc.fids(fids))
    case D.VsState{v}:
      4 <> Enc.vsock(v)
    case D.InDev{In.InputState{sel, sub, +evs}}:
      List.append(&2, U32, [5, sel, sub, Enc.len(+List<U32>, evs)], Enc.frames(evs))

def Enc.dev(d: D.Dev) -> +List<U32>:
  match d:
    case D.Dev{k, m, +qs, s}:
      List.append(&2, U32, Enc.kind(k), List.append(&2, U32, Enc.mmio(m), List.append(&2, U32, Enc.len(Q.Vq, qs) <> Enc.vqs(qs), Enc.state(s))))

def Enc.devs(ds: +List<D.Dev>) -> +List<U32>:
  match ds:
    case Nil{}:
      []
    case Con{d, rest}:
      List.append(&2, U32, Enc.dev(d), Enc.devs(rest))

def Enc.pflash(f: Pf.Pflash) -> +List<U32>:
  match f:
    case Pf.Pflash{m, at, n, d}:
      List.append(&2, U32, [m, at, n], X.Enc.bytes(d))

def Snap.encode(m: Mc.Machine) -> +List<U32>:
  match m:
    case Mc.Machine{ps, uart, uirq, +devs, +lines, rtc, rirq, net, fl}:
      +a = {List.append(&2, U32, [Snap.magic(), Snap.version()], List.append(&2, U32, Enc.psci(ps), Enc.pl011(uart))) : +List<U32>}
      +b = {List.append(&2, U32, [Bool.to_u32(uirq), Enc.len(D.Dev, devs)], Enc.devs(devs)) : +List<U32>}
      +c = {List.append(&2, U32, Enc.len(Bool, lines) <> Enc.bools(lines), List.append(&2, U32, Enc.pl031(rtc), Bool.to_u32(rirq) <> List.append(&2, U32, Enc.slirp(net), Enc.pflash(fl)))) : +List<U32>}
      List.append(&2, U32, a, List.append(&2, U32, b, c))

# Decoders
# ========

def Dec.bools(n: Nat) -> X.Dec<+List<Bool>>:
  match n:
    case 0n:
      X.Dec.pure(+List<Bool>, [])
    case 1n+p:
      do X.Dec<+List<Bool>>:
        b : Bool <- X.Dec.bool()
        bs : +List<Bool> <- Dec.bools(p)
        return b <> bs

def Dec.count() -> X.Dec<Nat>:
  do X.Dec<Nat>:
    n : U32 <- X.Dec.u32()
    return U32.to_nat(n)

def Dec.frames(n: Nat) -> X.Dec<+List<+List<U32>>>:
  match n:
    case 0n:
      X.Dec.pure(+List<+List<U32>>, [])
    case 1n+p:
      do X.Dec<+List<+List<U32>>>:
        f : +List<U32> <- X.Dec.bytes()
        fs : +List<+List<U32>> <- Dec.frames(p)
        return f <> fs

def Dec.psci() -> X.Dec<P.PsciState>:
  do X.Dec<P.PsciState>:
    n : Nat <- Dec.count()
    on : +List<Bool> <- Dec.bools(n)
    return P.PsciState{on}

def Dec.pl011() -> X.Dec<Uart.Pl011>:
  do X.Dec<Uart.Pl011>:
    i : U32 <- X.Dec.u32()
    f : U32 <- X.Dec.u32()
    l : U32 <- X.Dec.u32()
    c : U32 <- X.Dec.u32()
    fl : U32 <- X.Dec.u32()
    m : U32 <- X.Dec.u32()
    rx : +List<U32> <- X.Dec.bytes()
    return Uart.Pl011{i, f, l, c, fl, m, rx}

def Dec.pl031() -> X.Dec<Rtc.Pl031>:
  do X.Dec<Rtc.Pl031>:
    o : U32 <- X.Dec.u32()
    mr : U32 <- X.Dec.u32()
    lr : U32 <- X.Dec.u32()
    im : U32 <- X.Dec.u32()
    ris : U32 <- X.Dec.u32()
    return Rtc.Pl031{o, mr, lr, im, ris}

def Dec.conns(n: Nat) -> X.Dec<+List<Nt.Conn>>:
  match n:
    case 0n:
      X.Dec.pure(+List<Nt.Conn>, [])
    case 1n+p:
      do X.Dec<+List<Nt.Conn>>:
        id : U32 <- X.Dec.u32()
        gp : U32 <- X.Dec.u32()
        rip : U32 <- X.Dec.u32()
        rp : U32 <- X.Dec.u32()
        st : U32 <- X.Dec.u32()
        gs : U32 <- X.Dec.u32()
        hs : U32 <- X.Dec.u32()
        rest : +List<Nt.Conn> <- Dec.conns(p)
        return Nt.Conn{id, gp, rip, rp, st, gs, hs} <> rest

def Dec.slirp() -> X.Dec<Nt.Slirp>:
  do X.Dec<Nt.Slirp>:
    n : Nat <- Dec.count()
    next : U32 <- X.Dec.u32()
    cs : +List<Nt.Conn> <- Dec.conns(n)
    return Nt.Slirp{cs, next}

def Dec.qcfgs(n: Nat) -> X.Dec<+List<M.QueueCfg>>:
  match n:
    case 0n:
      X.Dec.pure(+List<M.QueueCfg>, [])
    case 1n+p:
      do X.Dec<+List<M.QueueCfg>>:
        mx : U32 <- X.Dec.u32()
        num : U32 <- X.Dec.u32()
        r : Bool <- X.Dec.bool()
        d : U.U64 <- X.Dec.u64()
        dr : U.U64 <- X.Dec.u64()
        dv : U.U64 <- X.Dec.u64()
        rest : +List<M.QueueCfg> <- Dec.qcfgs(p)
        return M.QueueCfg{mx, num, r, d, dr, dv} <> rest

def Dec.mmio() -> X.Dec<M.VirtioMmio>:
  do X.Dec<M.VirtioMmio>:
    id : U32 <- X.Dec.u32()
    df : U.U64 <- X.Dec.u64()
    drf : U.U64 <- X.Dec.u64()
    dsel : U32 <- X.Dec.u32()
    drsel : U32 <- X.Dec.u32()
    qsel : U32 <- X.Dec.u32()
    nq : Nat <- Dec.count()
    qs : +List<M.QueueCfg> <- Dec.qcfgs(nq)
    st : U32 <- X.Dec.u32()
    ist : U32 <- X.Dec.u32()
    cg : U32 <- X.Dec.u32()
    cfg : +List<U32> <- X.Dec.bytes()
    return M.VirtioMmio{id, df, drf, dsel, drsel, qsel, qs, st, ist, cg, cfg}

def Dec.vqs(n: Nat) -> X.Dec<+List<Q.Vq>>:
  match n:
    case 0n:
      X.Dec.pure(+List<Q.Vq>, [])
    case 1n+p:
      do X.Dec<+List<Q.Vq>>:
        num : U32 <- X.Dec.u32()
        d : U.U64 <- X.Dec.u64()
        dr : U.U64 <- X.Dec.u64()
        dv : U.U64 <- X.Dec.u64()
        na : U32 <- X.Dec.u32()
        nu : U32 <- X.Dec.u32()
        rest : +List<Q.Vq> <- Dec.vqs(p)
        return Q.Vq{num, d, dr, dv, na, nu} <> rest

def Dec.blk(ro: Bool, d: U32, s: U.U64) -> D.DevKind:
  match ro:
    case True{}:
      D.BlkRoKind{d, s}
    case False{}:
      D.BlkKind{d, s}

def Dec.kind.blk(ro: Bool) -> X.Dec<D.DevKind>:
  do X.Dec<D.DevKind>:
    d : U32 <- X.Dec.u32()
    s : U.U64 <- X.Dec.u64()
    return Dec.blk(ro, d, s)

def Dec.kind.net() -> X.Dec<D.DevKind>:
  do X.Dec<D.DevKind>:
    mac : +List<U32> <- X.Dec.bytes()
    return D.NetKind{mac}

def Dec.kind.p9() -> X.Dec<D.DevKind>:
  do X.Dec<D.DevKind>:
    sh : U32 <- X.Dec.u32()
    tag : String <- X.Dec.string()
    return D.P9Kind{sh, tag}

def Dec.kind.vsock() -> X.Dec<D.DevKind>:
  do X.Dec<D.DevKind>:
    cid : U.U64 <- X.Dec.u64()
    return D.VsockKind{cid}

def Dec.kind.input() -> X.Dec<D.DevKind>:
  do X.Dec<D.DevKind>:
    tablet : Bool <- X.Dec.bool()
    return D.InputKind{tablet}

def Dec.kind.by(t0: Bool, t1: Bool, t2: Bool, t3: Bool, t4: Bool, t5: Bool, t6: Bool, t7: Bool) -> X.Dec<D.DevKind>:
  match t0 t1 t2 t3 t4 t5 t6 t7:
    case True{} _ _ _ _ _ _ _:
      X.Dec.pure(D.DevKind, D.RngKind{})
    case False{} True{} _ _ _ _ _ _:
      Dec.kind.blk(False{})
    case False{} False{} True{} _ _ _ _ _:
      Dec.kind.blk(True{})
    case False{} False{} False{} True{} _ _ _ _:
      X.Dec.pure(D.DevKind, D.ConsoleKind{})
    case False{} False{} False{} False{} True{} _ _ _:
      Dec.kind.net()
    case False{} False{} False{} False{} False{} True{} _ _:
      Dec.kind.p9()
    case False{} False{} False{} False{} False{} False{} True{} _:
      Dec.kind.vsock()
    case False{} False{} False{} False{} False{} False{} False{} True{}:
      Dec.kind.input()
    case False{} False{} False{} False{} False{} False{} False{} False{}:
      X.Dec.fail(D.DevKind)

def Dec.kind() -> X.Dec<D.DevKind>:
  do X.Dec<D.DevKind>:
    +t : U32 <- X.Dec.u32()
    Dec.kind.by(U32.is_eq(t, 0), U32.is_eq(t, 1), U32.is_eq(t, 2), U32.is_eq(t, 3), U32.is_eq(t, 4), U32.is_eq(t, 5), U32.is_eq(t, 6), U32.is_eq(t, 7))

def Dec.fids(n: Nat) -> X.Dec<+List<F.Fid>>:
  match n:
    case 0n:
      X.Dec.pure(+List<F.Fid>, [])
    case 1n+p:
      do X.Dec<+List<F.Fid>>:
        fid : U32 <- X.Dec.u32()
        path : String <- X.Dec.string()
        open : Bool <- X.Dec.bool()
        rest : +List<F.Fid> <- Dec.fids(p)
        return F.Fid{fid, path, open} <> rest

def Dec.state.con() -> X.Dec<D.DevState>:
  do X.Dec<D.DevState>:
    input : +List<U32> <- X.Dec.bytes()
    return D.ConState{input}

def Dec.state.net() -> X.Dec<D.DevState>:
  do X.Dec<D.DevState>:
    n : Nat <- Dec.count()
    fs : +List<+List<U32>> <- Dec.frames(n)
    return D.NetState{fs}

def Dec.state.p9() -> X.Dec<D.DevState>:
  do X.Dec<D.DevState>:
    ms : U32 <- X.Dec.u32()
    n : Nat <- Dec.count()
    fids : +List<F.Fid> <- Dec.fids(n)
    return D.P9Dev{F.P9State{ms, fids}}

def Dec.vconns(n: Nat) -> X.Dec<+List<Vs.VConn>>:
  match n:
    case 0n:
      X.Dec.pure(+List<Vs.VConn>, [])
    case 1n+p:
      do X.Dec<+List<Vs.VConn>>:
        id : U32 <- X.Dec.u32()
        gp : U32 <- X.Dec.u32()
        hp : U32 <- X.Dec.u32()
        st : U32 <- X.Dec.u32()
        tx : U32 <- X.Dec.u32()
        pa : U32 <- X.Dec.u32()
        pf : U32 <- X.Dec.u32()
        fwd : U32 <- X.Dec.u32()
        lf : U32 <- X.Dec.u32()
        pend : +List<U32> <- X.Dec.bytes()
        eof : Bool <- X.Dec.bool()
        rest : +List<Vs.VConn> <- Dec.vconns(p)
        return Vs.VConn{id, gp, hp, st, tx, pa, pf, fwd, lf, pend, eof} <> rest

def Dec.state.vsock() -> X.Dec<D.DevState>:
  do X.Dec<D.DevState>:
    cid : U.U64 <- X.Dec.u64()
    nid : U32 <- X.Dec.u32()
    np : U32 <- X.Dec.u32()
    nc : Nat <- Dec.count()
    cs : +List<Vs.VConn> <- Dec.vconns(nc)
    no : Nat <- Dec.count()
    out : +List<+List<U32>> <- Dec.frames(no)
    return D.VsState{Vs.Vsock{cid, cs, nid, np, out}}

def Dec.state.input() -> X.Dec<D.DevState>:
  do X.Dec<D.DevState>:
    sel : U32 <- X.Dec.u32()
    sub : U32 <- X.Dec.u32()
    n : Nat <- Dec.count()
    evs : +List<+List<U32>> <- Dec.frames(n)
    return D.InDev{In.InputState{sel, sub, evs}}

def Dec.state.by(t0: Bool, t1: Bool, t2: Bool, t3: Bool, t4: Bool, t5: Bool) -> X.Dec<D.DevState>:
  match t0 t1 t2 t3 t4 t5:
    case True{} _ _ _ _ _:
      X.Dec.pure(D.DevState, D.NoState{})
    case False{} True{} _ _ _ _:
      Dec.state.con()
    case False{} False{} True{} _ _ _:
      Dec.state.net()
    case False{} False{} False{} True{} _ _:
      Dec.state.p9()
    case False{} False{} False{} False{} True{} _:
      Dec.state.vsock()
    case False{} False{} False{} False{} False{} True{}:
      Dec.state.input()
    case False{} False{} False{} False{} False{} False{}:
      X.Dec.fail(D.DevState)

def Dec.state() -> X.Dec<D.DevState>:
  do X.Dec<D.DevState>:
    +t : U32 <- X.Dec.u32()
    Dec.state.by(U32.is_eq(t, 0), U32.is_eq(t, 1), U32.is_eq(t, 2), U32.is_eq(t, 3), U32.is_eq(t, 4), U32.is_eq(t, 5))

def Dec.dev() -> X.Dec<D.Dev>:
  do X.Dec<D.Dev>:
    k : D.DevKind <- Dec.kind()
    m : M.VirtioMmio <- Dec.mmio()
    nq : Nat <- Dec.count()
    qs : +List<Q.Vq> <- Dec.vqs(nq)
    s : D.DevState <- Dec.state()
    return D.Dev{k, m, qs, s}

def Dec.devs(n: Nat) -> X.Dec<+List<D.Dev>>:
  match n:
    case 0n:
      X.Dec.pure(+List<D.Dev>, [])
    case 1n+p:
      do X.Dec<+List<D.Dev>>:
        d : D.Dev <- Dec.dev()
        ds : +List<D.Dev> <- Dec.devs(p)
        return d <> ds

def Dec.header.ok(ok: Bool) -> X.Dec<Unit>:
  match ok:
    case True{}:
      X.Dec.pure(Unit, Unit{})
    case False{}:
      X.Dec.fail(Unit)

def Dec.pflash() -> X.Dec<Pf.Pflash>:
  do X.Dec<Pf.Pflash>:
    m : U32 <- X.Dec.u32()
    at : U32 <- X.Dec.u32()
    n : U32 <- X.Dec.u32()
    d : +List<U32> <- X.Dec.bytes()
    return Pf.Pflash{m, at, n, d}

def Dec.machine() -> X.Dec<Mc.Machine>:
  do X.Dec<Mc.Machine>:
    magic : U32 <- X.Dec.u32()
    version : U32 <- X.Dec.u32()
    _ : Unit <- Dec.header.ok(U32.is_eq(magic, Snap.magic()) && U32.is_eq(version, Snap.version()))
    ps : P.PsciState <- Dec.psci()
    uart : Uart.Pl011 <- Dec.pl011()
    uirq : Bool <- X.Dec.bool()
    nd : Nat <- Dec.count()
    devs : +List<D.Dev> <- Dec.devs(nd)
    nl : Nat <- Dec.count()
    lines : +List<Bool> <- Dec.bools(nl)
    rtc : Rtc.Pl031 <- Dec.pl031()
    rirq : Bool <- X.Dec.bool()
    net : Nt.Slirp <- Dec.slirp()
    fl : Pf.Pflash <- Dec.pflash()
    return Mc.Machine{ps, uart, uirq, devs, lines, rtc, rirq, net, fl}

def Snap.decode.end(m: Mc.Machine, rest: +List<U32>) -> Maybe<&2, Mc.Machine>:
  match rest:
    case Nil{}:
      Some{m}
    case Con{w, more}:
      None{}

def Snap.decode.fin(r: Maybe<&1, Mc.Machine & +List<U32>>) -> Maybe<&2, Mc.Machine>:
  match r:
    case None{}:
      None{}
    case Some{(m, rest)}:
      Snap.decode.end(m, rest)

# The machine a snapshot stream holds; None when the stream is malformed or
# has words left over.
def Snap.decode(ws: +List<U32>) -> Maybe<&2, Mc.Machine>:
  Snap.decode.fin(X.Dec.run(Mc.Machine, Dec.machine(), ws))
