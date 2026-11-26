import Tribrach.Link

/-!
# Package descriptors and link ownership

Every package describes itself in `tribrach-package.toml`. A package that
owns links lists their ids under `owns-links`:

```toml
name = "acme-kotlin"
kind = "instrument"
owns-links = ["acme.kotlin"]
diagnostics = "ACK"
```

`resolve` finds the installed package that owns a link's id. It reports:

- `TR0101` no installed package owns the id,
- `TR0102` two packages register the same id,
- `TR0103` a descriptor is malformed or registers an invalid id.

Descriptors use a small subset of TOML: top-level `key = value` lines where
the value is a string, an array of strings, or an inline table (kept but not
read here), plus `#` comments. That keeps this reader small; anything else is
reported as malformed.
-/

namespace Tribrach

inductive PackageKind where
  | core
  | instrument
  | pack
  | adapter
  deriving DecidableEq, Repr

def PackageKind.parse? : String → Option PackageKind
  | "core" => some .core
  | "instrument" => some .instrument
  | "pack" => some .pack
  | "adapter" => some .adapter
  | _ => none

structure Descriptor where
  name : String
  kind : PackageKind
  ownsLinks : List InstrumentId
  deriving Repr

/-- A finding about packages or links, with a fix the user can act on. -/
structure Diagnostic where
  code : String
  message : String
  hint : String
  deriving Repr

def Diagnostic.render (d : Diagnostic) : String :=
  s!"{d.code} {d.message}. {d.hint}"

/-! ## Reading descriptors -/

inductive TomlValue where
  | str (s : String)
  | arr (xs : List String)
  | table (raw : String)
  deriving Repr

private def isSpace (c : Char) : Bool := c == ' ' || c == '\t' || c == '\r'

private def trimChars (l : List Char) : List Char :=
  ((l.dropWhile isSpace).reverse.dropWhile isSpace).reverse

private def trim (s : String) : String := String.ofList (trimChars s.toList)

/-- Drop a `#` comment that isn't inside a string. -/
private def stripComment (line : String) : String :=
  let rec go : List Char → Bool → List Char
    | [], _ => []
    | c :: cs, inStr =>
      if c == '"' then c :: go cs (!inStr)
      else if c == '#' && !inStr then []
      else c :: go cs inStr
  String.ofList (go line.toList false)

/-- `"text"` to `text`. -/
private def unquote? (s : String) : Option String :=
  match s.toList with
  | '"' :: rest =>
    match rest.reverse with
    | '"' :: inner => some (String.ofList inner.reverse)
    | _ => none
  | _ => none

private def parseValue? (raw : String) : Option TomlValue :=
  match raw.toList with
  | '[' :: rest =>
    match rest.reverse with
    | ']' :: inner =>
      let body := trim (String.ofList inner.reverse)
      if body.isEmpty then some (.arr [])
      else ((body.splitOn ",").mapM (fun part => unquote? (trim part))).map TomlValue.arr
    | _ => none
  | '{' :: _ => some (.table raw)
  | _ => (unquote? raw).map TomlValue.str

/-- Parse the descriptor subset into key/value pairs. -/
def parseToml (text : String) : Except String (List (String × TomlValue)) :=
  ((List.range (text.splitOn "\n").length).zip (text.splitOn "\n")).foldlM
    (fun acc p => do
      let line := trim (stripComment p.2)
      if line.isEmpty then return acc
      match line.splitOn "=" with
      | key :: rest@(_ :: _) =>
        let value := trim ("=".intercalate rest)
        match parseValue? value with
        | some v => return acc ++ [(trim key, v)]
        | none => throw s!"line {p.1 + 1}: can't read the value `{value}`"
      | _ => throw s!"line {p.1 + 1}: expected `key = value`")
    []

/-- Read a descriptor. `source` names the file in messages. -/
def Descriptor.parse (source : String) (text : String) : Except Diagnostic Descriptor :=
  let bad := fun (msg : String) =>
    ({ code := "TR0103", message := s!"{source} is malformed: {msg}",
       hint := "See the package descriptor section of docs/architecture.md" } : Diagnostic)
  match parseToml text with
  | .error e => .error (bad e)
  | .ok kvs =>
    let lookup : String → Option TomlValue := fun k => (kvs.find? (fun p => p.1 == k)).map (·.2)
    match lookup "name", lookup "kind" with
    | some (.str name), some (.str kindName) =>
      match PackageKind.parse? kindName with
      | none => .error (bad s!"unknown kind `{kindName}`")
      | some kind =>
        let owned : List String :=
          match lookup "owns-links" with
          | some (.arr xs) => xs
          | _ => []
        match owned.find? (fun s => !InstrumentId.valid s) with
        | some badId => .error (bad s!"`{badId}` is not a valid instrument id (use publisher.name, lowercase)")
        | none => .ok { name, kind, ownsLinks := owned.map (fun s => ⟨s⟩) }
    | _, _ => .error (bad "it needs `name` and `kind` strings")

/-! ## Registering and resolving -/

structure Registry where
  /-- Which package registered each id, first registration wins. -/
  owners : List (InstrumentId × String)
  diagnostics : List Diagnostic

def Registry.build (ds : List Descriptor) : Registry :=
  ds.foldl (fun reg d =>
    d.ownsLinks.foldl (fun reg2 id =>
      match reg2.owners.find? (fun p => p.1 == id) with
      | some (_, other) =>
        { reg2 with diagnostics := reg2.diagnostics ++ [{
            code := "TR0102",
            message := s!"instrument id {id} is registered by both {other} and {d.name}",
            hint := "Uninstall one of them, or give one a different id" }] }
      | none => { reg2 with owners := reg2.owners ++ [(id, d.name)] }) reg)
    { owners := [], diagnostics := [] }

/-- The package that owns a link. -/
def Registry.resolve (reg : Registry) (l : Link) : Except Diagnostic String :=
  match reg.owners.find? (fun p => p.1 == l.owner) with
  | some (_, pkg) => .ok pkg
  | none => .error {
      code := "TR0101",
      message := s!"no installed package owns {l.owner} links ({l.leanName} -> {l.symbol})",
      hint := s!"Install the package that registers {l.owner} in its tribrach-package.toml, or fix the owner in the link" }

end Tribrach
