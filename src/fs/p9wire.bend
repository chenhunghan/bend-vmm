import Base
import ../lib/u64.bend as U
import ../lib/bytes.bend as B

# The 9P2000.L wire format (the protocol Linux's v9fs speaks over virtio).
# A message is size[4] type[1] tag[2] then its fields, all little-endian;
# size counts the whole message. A string s is len[2] then its bytes; a qid
# is type[1] version[4] path[8]. Message types and fields (decimal):
#   Tstatfs 8 fid[4]              Rstatfs 9 type[4] bsize[4] blocks[8] bfree[8]
#                                    bavail[8] files[8] ffree[8] fsid[8] namelen[4]
#   Tlopen 12 fid[4] flags[4]     Rlopen 13 qid iounit[4]
#   Tlcreate 14 fid[4] name[s] flags[4] mode[4] gid[4]   Rlcreate 15 qid iounit[4]
#   Tsymlink 16 fid[4] name[s] symtgt[s] gid[4]          Rsymlink 17 qid
#   Treadlink 22 fid[4]           Rreadlink 23 target[s]
#   Tgetattr 24 fid[4] request_mask[8]
#                                 Rgetattr 25 valid[8] qid mode[4] uid[4] gid[4]
#                                    nlink[8] rdev[8] size[8] blksize[8] blocks[8]
#                                    atime_sec[8] atime_nsec[8] mtime_sec[8]
#                                    mtime_nsec[8] ctime_sec[8] ctime_nsec[8]
#                                    btime_sec[8] btime_nsec[8] gen[8] data_version[8]
#   Tsetattr 26 fid[4] valid[4] mode[4] uid[4] gid[4] size[8] atime_sec[8]
#                 atime_nsec[8] mtime_sec[8] mtime_nsec[8]   Rsetattr 27
#   Txattrwalk 30 fid[4] newfid[4] name[s]   (answered with Rlerror)
#   Treaddir 40 fid[4] offset[8] count[4]
#                                 Rreaddir 41 count[4] then count bytes of
#                                    entries: qid offset[8] type[1] name[s]
#   Tfsync 50 fid[4] datasync[4]  Rfsync 51
#   Tmkdir 72 dfid[4] name[s] mode[4] gid[4]             Rmkdir 73 qid
#   Trenameat 74 olddirfid[4] oldname[s] newdirfid[4] newname[s]  Rrenameat 75
#   Tunlinkat 76 dirfd[4] name[s] flags[4]               Runlinkat 77
#   Tversion 100 msize[4] version[s]                     Rversion 101 msize[4] version[s]
#   Tattach 104 fid[4] afid[4] uname[s] aname[s] n_uname[4]   Rattach 105 qid
#   Tflush 108 oldtag[2]          Rflush 109
#   Twalk 110 fid[4] newfid[4] nwname[2] wname[s]*nwname
#                                 Rwalk 111 nwqid[2] qid*nwqid
#   Tread 116 fid[4] offset[8] count[4]                  Rread 117 count[4] data
#   Twrite 118 fid[4] offset[8] count[4] data            Rwrite 119 count[4]
#   Tclunk 120 fid[4]             Rclunk 121
#   Rlerror 7 ecode[4] (a Linux errno)
# Strings are byte strings here (+List<U32>), not decoded text.

type Qid is Data:
  Qid{kind: U32, version: U32, path: U.U64}

type P9Req is Data:
  Tstatfs{fid: U32}
  Tlopen{fid: U32, flags: U32}
  Tlcreate{fid: U32, name: +List<U32>, flags: U32, mode: U32, gid: U32}
  Tsymlink{fid: U32, name: +List<U32>, target: +List<U32>, gid: U32}
  Treadlink{fid: U32}
  Tgetattr{fid: U32, mask: U.U64}
  Tsetattr{fid: U32, valid: U32, mode: U32, uid: U32, gid: U32, size: U.U64}
  Txattrwalk{fid: U32, newfid: U32, name: +List<U32>}
  Treaddir{fid: U32, offset: U.U64, count: U32}
  Tfsync{fid: U32}
  Tmkdir{dfid: U32, name: +List<U32>, mode: U32, gid: U32}
  Trenameat{olddir: U32, oldname: +List<U32>, newdir: U32, newname: +List<U32>}
  Tunlinkat{dir: U32, name: +List<U32>, flags: U32}
  Tversion{msize: U32, version: +List<U32>}
  Tattach{fid: U32, afid: U32, uname: +List<U32>, aname: +List<U32>, n_uname: U32}
  Tflush{oldtag: U32}
  Twalk{fid: U32, newfid: U32, names: +List<+List<U32>>}
  Tread{fid: U32, offset: U.U64, count: U32}
  Twrite{fid: U32, offset: U.U64, data: +List<U32>}
  Tclunk{fid: U32}
  # A message type this server does not know.
  Tunknown{kind: U32}

# Rgetattr carries the full stat; the fields not listed (rdev, the nsec
# parts, btime, gen, data_version) are written as zero, valid as 2047
# (P9_GETATTR_BASIC), blksize as 4096.
type P9Stat is Data:
  P9Stat{qid: Qid, mode: U32, uid: U32, gid: U32, nlink: U.U64, size: U.U64, blocks: U.U64, atime: U.U64, mtime: U.U64, ctime: U.U64}

# A directory entry in an Rreaddir: qid, the offset of the next entry, the
# type (DT_* value), the name.
type P9Dirent is Data:
  P9Dirent{qid: Qid, next: U.U64, kind: U32, name: +List<U32>}

type P9Resp is Data:
  Rlerror{ecode: U32}
  Rstatfs{bsize: U32, blocks: U.U64, bfree: U.U64, bavail: U.U64, files: U.U64, ffree: U.U64}
  Rlopen{qid: Qid, iounit: U32}
  Rlcreate{qid: Qid, iounit: U32}
  Rsymlink{qid: Qid}
  Rreadlink{target: +List<U32>}
  Rgetattr{stat: P9Stat}
  Rsetattr{}
  Rreaddir{entries: +List<P9Dirent>}
  Rfsync{}
  Rmkdir{qid: Qid}
  Rrenameat{}
  Runlinkat{}
  Rversion{msize: U32, version: +List<U32>}
  Rattach{qid: Qid}
  Rflush{}
  Rwalk{qids: +List<Qid>}
  Rread{data: +List<U32>}
  Rwrite{count: U32}
  Rclunk{}

# A request: its tag and the decoded message. None when the bytes are not a
# whole message (short, size field disagreeing, or fields running past it).
# Rstatfs writes type 0x01021997 (V9FS_MAGIC), fsid 0 and namelen 255.
type P9Msg is Data:
  P9Msg{tag: U32, req: P9Req}

def P9.parse(bs: +List<U32>) -> Maybe<&2, P9Msg>:
  ?TODO

def P9.build(tag: U32, r: P9Resp) -> +List<U32>:
  ?TODO
