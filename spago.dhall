{ name = "purescript-veither"
, dependencies =
  [ "arrays"
  , "control"
  , "either"
  , "enums"
  , "foldable-traversable"
  , "invariant"
  , "lists"
  , "maybe"
  , "newtype"
  , "partial"
  , "prelude"
  , "quickcheck"
  , "record"
  , "tuples"
  , "unsafe-coerce"
  , "variant"
  ]
, packages = ./packages.dhall
, sources = [ "src/**/*.purs" ]
}