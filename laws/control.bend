import Base
import ../src/vmm/control.bend as C

# Spec for src/vmm/control.bend: which command a control line is.

law control.pause:
  {C.Ctl.parse("pause") == C.CPause{} : C.Cmd}

law control.resume_trimmed:
  {C.Ctl.parse("  resume \n") == C.CResume{} : C.Cmd}

law control.status:
  {C.Ctl.parse("status") == C.CStatus{} : C.Cmd}

law control.quit:
  {C.Ctl.parse("quit") == C.CQuit{} : C.Cmd}

law control.net:
  {C.Ctl.parse("net") == C.CNet{} : C.Cmd}

law control.powerdown:
  {C.Ctl.parse("powerdown") == C.CPowerdown{} : C.Cmd}

law control.snapshot:
  {C.Ctl.parse("snapshot /tmp/vm.snap") == C.CSnapshot{"/tmp/vm.snap"} : C.Cmd}

law control.snapshot_spaces:
  {C.Ctl.parse("snapshot my vm.snap") == C.CSnapshot{"my vm.snap"} : C.Cmd}

law control.screendump:
  {C.Ctl.parse("screendump s.ppm") == C.CScreendump{"s.ppm"} : C.Cmd}

law control.type:
  {C.Ctl.parse("type ls -l\\n") == C.CType{"ls -l\\n"} : C.Cmd}

law control.pointer:
  {C.Ctl.parse("pointer 100 32767") == C.CPointer{100, 32767} : C.Cmd}

law control.pointer_off_scale:
  {C.Ctl.parse("pointer 100 32768") == C.CPointerUsage{} : C.Cmd}

law control.pointer_one:
  {C.Ctl.parse("pointer 100") == C.CPointerUsage{} : C.Cmd}

law control.pointer_word:
  {C.Ctl.parse("pointer x 1") == C.CPointerUsage{} : C.Cmd}

law control.unknown:
  {C.Ctl.parse("reboot") == C.CUnknown{} : C.Cmd}

law control.empty:
  {C.Ctl.parse("") == C.CUnknown{} : C.Cmd}

law control.verb_case:
  {C.Ctl.parse("PAUSE") == C.CUnknown{} : C.Cmd}
