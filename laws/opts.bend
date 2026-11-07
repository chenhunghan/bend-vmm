import Base
import ../src/vmm/opts.bend as O

# Spec for src/vmm/opts.bend: the options a command line makes, and the
# restore policy.

def base() -> O.Opts:
  O.Opts.default()

law opts.default:
  {base() == O.Opts{"", "", "", "console=ttyAMA0 earlycon=pl011,0x9000000", 512, 1, "", "", "", "", "", "", "", "", "", ""} : O.Opts}

law opts.parse:
  {O.Opts.parse(["--kernel", "Image", "--mem", "1024", "--cpus", "4", "--disk", "a.img", "--lan", "/tmp/l,ip=10.0.3.11/24"], base())
    == O.Opts{"Image", "", "", "console=ttyAMA0 earlycon=pl011,0x9000000", 1024, 4, "a.img", "", "", "", "", "", "", "", "", "/tmp/l,ip=10.0.3.11/24"} : O.Opts}

# --forward may be given more than once: the lists join
law opts.forwards_join:
  {O.Opts.forward(O.Opts.parse(["--forward", "2222:22", "--forward", "8080:80"], base())) == "2222:22,8080:80" : String}

law opts.later_wins:
  {O.Opts.kernel(O.Opts.parse(["--kernel", "a", "--kernel", "b"], base())) == "b" : String}

# a restore takes the snapshot's options, this run's --control and --forward
law opts.restore_keeps_own:
  {O.Restore.opts(["bend-vmm", "--kernel", "Image", "--mem", "256", "--control", "old.sock", "--forward", "1:2"], O.Opts.parse(["--restore", "s.snap", "--control", "new.sock", "--forward", "3:4"], base()))
    == O.Opts{"Image", "", "", "console=ttyAMA0 earlycon=pl011,0x9000000", 256, 1, "", "", "", "new.sock", "", "", "", "", "3:4", ""} : O.Opts}

law opts.restore_same:
  {O.Restore.differs(O.Opts.parse(["--disk", "a.img", "--lan", "l,ip=10.0.3.11/24"], base()), O.Opts.parse(["--disk", "a.img", "--lan", "l,ip=10.0.3.11/24"], base())) == "" : String}

law opts.restore_other_disk:
  {O.Restore.differs(O.Opts.parse(["--disk", "a.img"], base()), O.Opts.parse(["--disk", "b.img"], base()))
    == "the snapshot was taken with --disk a.img; pass the same --disk to restore it" : String}

law opts.restore_new_share:
  {O.Restore.differs(base(), O.Opts.parse(["--share", "/tmp"], base()))
    == "the snapshot was taken without --share; restore it without --share" : String}

law opts.restore_lan:
  {O.Restore.differs(O.Opts.parse(["--lan", "l,ip=10.0.3.11/24"], base()), base())
    == "the snapshot was taken with --lan l,ip=10.0.3.11/24; pass the same --lan to restore it" : String}

law opts.with_size:
  {O.Opts.with_size(base(), 256, 2) == O.Opts{"", "", "", "console=ttyAMA0 earlycon=pl011,0x9000000", 256, 2, "", "", "", "", "", "", "", "", "", ""} : O.Opts}
