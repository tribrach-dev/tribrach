import Todo.Triage

/-- `lake exe triage [--json] reports.json`, with the to-do model. -/
def main (args : List String) : IO UInt32 :=
  Tribrach.Triage.main Todo.subject args
