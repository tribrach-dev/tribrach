/-!
# Links

A `Link` ties a Lean definition to a symbol in host code. Instruments read
links from annotations in the host code (for example `//tribrach:link
Counter.counterStep`) and check them against the manifest exported from Lean.
The stamp is a hash of the Lean definition, so a change on either side shows up
as drift instead of passing silently.

Each link names its owner by an `InstrumentId`, an open, namespaced string
such as `tribrach.go` or `acme.kotlin`. Core never lists the owners: installed
packages register the ids they own in `tribrach-package.toml` (see
`Tribrach.Package`), so a third-party instrument needs no change to core.
-/

namespace Tribrach

/-- A stable identifier for whatever owns a link: dot-separated segments of
lowercase letters, digits and `-`, at least two of them, starting with the
publisher (`tribrach.go`, `acme.kotlin`). -/
structure InstrumentId where
  value : String
  deriving DecidableEq, Repr, Inhabited

def InstrumentId.validSegment (seg : String) : Bool :=
  !seg.isEmpty && seg.all (fun c => c.isLower || c.isDigit || c == '-')

def InstrumentId.valid (s : String) : Bool :=
  let segs := s.splitOn "."
  segs.length ≥ 2 && segs.all InstrumentId.validSegment

def InstrumentId.parse? (s : String) : Option InstrumentId :=
  if InstrumentId.valid s then some ⟨s⟩ else none

instance : ToString InstrumentId := ⟨InstrumentId.value⟩

namespace InstrumentId
/-- The Go instrument, `tribrach-go`. -/
def go : InstrumentId := ⟨"tribrach.go"⟩
/-- The Swift instrument, `tribrach-swift`. -/
def swift : InstrumentId := ⟨"tribrach.swift"⟩
/-- Links to migration files that aren't host-language code, owned by the
`tribrach-data` package. Migrations written in Swift or Go are host code and
belong to that language's instrument instead. -/
def dataMigration : InstrumentId := ⟨"tribrach.data.migration"⟩
end InstrumentId

/-- The names the first manifests used before owners were open. Kept only so
those manifests still read; new manifests write an `InstrumentId`. -/
inductive Host where
  | go
  | swift
  | migration
  deriving Repr, DecidableEq

def Host.toInstrument : Host → InstrumentId
  | .go => InstrumentId.go
  | .swift => InstrumentId.swift
  | .migration => InstrumentId.dataMigration

def Host.ofLegacyName? : String → Option Host
  | "go" => some .go
  | "swift" => some .swift
  | "migration" => some .migration
  | _ => none

/-- Read the owner field of a manifest entry: an `InstrumentId`, or one of
the legacy names `go`, `swift`, `migration`. The flag is true for a legacy
name, so the runner can suggest rewriting it. -/
def ownerOfManifest? (field : String) : Option (InstrumentId × Bool) :=
  match InstrumentId.parse? field with
  | some id => some (id, false)
  | none => (Host.ofLegacyName? field).map (fun h => (h.toInstrument, true))

/-- A link from a Lean definition to a symbol in host code. -/
structure Link where
  /-- Fully qualified Lean name, e.g. `Counter.counterStep`. -/
  leanName : String
  /-- The instrument that checks this link. -/
  owner : InstrumentId
  /-- Host symbol, e.g. a Go package path plus function, or a Swift type. -/
  symbol : String
  /-- Hash of the Lean definition at export time. -/
  stamp : String
  deriving Repr

end Tribrach
