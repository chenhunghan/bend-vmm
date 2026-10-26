# bend-vmm

A virtual machine monitor for macOS on Apple Silicon, written in
[Bend](https://bend-lang.com). The VMM's logic is pure Bend, and laws state
its spec. Proofs check the laws. A simulator runs it on any OS, and a thin C
layer drives Hypervisor.framework.

- Design and verification plan: [docs/DESIGN.md](docs/DESIGN.md)
- Contributor and agent rules: [AGENTS.md](AGENTS.md)
- Gate: `scripts/check.sh` (Linux or macOS), `bend PROOF.bend`
