let upstream =
      https://github.com/purescript/package-sets/releases/download/psc-0.15.2-20220531/packages.dhall
        sha256:278d3608439187e51136251ebf12fabda62d41ceb4bec9769312a08b56f853e3

in upstream
    //  { heterogenous =
          { dependencies =
            [ "prelude", "record", "tuples", "functors", "variant", "either" ]
          , repo = "https://github.com/natefaubion/purescript-heterogeneous.git"
          , version = "v0.5.0"
          }
        }
