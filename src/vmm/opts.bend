import Base

# The VMM's options (laws/opts.bend): the record the command line fills,
# flag by flag, once src/vmm/cli.bend found nothing wrong with it; and the
# restore policy: a snapshot's own options (its saved command line), with
# this run's --control and --forward, and the host files and sockets it may
# use only when this command line names the same ones.

type Opts is Data:
  Opts{kernel: String, initrd: String, payload: String, cmdline: String, mem: U32, cpus: U32, disk: String, share: String, restore: String, control: String, vsock: String, display: String, firmware: String, vars: String, forward: String, lan: String}

def Opts.default() -> Opts:
  Opts{"", "", "", "console=ttyAMA0 earlycon=pl011,0x9000000", 512, 1, "", "", "", "", "", "", "", "", "", ""}

def Opts.mem(o: Opts) -> U32:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      m

def Opts.disk(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      d

def Opts.kernel(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      k

def Opts.share(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      sh

def Opts.restore(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      rs

def Opts.control(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      ct

def Opts.cpus(o: Opts) -> U32:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      n

def Opts.vsock(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      vk

def Opts.firmware(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      fw

def Opts.vars(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      nv

def Opts.forward(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      fd

def Opts.lan(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      ln

def Opts.display(o: Opts) -> String:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      dp


def Opts.num(s: String, d: U32) -> U32:
  Maybe.default(&2, U32, U32.read(s), d)

def Opts.set(+flag: String, +v: String, o: Opts) -> Opts:
  match o:
    case Opts{k, i, p, c, +m, +n, d, sh, rs, ct, vk, dp, fw, nv, +fd, ln}:
      Opts{
        Bool.pick(String, String.eq(flag, "--kernel"), v, k),
        Bool.pick(String, String.eq(flag, "--initrd"), v, i),
        Bool.pick(String, String.eq(flag, "--payload"), v, p),
        Bool.pick(String, String.eq(flag, "--cmdline"), v, c),
        Bool.pick(U32, String.eq(flag, "--mem"), Opts.num(v, m), m),
        Bool.pick(U32, String.eq(flag, "--cpus"), Opts.num(v, n), n),
        Bool.pick(String, String.eq(flag, "--disk"), v, d),
        Bool.pick(String, String.eq(flag, "--share"), v, sh),
        Bool.pick(String, String.eq(flag, "--restore"), v, rs),
        Bool.pick(String, String.eq(flag, "--control"), v, ct),
        Bool.pick(String, String.eq(flag, "--vsock"), v, vk),
        Bool.pick(String, String.eq(flag, "--display"), v, dp),
        Bool.pick(String, String.eq(flag, "--firmware"), v, fw),
        Bool.pick(String, String.eq(flag, "--vars"), v, nv),
        # --forward may be given more than once: the lists join
        Bool.pick(String, String.eq(flag, "--forward"), Bool.pick(String, String.is_empty(fd), v, fd ++ "," ++ v), fd),
        Bool.pick(String, String.eq(flag, "--lan"), v, ln)
      }

def Opts.parse(args: List<String>, o: Opts) -> Opts:
  match args:
    case Nil{}:
      o
    case Con{flag, rest}:
      match rest:
        case Nil{}:
          o
        case Con{v, more}:
          Opts.parse(more, Opts.set(flag, v, o))

# o with this run's --forward (forwards are not the snapshot's: they come
# from the command line that restores it).
def Opts.with_forward(o: Opts, fd: String) -> Opts:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, was, ln}:
      Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}


# o with the RAM and vCPUs a restore makes (the snapshot header's).
def Opts.with_size(o: Opts, mem: U32, cpus: U32) -> Opts:
  match o:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      Opts{k, i, p, c, mem, cpus, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}

# Options for a restore: the snapshot's own (its saved command line, past
# the program's words), with this run's --control and --forward.
def Restore.opts(saved: List<String>, now: Opts) -> Opts:
  match now:
    case Opts{k, i, p, c, m, n, d, sh, rs, ct, vk, dp, fw, nv, fd, ln}:
      Opts.with_forward(Opts.set("--control", ct, Opts.parse(List.drop(&1, String, saved, 1n), Opts.default())), fd)


# A snapshot names the host files and sockets its devices use. Restoring it
# opens them only when this command line names the same ones, so a snapshot
# from elsewhere cannot choose what to open, share or replace: the first
# flag that differs, as a message ("" when none does).
def Restore.differs.one(+flag: String, +was: String, +now: String) -> String:
  Bool.pick(String, String.eq(was, now), "",
    Bool.pick(String, String.is_empty(was),
      "the snapshot was taken without " ++ flag ++ "; restore it without " ++ flag,
      "the snapshot was taken with " ++ flag ++ " " ++ was ++ "; pass the same " ++ flag ++ " to restore it"))

def Restore.differs.first(+a: String, b: String) -> String:
  Bool.pick(String, String.is_empty(a), b, a)

def Restore.differs(+was: Opts, +now: Opts) -> String:
  Restore.differs.first(Restore.differs.one("--disk", Opts.disk(was), Opts.disk(now)),
    Restore.differs.first(Restore.differs.one("--share", Opts.share(was), Opts.share(now)),
      Restore.differs.first(Restore.differs.one("--vsock", Opts.vsock(was), Opts.vsock(now)),
        Restore.differs.first(Restore.differs.one("--firmware", Opts.firmware(was), Opts.firmware(now)),
          Restore.differs.first(Restore.differs.one("--vars", Opts.vars(was), Opts.vars(now)),
            Restore.differs.one("--lan", Opts.lan(was), Opts.lan(now)))))))
