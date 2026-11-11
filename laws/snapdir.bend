import Base
import ../src/vmm/snapdir.bend as S

# Spec for src/vmm/snapdir.bend: snapshots as users see them.

# Names: one safe path component; never hidden, never "." or "..".
law snapdir.name_ok:
  {S.Sname.valid("before-upgrade_2.v1") == True{} : Bool}

law snapdir.name_slash:
  {S.Sname.valid("a/b") == False{} : Bool}

law snapdir.name_dot:
  {S.Sname.valid(".hidden") || S.Sname.valid("..") || S.Sname.valid("") == False{} : Bool}

# Default names are the UTC time, so they sort as times do (the epoch, a
# leap day, today, the end of the century).
law snapdir.time_epoch:
  {S.Sname.of_time(0) == "1970-01-01-000000" : String}

law snapdir.time_leap:
  {S.Sname.of_time(951782400) == "2000-02-29-000000" : String}

law snapdir.time_now:
  {S.Sname.of_time(1794384652) == "2026-11-11-081052" : String}

law snapdir.time_2099:
  {S.Sname.of_time(4102444799) == "2099-12-31-235959" : String}

law snapdir.undo:
  {S.Sname.undo(0) == "before-restore-1970-01-01-000000" : String}

# Layout: a snapshot is a folder of its VM; it is written beside it, hidden.
law snapdir.layout:
  {S.Sdir.memory(S.Sdir.dir("web", "s1")) == "web/snapshots/s1/memory" : String}

law snapdir.layout_tmp:
  {S.Sdir.tmp("web", "s1") == "web/snapshots/.s1.tmp" : String}

law snapdir.layout_disk:
  {S.Sdir.disk(S.Sdir.dir("web", "s1"), 1) == "web/snapshots/s1/disk1" : String}

# Metadata survives its text, and a note stays on one line.
law snapdir.info_roundtrip:
  {S.Sdir.info.parse(S.Sdir.info.text(S.Info{"s1", 1794384652, "s0", 1048576, 2048, "before the upgrade"})) == S.Info{"s1", 1794384652, "s0", 1048576, 2048, "before the upgrade"} : S.Info}

law snapdir.info_one_line:
  {S.Sdir.info.parse(S.Sdir.info.text(S.Info{"s1", 5, "", 1, 2, "a\nb"})) == S.Info{"s1", 5, "", 1, 2, "a b"} : S.Info}

# A listing is oldest first (then by name); prune --keep N removes the
# oldest past the newest N, and nothing when there are N or fewer.
law snapdir.sorted:
  {S.Sdir.names(S.Sdir.sorted([S.Info{"c", 30, "", 0, 0, ""}, S.Info{"a", 10, "", 0, 0, ""}, S.Info{"b", 10, "", 0, 0, ""}], [])) == ["a", "b", "c"] : List<&2, String>}

law snapdir.prune:
  {S.Sdir.prune([S.Info{"c", 30, "", 0, 0, ""}, S.Info{"a", 10, "", 0, 0, ""}, S.Info{"b", 20, "", 0, 0, ""}], 1) == ["a", "b"] : List<&2, String>}

law snapdir.prune_none:
  {S.Sdir.prune([S.Info{"a", 10, "", 0, 0, ""}], 3) == [] : List<&2, String>}

# Which VM: the one named, else the only one running, else say why not.
law snapdir.pick_named:
  {S.Vmsel.pick("web", ["db", "web"]) == S.PVm{"web"} : S.Pick}

law snapdir.pick_only:
  {S.Vmsel.pick("", ["web"]) == S.PVm{"web"} : S.Pick}

law snapdir.pick_many:
  {S.Vmsel.why(S.Vmsel.pick("", ["db", "web"])) == "2 VMs are running: name one" : String}

law snapdir.pick_none:
  {S.Vmsel.why(S.Vmsel.pick("", [])) == "no VM is running here" : String}
