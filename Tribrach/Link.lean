/-!
# Links

A `Link` ties a Lean definition to a symbol in host code. Instruments read
links from annotations in the host code (for example `//tribrach:link
Counter.counterStep`) and check them against the manifest exported from Lean.
The stamp is a hash of the Lean definition, so a change on either side shows up
as drift instead of passing silently.
-/

namespace Tribrach

/-- Which instrument owns a link. -/
inductive Host where
  | go
  | swift
  | migration
  deriving Repr, DecidableEq

/-- A link from a Lean definition to a symbol in host code. -/
structure Link where
  /-- Fully qualified Lean name, e.g. `Counter.counterStep`. -/
  leanName : String
  /-- The instrument that checks this link. -/
  host : Host
  /-- Host symbol, e.g. a Go package path plus function, or a Swift type. -/
  symbol : String
  /-- Hash of the Lean definition at export time. -/
  stamp : String
  deriving Repr

end Tribrach
