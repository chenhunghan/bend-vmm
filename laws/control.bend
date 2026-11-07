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

# Proposed: framing of what the host reads (review of a6fba53): an empty
# line or a bare connect gets an answer and the service goes on; a line cut
# short and a command missing its argument get their usage.

law control.frame_line:
  {C.Ctl.frame([0, 112, 97, 117, 115, 101]) == Some{C.CPause{}} : Maybe<&2, C.Cmd>}

law control.frame_empty:
  {C.Ctl.frame([0]) == Some{C.CUnknown{}} : Maybe<&2, C.Cmd>}

law control.frame_too_long:
  {C.Ctl.frame([1, 112]) == Some{C.CBad{"line too long (at most 1024 bytes)"}} : Maybe<&2, C.Cmd>}

law control.frame_no_socket:
  {C.Ctl.frame([2]) == None{} : Maybe<&2, C.Cmd>}

law control.frame_nothing:
  {C.Ctl.frame([]) == None{} : Maybe<&2, C.Cmd>}

law control.snapshot_no_path:
  {C.Ctl.parse("snapshot") == C.CBad{"usage: snapshot PATH"} : C.Cmd}

law control.screendump_no_path:
  {C.Ctl.parse("screendump  ") == C.CBad{"usage: screendump PATH"} : C.Cmd}

law control.type_nothing:
  {C.Ctl.parse("type") == C.CBad{"usage: type TEXT"} : C.Cmd}

# Proposed: status json, for programs (bend-vk8s).

law control.status_json:
  {C.Ctl.parse("status json") == C.CStatusJson{} : C.Cmd}

law control.status_json_running:
  {C.Ctl.status_json(False{}) == "{\"state\":\"running\"}" : String}

law control.status_json_paused:
  {C.Ctl.status_json(True{}) == "{\"state\":\"paused\"}" : String}
