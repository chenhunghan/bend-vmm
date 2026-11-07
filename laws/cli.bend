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
