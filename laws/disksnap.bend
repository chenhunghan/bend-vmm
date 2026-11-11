import Base
import ../src/vmm/disksnap.bend as D

# Spec for src/vmm/disksnap.bend: a snapshot keeps each writable disk, and
# restoring it puts them back without touching the copies.

# Only writable disks are kept, by their place in --disk.
law disksnap.writable:
  {D.Dsnap.writable("a.img,b.img:ro,c.qcow2") == [D.DiskAt{0, "a.img"}, D.DiskAt{2, "c.qcow2"}] : List<D.DiskAt>}

law disksnap.none:
  {D.Dsnap.writable("") == [] : List<D.DiskAt>}

# Taking: each disk cloned to its copy's temporary name, then the copies
# renamed into place.
law disksnap.save:
  {D.Dsnap.save("vm.snap", "7", [D.DiskAt{0, "a.img"}]) == [D.DClone{"a.img", "vm.snap.7.disk0.bend-vmm-tmp"}] : List<D.Step>}

law disksnap.place:
  {D.Dsnap.place("vm.snap", "7", [D.DiskAt{0, "a.img"}]) == [D.DRename{"vm.snap.7.disk0.bend-vmm-tmp", "vm.snap.7.disk0"}] : List<D.Step>}

# The copies of the snapshot replaced go; this one's never.
law disksnap.drop_old:
  {D.Dsnap.drop("vm.snap", "5", "7", [D.DiskAt{0, "a.img"}]) == [D.DRemove{"vm.snap.5.disk0"}] : List<D.Step>}

law disksnap.drop_same:
  {D.Dsnap.drop("vm.snap", "7", "7", [D.DiskAt{0, "a.img"}]) == [] : List<D.Step>}

law disksnap.drop_untagged:
  {D.Dsnap.drop("vm.snap", "", "7", [D.DiskAt{0, "a.img"}]) == [] : List<D.Step>}

# Restoring: each disk cloned back from its copy through a temporary name
# (the copy is only read); an untagged snapshot leaves the disks alone.
law disksnap.restore:
  {D.Dsnap.restore("vm.snap", "7", [D.DiskAt{0, "a.img"}]) == [D.DClone{"vm.snap.7.disk0", "a.img.bend-vmm-tmp"}, D.DRename{"a.img.bend-vmm-tmp", "a.img"}] : List<D.Step>}

law disksnap.restore_untagged:
  {D.Dsnap.restore("vm.snap", "", [D.DiskAt{0, "a.img"}]) == [] : List<D.Step>}

# The tag: added to the saved command line, found again (the last wins).
law disksnap.tag_roundtrip:
  {D.Dsnap.gen_of(D.Dsnap.tagged(["bend-vmm", "--disk", "a.img"], "42")) == "42" : String}

law disksnap.tag_none:
  {D.Dsnap.gen_of(["bend-vmm", "--disk", "a.img"]) == "" : String}

# A saved command line read back from its NUL-separated bytes.
law disksnap.args:
  {D.Dsnap.args([97, 0, 98, 99, 0]) == ["a", "bc"] : List<String>}

# A failed snapshot leaves no temporary copy behind.
law disksnap.unsave:
  {D.Dsnap.unsave("vm.snap", "7", [D.DiskAt{1, "b.img"}]) == [D.DRemove{"vm.snap.7.disk1.bend-vmm-tmp"}] : List<D.Step>}

# A snapshot folder: its copies are DIR/disk<i> beside DIR/memory.
law disksnap.folder:
  {D.Dsnap.restore("web/snapshots/s1/memory", "dir", [D.DiskAt{0, "disk.img"}]) == [D.DClone{"web/snapshots/s1/disk0", "disk.img.bend-vmm-tmp"}, D.DRename{"disk.img.bend-vmm-tmp", "disk.img"}] : List<D.Step>}

law disksnap.folder_save:
  {D.Dsnap.place("t/memory", "dir", [D.DiskAt{2, "c.img"}]) == [D.DRename{"t/disk2.bend-vmm-tmp", "t/disk2"}] : List<D.Step>}
