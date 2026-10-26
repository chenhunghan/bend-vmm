// Hypervisor.framework exists only in native macOS builds (host/hvf.c).
// The JavaScript lane registers stubs that fail, so `bend host/*.bend` still
// checks and runs anywhere, and reports that it needs the native build.
function hvf_unavailable() {
  return 4294967295;
}

io_eff(CID(Hvf.init), () => 1);
io_eff(CID(Hvf.load), hvf_unavailable);
io_eff(CID(Hvf.write), hvf_unavailable);
io_eff(CID(Hvf.read), () => ({ $: CID(Nil) }));
io_eff(CID(Hvf.vcpu), () => ({ $: CID(Con), head: 4294967295, tail: { $: CID(Nil) } }));
io_eff(CID(Hvf.irq), hvf_unavailable);
io_eff(CID(Hvf.kick), hvf_unavailable);
