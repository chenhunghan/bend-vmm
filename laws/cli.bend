import Base
import ../src/boot/dtb.bend as T
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
