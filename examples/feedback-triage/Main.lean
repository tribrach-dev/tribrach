import Todo.Triage

/-- Usage: `lake exe triage reports.json`. Prints one line per report and
exits non-zero if any report's expected triage doesn't match. -/
def main (args : List String) : IO UInt32 :=
  Tribrach.Triage.runFile Todo.subject (args.headD "reports.json")
