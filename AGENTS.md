When using Bend:
- run `bend guide` to learn it
- use `LAWS.bend` to keep important rules
- run `bend PROOF.bend` before committing
- parallelize the code whenever possible

# bend-vmm

A virtual machine monitor for macOS on Apple Silicon, written in Bend. It
boots arm64 guests (Linux) on Hypervisor.framework. Read docs/DESIGN.md
before your first change. `openvmm/` (when present, git-ignored) is a
reference only: we do not follow its design or API.

## Layout

- `src/` — the pure VMM: every device model, decoder, loader and the exit
  handler. No IO. Runs and proves on Linux and macOS.
- `host/` — the macOS layer: C effects over Hypervisor.framework and the
  `main` that drives vCPUs. Builds only on macOS (Apple Silicon).
- `laws/<module>.bend` — the spec of each module, as Bend laws.
- `proofs/<module>.bend` — the proof of each law, as a def of the same name.
- `LAWS.bend`, `PROOF.bend` — gather every laws/proofs file.
- `tests/<name>.bend` — executable tests; each prints PASS/FAIL lines.
- `laws/done/<module>` — marker: the module's laws are all proven (the ratchet).
- `scripts/check.sh` — the gate (typing, ratchet, tests). CI runs it.

## Rules

1. Laws are the spec and are owned by the architect. Never edit, weaken or
   delete an existing law in `laws/`. You may add new laws under a
   `# Proposed:` comment at the end of the file; say so in the PR.
2. Test files headed `FROZEN SPEC` are spec too: do not edit them.
3. A contract in `src/` (types, def names and signatures that a law or a
   frozen test uses) is fixed. Fill the `?TODO` bodies; add as many helper
   defs as you like; do not change an existing signature or type. If a
   contract is wrong, stop and say why in the PR instead of working around it.
4. Prove every law of your module in `proofs/<module>.bend`: `def L.<law>`
   for `law <law>` (see proofs/lib.bend). Concrete laws usually close with
   `{==}`; general ones need induction and rewrites (`bend guide`). If a
   general law resists a real attempt, leave it open (no def), do not add the
   done marker, and explain in the PR what blocks it. Concrete laws and
   frozen tests must always pass.
5. When `bend proofs/<module>.bend` prints ALL PROOFS CHECK, add the marker
   file `laws/done/<module>` (containing the module name) in the same PR.
6. `scripts/check.sh` must pass before you push. `bend PROOF.bend` may still
   report open TODOs of other modules, but no other error.
7. Never use `@unsafe` (or `?`-suffixed defs) in `src/`. Only `host/` may.
8. Parallelize where the work splits evenly: independent subtrees, halves of
   a list, independent devices. Use a parallel let (`a b = f(x) g(y)`) and
   keep both sides about the same size.

## Bend facts that bite (2.0.39)

- No hex literals: write decimal and put the hex in a comment.
- No U64 and no U8: use `U.U64` (src/lib/u64.bend) and byte lists
  `+List<U32>` (src/lib/bytes.bend).
- Variables are affine. Write `+x` (param, let, pattern or do-bind:
  `+bs : +List<U32> <- ...`) to use a Data value more than once.
- `match` takes only parameters or pattern-bound variables. To branch on a
  computed value, pass it to a helper def that matches on its parameter.
- A def must be declared above every def that calls it, and mutual recursion
  is refused. Recursion must shrink an argument (left to right) — loops over
  outside data take a `Nat` fuel argument first.
- Imported names keep their alias, constructors too: `U.U64{0, 1}`,
  `case V.VmRet{x}:`.
- Templates take `~` arguments: `List.show(~&2, ~U32, ~U32.show, xs)`,
  `List.foldl(~&2, ~U32, ~U32, ~U32.add, xs, 0)`. `bend base <Name>` prints
  any Base def with its signature.
- Operators need a type: `(a + b : U32)`, `(x .&. 255 : U32)`, `(x >> 8n : U32)`.
- A pair is `A & B`, built `(a, b)`; destructure it in a helper's `match`.
- Parallel lets run on real threads only in native builds, and Bend 2.0.39's
  native runtime can fail on some of them ("frontier drained without a
  result") while `bend file.bend` (the sequential JS lane) passes. Bind every
  argument of a parallel call to a variable first (`+st = status(s)`, then
  `a b = f(s, st) g(st)`), and run `scripts/check-native.sh` (macOS or Linux
  with clang) before pushing a parallel let.
- Code that touches guest memory is written in `V.Op<R, A>` (src/vmm/abi.bend)
  with `do V.Op<R, A>:` blocks; tests run it on the simulator (src/vmm/sim.bend).

## Verifying your work

```
bend proofs/<module>.bend      # your module's laws
bend tests/<module>.bend       # your module's tests
scripts/check.sh               # the whole gate (what CI runs)
scripts/check-native.sh        # every test compiled native, run on all threads
```

On macOS only, `scripts/check-mac.sh` builds `host/` and boots guests
(see docs/DESIGN.md, level 4).
