import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B
import ../vmm/abi.bend as V
import ../virtio/queue.bend as Q
import ./p9wire.bend as W

# A 9P2000.L server over the host's shared directory (V.FsOp effects), and
# the virtio-9p request queue (Virtio 1.2 section 5.11: device id 9, feature
# VIRTIO_9P_MOUNT_TAG bit 0, config tag_len[2] tag; one queue). The guest
# mounts it with: mount -t 9p -o trans=virtio,version=9P2000.L <tag> /mnt
#
# State: msize and the fid table, each fid naming a path relative to the
# share ("" is its root) and whether it was opened.
# Behaviour:
#   Tversion: msize = min(requested, 65536); version "9P2000.L" if requested
#     exactly, else "unknown". Resets the fid table.
#   Tattach: fid -> "" (root), Rattach with the root's qid (from FsStat).
#   Twalk: newfid -> fid's path extended by each name, stopping at the first
#     name that does not exist (FsStat fails): Rwalk with the qids found. If
#     the first name fails, Rlerror. newfid is bound only if all names were
#     walked (or there were none: a clone). Names "." / ".." / containing
#     "/" or NUL are refused with EINVAL (".." of the root is the root).
#   Tgetattr: FsStat -> Rgetattr. Tsetattr: mode (valid bit 0) -> FsChmod,
#     size (valid bit 3) -> FsTruncate; other bits ignored -> Rsetattr.
#   Tlopen: marks the fid open, Rlopen with its qid and iounit msize - 24.
#   Tlcreate: FsCreate(dir path + "/" + name); the fid now names the new
#     file, opened. Tmkdir, Tsymlink: FsMkdir, FsSymlink, answer the new qid.
#   Tread: FsRead (count capped to msize - 11) -> Rread.
#   Twrite: FsWrite -> Rwrite with FsCount.
#   Treaddir: FsList(path, offset, n) -> Rreaddir, as many entries as fit in
#     count bytes; offsets are entry indexes (next = index + 1).
#   Tunlinkat: FsRemove(dir + "/" + name, flags has AT_REMOVEDIR 512).
#   Trenameat: FsRename. Treadlink: FsReadlink. Tstatfs: FsStatfs.
#   Tfsync: Rfsync. Tflush: Rflush. Tclunk: drops the fid, Rclunk.
#   Txattrwalk, Tunknown: Rlerror EOPNOTSUPP (95).
#   An unknown fid: Rlerror EBADF (9). A host error: Rlerror with its macOS
#   errno translated to Linux's (P9.linux_errno).
# Qids: type 128 (QTDIR) for directories, 2 (QTSYMLINK) for symlinks, 0
# otherwise; version 0; path = inode.

type Fid is Data:
  Fid{fid: U32, path: String, open: Bool}

type P9State is Data:
  P9State{msize: U32, fids: +List<Fid>}

def P9State.new() -> P9State:
  P9State{8192, []}

# The Linux errno for a macOS errno (equal below 35; EAGAIN 35 -> 11,
# ENOTEMPTY 66 -> 39, ENAMETOOLONG 63 -> 36, ELOOP 62 -> 40, ENOSYS 78 -> 38,
# ENOTSUP 45 -> 95, others unchanged).
def P9.linux_errno(e: U32) -> U32:
  ?TODO

# The config space for a mount tag.
def P9.config(tag: String) -> +List<U32>:
  ?TODO

type P9Answer is Data:
  P9Answer{state: P9State, reply: +List<U32>}

# Serves one request on share `share`.
def P9.serve(-R: Type, share: U32, s: P9State, m: W.P9Msg) -> V.Op<R, P9Answer>:
  ?TODO

type P9Pass is Data:
  P9Pass{state: P9State, q: Q.Vq, used: Bool}

# Serves every available chain (at most num): the request is the chain's
# readable bytes, the reply goes to its writable descriptors, pushed used with
# the reply's length. A malformed request gets Rlerror EINVAL with tag 65535.
def P9.process(-R: Type, share: U32, s: P9State, q: Q.Vq) -> V.Op<R, P9Pass>:
  ?TODO
