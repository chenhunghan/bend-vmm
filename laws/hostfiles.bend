import Base
import ../src/vmm/hostfiles.bend as F

# Spec for src/vmm/hostfiles.bend: what the VMM makes on the host, and where.

# What the VMM creates is this user's alone.
law hostfiles.private:
  {F.Files.private() == 384 : U32}

law hostfiles.private_dir:
  {F.Files.private_dir() == 448 : U32}

# Listening: nothing there binds; a dead socket is replaced; a live one, or
# anything that is not a socket, is refused and left alone.
law hostfiles.listen_free:
  {F.Files.listen(0, False{}) == F.LBind{} : F.Listen}

law hostfiles.listen_stale:
  {F.Files.listen(1, False{}) == F.LReplace{} : F.Listen}

law hostfiles.listen_live:
  {F.Files.listen(1, True{}) == F.LInUse{} : F.Listen}

law hostfiles.listen_file:
  {F.Files.listen(2, False{}) == F.LNotSocket{} : F.Listen}

law hostfiles.only_stale_removed:
  {F.Files.listen.replace(F.Files.listen(2, True{})) == False{} : Bool}

# The LAN directory: this user's directory with no group or other bits.
law hostfiles.lan_ok:
  {F.Files.dir_trusted(1, True{}, 448) == True{} : Bool}

law hostfiles.lan_group:
  {F.Files.dir_trusted(1, True{}, 488) == False{} : Bool}

law hostfiles.lan_other:
  {F.Files.dir_trusted(1, True{}, 449) == False{} : Bool}

law hostfiles.lan_not_mine:
  {F.Files.dir_trusted(1, False{}, 448) == False{} : Bool}

law hostfiles.lan_symlink:
  {F.Files.dir_trusted(2, True{}, 448) == False{} : Bool}

# A VM's socket in the LAN directory is named by its MAC.
law hostfiles.lan_sock:
  {F.Files.lan_sock([2, 0, 0, 171, 205, 239]) == "02-00-00-ab-cd-ef.sock" : String}

# Proposed: the program a reset starts again: the system's name for this
# executable, else the first argument.
law hostfiles.exec_system:
  {F.Files.exec_path("/usr/local/bin/bend-vmm", "bend-vmm") == "/usr/local/bin/bend-vmm" : String}

law hostfiles.exec_argv0:
  {F.Files.exec_path("", "./out/bend-vmm") == "./out/bend-vmm" : String}

# Proposed: a socket path fits the address when its UTF-8 bytes are at most
# the field's room (a 2-byte character counts 2).
law hostfiles.sock_fits:
  {F.Files.sock_path_fits("/tmp/vm.sock", 103) == True{} : Bool}

law hostfiles.sock_too_long:
  {F.Files.sock_path_fits("/tmp/abcde", 9) == False{} : Bool}

law hostfiles.sock_utf8:
  {F.Files.utf8_len("é/x") == 4 : U32}
