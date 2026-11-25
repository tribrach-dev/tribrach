import Todo.Cards

/-- Usage:
- `lake exe cards` prints the rule cards.
- `lake exe cards --write RULES.md` writes them.
- `lake exe cards --check RULES.md` fails if the file is out of date.

Every mode fails if the model breaks a rule or a rule is vacuous. -/
def main (args : List String) : IO UInt32 := do
  let problems := Todo.Cards.problems
  if !problems.isEmpty then
    for p in problems do
      IO.eprintln s!"problem: {p}"
    return 1
  let text := Todo.Cards.render
  match args with
  | ["--write", path] =>
    IO.FS.writeFile path text
    IO.println s!"wrote {path}"
    return 0
  | ["--check", path] =>
    let current ← IO.FS.readFile path
    if current == text then
      IO.println s!"{path} is up to date"
      return 0
    else
      IO.println s!"{path} is out of date; run `lake exe cards --write {path}`. Expected:"
      IO.println "-----BEGIN RULES-----"
      IO.print text
      IO.println "-----END RULES-----"
      return 1
  | _ =>
    IO.print text
    return 0
