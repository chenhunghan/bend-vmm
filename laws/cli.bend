import Base
import ../src/boot/dtb.bend as T
import ../src/lib/u64.bend as U
import ../src/vmm/cli.bend as C

# Spec for src/vmm/cli.bend: which command lines are valid, and --display.

law cli.ok:
  {C.Cli.check(["--kernel", "Image", "--mem", "1024", "--cpus", "4", "--disk", "a.img,b.img:ro", "--forward", "2222:22", "--forward", "8080:80"]) == "" : String}

law cli.empty:
  {C.Cli.check([]) == "" : String}

law cli.unknown:
  {C.Cli.check(["--kernel", "Image", "--mem=512", "x"]) == "unknown option --mem=512" : String}

law cli.no_value:
  {C.Cli.check(["--kernel", "Image", "--cpus"]) == "--cpus needs a value" : String}

law cli.stray_word:
  {C.Cli.check(["--kernel", "Image", "extra"]) == "unknown option extra" : String}

law cli.mem_word:
  {C.Cli.check(["--mem", "lots"]) == "--mem takes MiB, 1 to 1048576 (not lots)" : String}

law cli.mem_zero:
  {C.Cli.check(["--mem", "0"]) == "--mem takes MiB, 1 to 1048576 (not 0)" : String}

law cli.mem_most:
  {C.Cli.check(["--mem", "1048576"]) == "" : String}

law cli.mem_past:
  {C.Cli.check(["--mem", "1048577"]) == "--mem takes MiB, 1 to 1048576 (not 1048577)" : String}

law cli.cpus_most:
  {C.Cli.check(["--cpus", "64"]) == "" : String}

law cli.cpus_past:
  {C.Cli.check(["--cpus", "65"]) == "--cpus takes 1 to 64 (not 65)" : String}

law cli.cpus_zero:
  {C.Cli.check(["--cpus", "0"]) == "--cpus takes 1 to 64 (not 0)" : String}

law cli.display_bad:
  {C.Cli.check(["--display", "640"]) == "--display takes WxH or WxH,headless (not 640)" : String}

law cli.display_headless:
  {C.Cli.check(["--display", "640x480,headless"]) == "" : String}

law cli.display_size:
  {C.Cli.display("1024x768,headless") == Some{T.Display{1024, 768}} : Maybe<&2, T.Display>}

law cli.display_zero:
  {C.Cli.display("0x768") == None{} : Maybe<&2, T.Display>}

law cli.display_none:
  {C.Cli.display("") == None{} : Maybe<&2, T.Display>}

# Proposed: --lan DIR[,ip=A.B.C.D/N][,mac=xx:xx:xx:xx:xx:xx].

law cli.lan_ip:
  {C.Cli.lan("/tmp/k8s-lan,ip=10.0.3.11/24") == Some{C.LanSpec{"/tmp/k8s-lan", [82, 84, 1, 0, 3, 11], 167772939, 24}} : Maybe<&2, C.LanSpec>}

law cli.lan_mac:
  {C.Cli.lan("lan,mac=52:54:00:Ab:cd:0f,ip=10.0.3.12/16") == Some{C.LanSpec{"lan", [82, 84, 0, 171, 205, 15], 167772940, 16}} : Maybe<&2, C.LanSpec>}

law cli.lan_mac_only:
  {C.Cli.lan("lan,mac=02:00:00:00:00:01") == Some{C.LanSpec{"lan", [2, 0, 0, 0, 0, 1], 0, 0}} : Maybe<&2, C.LanSpec>}

law cli.lan_neither:
  {C.Cli.lan("lan") == None{} : Maybe<&2, C.LanSpec>}

law cli.lan_multicast_mac:
  {C.Cli.lan("lan,mac=01:00:5e:00:00:01") == None{} : Maybe<&2, C.LanSpec>}

law cli.lan_bad_prefix:
  {C.Cli.lan("lan,ip=10.0.3.11/31") == None{} : Maybe<&2, C.LanSpec>}

law cli.lan_no_prefix:
  {C.Cli.lan("lan,ip=10.0.3.11") == None{} : Maybe<&2, C.LanSpec>}

law cli.lan_unknown_option:
  {C.Cli.lan("lan,ip=10.0.3.11/24,mtu=9000") == None{} : Maybe<&2, C.LanSpec>}

law cli.lan_no_dir:
  {C.Cli.lan(",ip=10.0.3.11/24") == None{} : Maybe<&2, C.LanSpec>}

law cli.lan_checked:
  {C.Cli.check(["--lan", "lan"]) == "--lan takes DIR,ip=A.B.C.D/N and/or mac=xx:xx:xx:xx:xx:xx (not lan)" : String}

# Proposed: sizes, --share DIR[,quota=SIZE], --console-log PATH,max=SIZE[,keep=N],
# and finding a flag's value (bend-vk8s F6).

law cli.size_bytes:
  {C.Cli.size("4096") == Some{U.U64{0, 4096}} : Maybe<&2, U.U64>}

law cli.size_mib:
  {C.Cli.size("256M") == Some{U.U64{0, 268435456}} : Maybe<&2, U.U64>}

law cli.size_gib:
  {C.Cli.size("8G") == Some{U.U64{2, 0}} : Maybe<&2, U.U64>}

law cli.size_word:
  {C.Cli.size("lots") == None{} : Maybe<&2, U.U64>}

law cli.size_empty:
  {C.Cli.size("") == None{} : Maybe<&2, U.U64>}

law cli.share_plain:
  {C.Cli.share("/srv/share") == Some{C.ShareSpec{"/srv/share", U.U64{0, 0}}} : Maybe<&2, C.ShareSpec>}

law cli.share_quota:
  {C.Cli.share("/srv/share,quota=256M") == Some{C.ShareSpec{"/srv/share", U.U64{0, 268435456}}} : Maybe<&2, C.ShareSpec>}

law cli.share_bad:
  {C.Cli.check(["--share", "/srv/share,ro=x"]) == "--share takes DIR or DIR,quota=SIZE (bytes, or K, M, G) (not /srv/share,ro=x)" : String}

law cli.conlog:
  {C.Cli.conlog("console.log,max=64M,keep=2") == Some{C.ConLog{"console.log", U.U64{0, 67108864}, 2}} : Maybe<&2, C.ConLog>}

law cli.conlog_keep_default:
  {C.Cli.conlog("console.log,max=1048576") == Some{C.ConLog{"console.log", U.U64{0, 1048576}, 1}} : Maybe<&2, C.ConLog>}

law cli.conlog_no_max:
  {C.Cli.conlog("console.log,keep=2") == None{} : Maybe<&2, C.ConLog>}

law cli.conlog_zero_max:
  {C.Cli.conlog("console.log,max=0") == None{} : Maybe<&2, C.ConLog>}

law cli.find_last:
  {C.Cli.find(["--kernel", "a", "--console-log", "x,max=1M", "--console-log", "y,max=2M"], "--console-log") == "y,max=2M" : String}

law cli.find_none:
  {C.Cli.find(["--kernel", "a"], "--console-log") == "" : String}

# Proposed: --forward [ADDR:]HOSTPORT:GUESTPORT[,...].

law cli.fwd_default_addr:
  {C.Fwd.parse("2222:22") == Some{C.Fwd{"127.0.0.1", 2222, 22}} : Maybe<&2, C.Fwd>}

law cli.fwd_addr:
  {C.Fwd.parse("0.0.0.0:6443:6443") == Some{C.Fwd{"0.0.0.0", 6443, 6443}} : Maybe<&2, C.Fwd>}

law cli.fwd_port_zero:
  {C.Fwd.parse("0:22") == None{} : Maybe<&2, C.Fwd>}

law cli.fwd_port_past:
  {C.Fwd.parse("65536:22") == None{} : Maybe<&2, C.Fwd>}

law cli.fwd_specs:
  {C.Fwd.specs("2222:22,8080:80") == ["2222:22", "8080:80"] : List<&2, String>}

law cli.fwd_checked:
  {C.Cli.check(["--forward", "2222:22,80"]) == "--forward takes [ADDR:]HOSTPORT:GUESTPORT[,...] (ports 1 to 65535) (not 2222:22,80)" : String}

# Proposed: a display must fit the 16 MiB framebuffer (4 bytes a pixel):
# 2048x2048 does, 2048x2049 does not, and a size whose product overflows 32
# bits is refused rather than wrapped.
law cli.display_fits:
  {C.Cli.display("2048x2048") == Some{T.Display{2048, 2048}} : Maybe<&2, T.Display>}

law cli.display_too_big:
  {C.Cli.display("2048x2049") == None{} : Maybe<&2, T.Display>}

law cli.display_overflow:
  {C.Cli.display("65536x65537") == None{} : Maybe<&2, T.Display>}
