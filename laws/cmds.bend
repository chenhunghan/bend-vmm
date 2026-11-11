import Base
import ../src/vmm/cmds.bend as C

# Spec for src/vmm/cmds.bend: which command a command line is, and the
# options a VM folder's vm.conf makes.

law cmds.snapshot:
  {C.Sub.parse(["snapshot", "s1", "--note", "first", "--vm", "web"]) == C.SubSnap{"web", "s1", "first"} : C.Sub}

law cmds.snapshot_default:
  {C.Sub.parse(["snapshot"]) == C.SubSnap{".", "", ""} : C.Sub}

# Options first is no command: the VM's options, as before.
law cmds.options:
  {C.Sub.parse(["--kernel", "Image"]) == C.SubNone{} : C.Sub}

law cmds.restore_usage:
  {C.Sub.parse(["restore"]) == C.SubBad{"usage: bend-vmm restore NAME [--vm DIR]"} : C.Sub}

law cmds.stop:
  {C.Sub.parse(["stop", "--vm", "web"]) == C.SubCtl{"web", "quit"} : C.Sub}

law cmds.prune:
  {C.Sub.parse(["prune", "--keep", "3"]) == C.SubPrune{".", 3} : C.Sub}

law cmds.prune_usage:
  {C.Sub.parse(["prune"]) == C.SubBad{"usage: bend-vmm prune --keep N [--vm DIR]"} : C.Sub}

law cmds.ctl:
  {C.Sub.parse(["ctl", "s.sock", "status", "json"]) == C.SubRaw{"s.sock", "status json"} : C.Sub}

law cmds.unknown:
  {C.Sub.parse(["frob"]) == C.SubBad{"unknown command frob (bend-vmm --help)"} : C.Sub}

# vm.conf: one option per line; relative paths are the folder's; comments
# and empty lines skipped; quotes around a value dropped.
law cmds.conf:
  {C.Conf.flags("web", "--disk a.img,/abs/b.img:ro\n# a note\n\n--cmdline \"console=ttyAMA0 quiet\"\n--share data,quota=1M\n--mem 256\n") == ["--disk", "web/a.img,/abs/b.img:ro", "--cmdline", "console=ttyAMA0 quiet", "--share", "web/data,quota=1M", "--mem", "256"] : List<&2, String>}

law cmds.conf_roundtrip:
  {C.Conf.flags("/", C.Conf.text(["--mem", "256", "--cmdline", "a b"])) == ["--mem", "256", "--cmdline", "a b"] : List<&2, String>}

# A restore takes the host files and forwards from vm.conf; the rest is the
# snapshot's.
law cmds.for_restore:
  {C.Conf.for_restore(["--kernel", "k", "--disk", "d.img", "--mem", "1", "--forward", "8080:80"]) == ["--disk", "d.img", "--forward", "8080:80"] : List<&2, String>}
