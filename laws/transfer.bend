import Base
import ../src/host/transfer.bend as X

# Spec for src/host/transfer.bend: what the host does with each answer of a
# short or failed transfer, and the lifetime of staged send buffers
# (C_TO_BEND.md, the pure models).

# An interrupted call is made again: no byte lost or counted twice.
law transfer.eintr_retries:
  {X.Xfer.moved(X.Xfer.run([X.IoGot{100}, X.IoErr{4}, X.IoGot{300}], 400)) == 400 : U32}

# Short calls resume at the next byte until all moved.
law transfer.short_resumes:
  {X.Xfer.run([X.IoGot{1}, X.IoGot{2}, X.IoGot{397}], 400) == X.XStop{400} : X.Next}

# A read that meets the end of the file stops there; its answer is not an
# error, and the rest of the request reads as zeros.
law transfer.read_eof:
  {X.Xfer.status(False{}, 400, X.Xfer.run([X.IoGot{150}, X.IoEof{}], 400)) == 0 : U32}

law transfer.read_eof_fills:
  {X.Xfer.zero_fill(False{}, 400, X.Xfer.run([X.IoGot{150}, X.IoEof{}], 400)) == 250 : U32}

# A write that stops short is an error.
law transfer.short_write_errs:
  {X.Xfer.status(True{}, 400, X.Xfer.run([X.IoGot{150}, X.IoErr{28}], 400)) == 4294967295 : U32}

# An error before any byte moved fails; after progress it stops with the
# progress (a read keeps what it read).
law transfer.err_first_fails:
  {X.Xfer.run([X.IoErr{5}], 400) == X.XFail{5} : X.Next}

law transfer.err_later_stops:
  {X.Xfer.run([X.IoGot{8}, X.IoErr{5}, X.IoGot{8}], 400) == X.XStop{8} : X.Next}

# A whole write is not an error.
law transfer.whole_write:
  {X.Xfer.status(True{}, 400, X.Xfer.run([X.IoGot{400}], 400)) == 0 : U32}

# Staged buffers, in a table of 4: a stage takes a free slot, round from
# the last one taken; a freed slot is taken again in its turn; a full table
# answers none; a slot is freed once whether sent or dropped, and freeing
# it again changes nothing.
def table(+st: X.Staged) -> X.Stages:
  match st:
    case X.Staged{s, t}:
      t

def slot(+st: X.Staged) -> U32:
  match st:
    case X.Staged{s, t}:
      s

def staged(n: Nat) -> X.Stages:
  match n:
    case 0n:
      X.Stages{4, 0, []}
    case 1n+k:
      table(X.Stage.take(staged(k), 4n))

law transfer.stage_round:
  {slot(X.Stage.take(staged(2n), 4n)) == 2 : U32}

law transfer.stage_full:
  {slot(X.Stage.take(staged(4n), 4n)) == 4294967295 : U32}

law transfer.stage_reuse:
  {slot(X.Stage.take(X.Stage.free(staged(4n), 1), 4n)) == 1 : U32}

law transfer.stage_skips_live:
  {slot(X.Stage.take(X.Stage.free(X.Stage.free(staged(3n), 0), 2), 4n)) == 3 : U32}

law transfer.free_once:
  {X.Stage.free(X.Stage.free(staged(3n), 1), 1) == X.Stage.free(staged(3n), 1) : X.Stages}

law transfer.free_counts:
  {X.Stage.count(X.Stage.free(staged(3n), 1)) == 2 : U32}
