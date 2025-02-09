module Data.Veither where

import Prelude

import Control.Alt (class Alt)
import Control.Extend (class Extend)
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NEA
import Data.Either (Either, either)
import Data.Enum (class BoundedEnum, class Enum)
import Data.Foldable (class Foldable)
import Data.Functor.Invariant (class Invariant, imapF)
import Data.FunctorWithIndex (class FunctorWithIndex)
import Data.List as L
import Data.Maybe (Maybe(..), fromJust, maybe, maybe')
import Data.Newtype (class Newtype)
import Data.Symbol (class IsSymbol, reflectSymbol)
import Data.Traversable (class Traversable)
import Data.Tuple (Tuple)
import Data.Variant (class VariantMatchCases, Variant, case_, inj, on)
import Data.Variant.Internal (VariantRep(..), impossible, unsafeGet, unsafeHas)
import Partial.Unsafe (unsafePartial)
import Prim.Row as Row
import Prim.RowList as RL
import Record (get)
import Test.QuickCheck (class Arbitrary, class Coarbitrary, arbitrary, coarbitrary)
import Test.QuickCheck.Gen (Gen, frequency, oneOf)
import Type.Proxy (Proxy(..))
import Unsafe.Coerce (unsafeCoerce)

newtype Veither ∷ Row Type → Type → Type
-- | `Veither` is the same as `Either` except that the `l` type can be zero to many different types.
-- | `Veither` has all the instances that `Either` has, except for `Eq1` and `Ord1`, which simply
-- | haven't been implemented yet. If you would use a function from `Data.Either` (e.g. hush) and
-- | you want to use the equivalent for `Veither`, add a `v` in front of it (e.g. `vhush`).
-- |
-- | Conceptually, `Veither` has the following definition:
-- |
-- | ```
-- | data Veither l1 l2 ... ln a
-- |   = Right a
-- |   | L1 l1
-- |   | L2 l2
-- |   | ...
-- |   | LN ln
-- | ```
-- |
-- | `Veither` is monadic via the `a` type parameter. For example, the `Int` type below
-- | represents the 'happy path' and any other errors will short-circuit the computation:
-- |
-- | ```
-- | foo :: Variant (e1 :: Error1, e2 :: Error2) Int
-- | foo = do
-- |   i1 <- returnIntOrFailWithError1
-- |   i2 <- returnIntOrFailWithError2
-- |   pure $ i1 + i2
-- | ```
-- |
-- | Creating a value of `Veither` can be done in one of two ways, depending on whether
-- | you want the resulting `Veither` to function like `Either`'s `Right` constructor or like
-- | `Either`'s `Left` constructor:
-- |  - `Either`'s `Right` constructor: use `pure`. For example, `pure 4 :: forall errorRows. Veither errorRows Int`
-- |  - `Either`'s `Left` constructor: use `Data.Variant.inj`. For example, `Veither (inj (Proxy :: Proxy "foo") String)) :: forall a. Veither (foo :: String) a`
-- |
-- | One can also change an `Either a b` into a `Veither (x :: a) b` using `vfromEither`.
-- |
-- | To consume a `Veither` value, use `veither`, `vfromRight`, `vfromLeft`, `vnote`, or `vhush`. For example,
-- | one might do the following using `veither`:
-- |
-- | ```
-- | import Type.Proxy (Proxy(..))
-- | import Data.Variant (case_, on, inj)
-- |
-- | -- Given a variant value...
-- | val :: Veither (a :: Int, b :: String, c :: Boolean) Number
-- | val = pure 5
-- |
-- | -- you consume it using the following pattern. You'll need to handle every possible error type
-- | consume :: Veither (a :: Int, b :: String, c :: Boolean) Number -> String
-- | consume v = veither handleError handleSuccess v
-- |   where
-- |   handleError :: Variant (a :: Int, b :: String, c :: Boolean)
-- |   handleError =
-- |     case_
-- |       # on (Proxy :: Proxy "a") show
-- |       # on (Proxy :: Proxy "b") show
-- |       # on (Proxy :: Proxy "c") show
-- |
-- |   handleSuccess :: Number -> String
-- |   handleSuccess = show
-- | ```
-- |
-- | Below are functions that exist in `Veither` but do not exist in `Either`:
-- | - `vsafe` (inspired by `purescript-checked-exceptions`'s `safe` function)
-- | - `vhandle`
-- | - `vhandleErrors` (inspired by `purescript-checked-exceptions`'s `handleErrors` function)
-- | - `vfromEither`
-- | - `genVeitherUniform` - same as `genEither` but with uniform probability
-- | - `genVeitherFrequency` - same as `genEither` but with user-specified probability
-- |
newtype Veither errorRows a = Veither (Variant ("_" ∷ a | errorRows))

-- | Proxy type for `Veither`'s happy path (e.g. `Either`'s `Right` constructor).
-- |
-- | Note: the label `"_"` intentionally doesn't match the name of this value (i.e. '_veither').
_veither ∷ Proxy "_"
_veither = Proxy

derive instance newtypeVeither ∷ Newtype (Veither errorRows a) _

instance foldableVeither :: Foldable (Veither errorRows) where
  foldr f z v = veither (const z) (\a -> f a z) v
  foldl f z v = veither (const z) (\a -> f z a) v
  foldMap f v = veither (const mempty) f v

instance traversableVeither :: Traversable (Veither errorRows) where
  traverse :: forall a b m. Applicative m => (a -> m b) -> Veither errorRows a -> m (Veither errorRows b)
  traverse f v = veither (const (pure (coerceR v))) (\a -> pure <$> f a) v
    where
      coerceR ∷ forall a b. Veither errorRows a → Veither errorRows b
      coerceR = unsafeCoerce

  sequence :: forall a m. Applicative m => Veither errorRows (m a) -> m (Veither errorRows a)
  sequence v = veither (const (pure (coerceR v))) (\a -> pure <$> a) v
    where
      coerceR ∷ forall a b. Veither errorRows a → Veither errorRows b
      coerceR = unsafeCoerce

instance invariantVeither :: Invariant (Veither errorRows) where
  imap = imapF

instance functorVeither ∷ Functor (Veither errorRows) where
  map ∷ forall a b. (a → b) → Veither errorRows a → Veither errorRows b
  map f (Veither v) = case coerceV v of
      VariantRep v' | v'.type == "_" →
        Veither (inj _veither (f v'.value))
      _ → Veither (coerceR v)
    where
    coerceV ∷ forall a. Variant ("_" ∷ a | errorRows) → VariantRep a
    coerceV = unsafeCoerce

    coerceR ∷ forall a b. Variant ("_" ∷ a | errorRows) → Variant ("_" ∷ b | errorRows)
    coerceR = unsafeCoerce

instance functorWithIndexVeither ∷ FunctorWithIndex Unit (Veither errorRows) where
  mapWithIndex f = map $ f unit

instance applyVeither ∷ Apply (Veither errorRows) where
  apply ∷ forall a b. Veither errorRows (a → b) → Veither errorRows a → Veither errorRows b
  apply (Veither f) va = case coerceVF f of
      VariantRep f'
        | f'.type == "_" → f'.value <$> va
      _ → Veither (coerceR f)
    where
    coerceVF ∷ forall a b. Variant ("_" ∷ (a → b) | errorRows) → VariantRep (a → b)
    coerceVF = unsafeCoerce

    coerceR ∷ forall a b. Variant ("_" ∷ a | errorRows) → Variant ("_" ∷ b | errorRows)
    coerceR = unsafeCoerce

instance applicativeVeither ∷ Applicative (Veither errorRows) where
  pure ∷ forall a. a → Veither errorRows a
  pure arg = Veither (inj _veither arg)

instance bindVeither ∷ Bind (Veither errorRows) where
  bind ∷ forall a b. Veither errorRows a → (a → Veither errorRows b) → Veither errorRows b
  bind (Veither a) f = case coerceV a of
    VariantRep a'
      | a'.type == "_" → f a'.value
    _ → Veither $ coerceR a
    where
    coerceV ∷ forall a. Variant ("_" ∷ a | errorRows) → VariantRep a
    coerceV = unsafeCoerce

    coerceR ∷ forall a b. Variant ("_" ∷ a | errorRows) → Variant ("_" ∷ b | errorRows)
    coerceR = unsafeCoerce

instance monadVeither ∷ Monad (Veither errorRows)

instance altVeither :: Alt (Veither errorRows) where
  alt left@(Veither l) right@(Veither r) = case coerceV l, coerceV r of
    VariantRep l', VariantRep r'
      | l'.type /= "_", r'.type == "_" -> right
    _, _ -> left
    where
      coerceV ∷ forall a. Variant ("_" ∷ a | errorRows) → VariantRep a
      coerceV = unsafeCoerce

instance extendVeither :: Extend (Veither errorRows) where
  extend :: forall b a. (Veither errorRows a -> b) -> Veither errorRows a -> Veither errorRows b
  extend f v = map (\_ -> (f v)) v

derive newtype instance showVeither :: Show (Variant ("_" :: a | errorRows)) => Show (Veither errorRows a)

derive newtype instance eqVeither :: Eq (Variant ("_" :: a | errorRows)) => Eq (Veither errorRows a)

-- derive newtype instance eq1Either :: Eq a => Eq1 (Veither errorRows)

derive newtype instance ordVeither :: Ord (Variant ("_" :: a | errorRows)) => Ord (Veither errorRows a)

-- derive newtype instance ord1Either :: Ord a => Ord1 (Veither errorRows a)

derive newtype instance boundedVeither :: Bounded (Variant ("_" :: a | errorRows)) => Bounded (Veither errorRows a)

derive newtype instance enumVeither :: Enum (Variant ("_" :: a | errorRows)) => Enum (Veither errorRows a)

derive newtype instance boundedEnumVeither :: BoundedEnum (Variant ("_" :: a | errorRows)) => BoundedEnum (Veither errorRows a)

instance semigroupVeither :: (Semigroup b) => Semigroup (Veither errorRows b) where
  append x y = append <$> x <*> y

-- | Convert a `Veither` into a value by defining how to handle each possible value.
-- | Below is an example of the typical usage.
-- |
-- | ```
-- | consume :: Veither (a :: Int, b :: String, c :: Boolean) Number -> String
-- | consume v = veither handleError handleSuccess v
-- |   where
-- |   handleError :: Variant (a :: Int, b :: String, c :: Boolean)
-- |   handleError =
-- |     case_
-- |       # on (Proxy :: Proxy "a") show
-- |       # on (Proxy :: Proxy "b") show
-- |       # on (Proxy :: Proxy "c") show
-- |
-- |   handleSuccess :: Number -> String
-- |   handleSuccess = show
-- | ```
veither ∷ forall errorRows a b. (Variant errorRows → b) → (a → b) → Veither errorRows a → b
veither handleError handleSuccess (Veither v) = case coerceV v of
  VariantRep a | a.type == "_" → handleSuccess a.value
  _ → handleError (coerceR v)
  where
  coerceV ∷ Variant ("_" ∷ a | errorRows) → VariantRep a
  coerceV = unsafeCoerce

  coerceR ∷ Variant ("_" ∷ a | errorRows) → Variant errorRows
  coerceR = unsafeCoerce

-- | Extract the value out of the `Veither` when there are no other possible values
-- |
-- | ```
-- | vsafe (pure x) == x
-- | ```
vsafe ∷ forall a. Veither () a → a
vsafe (Veither v) = on _veither identity case_ v

-- | Removes one of the possible error types in the `Veither` by converting its value
-- | to a value of type `a`, the 'happy path' type. This can be useful for gradually
-- | picking off some of the errors the `Veither` value could have by handling only
-- | some of them at a given point in your code.
-- |
-- | If the number of errors in your `Veither` are small and can all be handled via `vhandle`,
-- | one can use `vsafe` to extract the value of the 'happy path' `a` type.
-- |
-- | ```
-- | foo :: Veither (b :: Int) String
-- | foo = pure "2"
-- |
-- | _b :: Proxy "b"
-- | _b = Proxy
-- |
-- | bar :: Veither (b :: Int) String
-- | bar = Veither (inj_ _b 3)
-- |
-- | vhandle _b show bar == ((pure "3") :: Veither () String)
-- | vhandle _b show foo == ((pure "2") :: Veither () String)
-- |
-- | vsafe (vhandle _b show bar) == "3"
-- | vsafe (vhandle _b show foo) == "2"
-- | ````
vhandle ∷ forall sym b otherErrorRows errorRows a
  .  IsSymbol sym
  => Row.Cons sym b otherErrorRows errorRows
  => Proxy sym -> (b -> a) -> Veither errorRows a → Veither otherErrorRows a
vhandle proxy f variant@(Veither v) = case coerceV v of
  VariantRep b | b.type == reflectSymbol proxy → pure $ f b.value
  _ → coerceVeither variant
  where
  coerceV ∷ Variant ("_" ∷ a | errorRows) → VariantRep b
  coerceV = unsafeCoerce

  coerceVeither ∷ Veither errorRows a → Veither otherErrorRows a
  coerceVeither = unsafeCoerce

-- | Removes one, some, or all of the possible error types in the `Veither`
-- | by converting its value to a value of type `a`, the 'happy path' type.
-- |
-- | Note: you will get a compiler error unless you add annotations
-- | to the record argument. You can do this by defining defining the record
-- | using a `let` statement or by annotating it inline
-- | (e.g. { a: identity} :: { a :: Int -> Int }`).
-- |
-- | If all errors are handled via `vhandleErrors`,
-- | one can use `vsafe` to extract the value of the 'happy path' `a` type.
-- |
-- | Doing something like `vhandleErrors {"_": \(i :: Int) -> i} v` will
-- | fail to compile. If you want to handle all possible values in the
-- |`Veither`, use `veither` or `Data.Variant.onMatch` directly
-- | (e.g. `onMatch record <<< un Veither`) instead of this function.
-- |
-- | Example usage:
-- | ```
-- | _a :: Proxy "a"
-- | _a = Proxy
-- |
-- | _b :: Proxy "b"
-- | _b = Proxy
-- |
-- | va :: Veither (a :: Int, b :: Boolean, c :: List String) String
-- | va = Veither $ inj _a 4
-- |
-- | vb :: Veither (a :: Int, b :: Boolean, c :: List String) String
-- | vb = Veither $ inj _b false
-- |
-- | handlers :: Record (a :: Int -> String, b :: Boolean -> String)
-- | handlers = { a: show, b: show }
-- |
-- | vhandleErrors handlers va == ((pure "4") :: Veither (c :: List String) String)
-- | vhandleErrors handlers vb == ((pure "false") :: Veither (c :: List String) String)
-- | ````
vhandleErrors ∷ forall handlers rlHandlers handledRows remainingErrorRows allErrorRows a
  .  RL.RowToList handlers rlHandlers
  => VariantMatchCases rlHandlers handledRows a
  => Row.Union handledRows ("_" :: a | remainingErrorRows) ("_" :: a | allErrorRows)
  => { | handlers } -> Veither allErrorRows a → Veither remainingErrorRows a
vhandleErrors rec (Veither v) = case coerceV v of
  VariantRep a | a.type /= "_", unsafeHas a.type rec →
    Veither (inj _veither ((unsafeGet a.type rec) a.value))
  _ → Veither (coerceR v)
  where
    coerceV ∷ ∀ b. Variant ("_" :: a | allErrorRows) → VariantRep b
    coerceV = unsafeCoerce

    coerceR ∷ Variant ("_" :: a | allErrorRows) → Variant ("_" :: a | remainingErrorRows)
    coerceR = unsafeCoerce

-- | Convert an `Either` into a `Veither`.
-- |
-- | ```
-- | p :: Proxy "foo"
-- | p = Proxy
-- |
-- | vfromEither p (Left Int)  :: forall a. Variant (foo :: Int) a
-- | vfromEither p (Right Int) :: forall a. Variant (foo :: a  ) Int
-- | ```
vfromEither ∷ forall sym otherRows errorRows a b
  .  IsSymbol sym
  => Row.Cons sym a otherRows ("_" :: b | errorRows)
  => Proxy sym -> Either a b -> Veither errorRows b
vfromEither proxy = either (\e -> Veither (inj proxy e)) (\a -> Veither (inj _veither a))

-- | Extract the value from a `Veither`, using a default value in case the underlying
-- | `Variant` is storing one of the error rows' values.
-- |
-- | ```
-- | vError :: Veither (foo :: Int) String
-- | vError = Veither (inj (Proxy :: Proxy "foo") 4)
-- |
-- | vSuccess :: Veither (foo :: Int) String
-- | vSuccess = pure "yay"
-- |
-- | vfromRight "" vError   == ""
-- | vfromRight "" vSuccess == "yay"
-- | ```
vfromRight ∷ forall errorRows a. a → Veither errorRows a → a
vfromRight default (Veither v) = case coerceV v of
  VariantRep a | a.type == "_" → a.value
  _ → default
  where
  coerceV ∷ Variant ("_" ∷ a | errorRows) → VariantRep a
  coerceV = unsafeCoerce

-- | Same as `vfromRight` but the default value is lazy.
vfromRight' ∷ forall errorRows a. (Unit → a) → Veither errorRows a → a
vfromRight' default (Veither v) = case coerceV v of
  VariantRep a | a.type == "_" → a.value
  _ → default unit
  where
  coerceV ∷ Variant ("_" ∷ a | errorRows) → VariantRep a
  coerceV = unsafeCoerce

-- | Extract the error value from a `Veither`, using a default value in case the underlying
-- | `Variant` is storing the `("_" :: a)` rows' values.
-- |
-- | ```
-- | vError :: Veither (foo :: Int) String
-- | vError = Veither (inj (Proxy :: Proxy "foo") 4)
-- |
-- | vSuccess :: Veither (foo :: Int) String
-- | vSuccess = pure "yay"
-- |
-- | vfromLeft  8 (case_ # on (Proxy :: Proxy "foo") identity) vError   == 4
-- | vfromRight 8 (case_ # on (Proxy :: Proxy "foo") identity) vSuccess == 8
-- | ```
vfromLeft ∷ forall errorRows a b. b → (Variant errorRows → b) → Veither errorRows a → b
vfromLeft default handleFailures (Veither v) =
  on _veither (const default) handleFailures v

-- | Same as `vfromLeft` but the default value is lazy.
vfromLeft' ∷ forall errorRows a b. (Unit → b) → (Variant errorRows → b) → Veither errorRows a → b
vfromLeft' default handleFailures (Veither v) =
  on _veither (\_ → default unit) handleFailures v

-- | Convert a `Maybe` value into a `Veither` value using a default value when the `Maybe` value is `Nothing`.
-- |
-- | ```
-- | mJust :: Maybe String
-- | mJust = Just "x"
-- |
-- | mNothing :: Maybe String
-- | mNothing = Nothing
-- |
-- | _foo :: Proxy "foo"
-- | _foo = Proxy
-- |
-- | vnote _foo 2 mJust    == (pure "y")             :: Veither (foo :: Int) String
-- | vnote _foo 2 mNothing == (Veither (inj _foo 2)) :: Veither (foo :: Int) String
-- | ```
vnote ∷ forall otherErrorRows errorRows s a b
   . Row.Cons s a otherErrorRows ("_" ∷ b | errorRows)
  => IsSymbol s
  => Proxy s → a → Maybe b → Veither errorRows b
vnote proxy a may = Veither (maybe (inj proxy a) (\b → inj _veither b) may)

-- | Same as `vnote` but the default value is lazy.
vnote' ∷ forall otherErrorRows errorRows s a b
   . Row.Cons s a otherErrorRows ("_" ∷ b | errorRows)
  => IsSymbol s
  => Proxy s → (Unit → a) → Maybe b → Veither errorRows b
vnote' proxy f may = Veither (maybe' (inj proxy <<< f) (\b → inj _veither b) may)

-- | Convert a `Veither` value into a `Maybe` value.
vhush ∷ forall errorRows a. Veither errorRows a → Maybe a
vhush = veither (const Nothing) Just

-- | Generate `Veither` with uniform probability given a record whose
-- | generators' labels correspond to the `Veither`'s labels
-- |
-- | ```
-- | -- Note: type annotations are needed! Otherwise, you'll get compiler errors.
-- | quickCheckGen do
-- |   v <- genVeitherUniform
-- |      -- first approach: annotate inline
-- |      { "_": genHappyPath :: Gen Int
-- |      , x: genXValues :: Gen (Maybe String)
-- |      , y: pure "foo" :: Gen String
-- |      }
-- |   -- rest of test...
-- |
-- | quickCheckGen do
-- |   let
-- |     -- second approach: use a let with annotations before usage
-- |     r :: { "_" :: Gen Int, x :: Gen (Maybe String), y :: Gen String }
-- |     r = { "_": genHappyPath, x: genXValues, y: pure "foo" }
-- |   v <- genVeitherUniform r
-- |   -- rest of test...
-- | ```
genVeitherUniform :: forall a errorRows otherGenRows rowList
  -- 2. Calculate what the rowList is
  .  RL.RowToList ("_" :: Gen a | otherGenRows) rowList
  -- 3. Pass all this information into the type class instance,
  => GenVariantUniform ("_" :: Gen a | otherGenRows) rowList ("_" :: a | errorRows)
  -- 1. Given a record that has a generator for every value in the row
  => Record ("_" :: Gen a | otherGenRows)
  -> Gen (Veither errorRows a)
genVeitherUniform rec = do
  let
    -- 4. Use the type class to create the list of generators
    vaList :: L.List (Gen (Variant ("_" :: a | errorRows)))
    vaList = mkUniformList rec (Proxy :: Proxy rowList)

    -- 5. This is guaranteed to be non-empty because there will always be a ("_" :: a) row
    vaNEA :: NonEmptyArray (Gen (Variant ("_" :: a | errorRows)))
    vaNEA = unsafePartial $ fromJust $ NEA.fromFoldable vaList

  -- 6. Choose one of the rows' generators and use it to generate a `Variant` whose rows fit the `Veither` rows
  randomVariant <- oneOf vaNEA
  pure $ Veither randomVariant

-- | Generate `Veither` with user-specified probability given a record whose
-- | generators' labels correspond to the `Veither`'s labels
-- |
-- | ```
-- | -- Note: type annotations are needed! Otherwise, you'll get compiler errors.
-- | quickCheckGen do
-- |   v <- genVeitherFrequency
-- |      -- first approach: annotate inline
-- |      { "_": genHappyPath :: Gen Int
-- |      , x: genXValues :: Gen (Maybe String)
-- |      , y: pure "foo" :: Gen String
-- |      }
-- |   -- rest of test...
-- |
-- | quickCheckGen do
-- |   let
-- |     -- second approach: use a let with annotations before usage
-- |     r :: { "_" :: Gen Int, x :: Gen (Maybe String), y :: Gen String }
-- |     r = { "_": genHappyPath, x: genXValues, y: pure "foo" }
-- |   v <- genVeitherFrequency r
-- |   -- rest of test...
-- | ```
genVeitherFrequncy :: forall a errorRows otherGenRows rowList
  -- 2. Calculate what the rowList is
  .  RL.RowToList ("_" :: Tuple Number (Gen a) | otherGenRows) rowList
  -- 3. Pass all this information into the type class instance,
  => GenVariantFrequency ("_" :: Tuple Number (Gen a) | otherGenRows) Number rowList ("_" :: a | errorRows)
--   1. Given a record whose labels match the labels in the `Veither`'s underlying `Variant`
--       and the corresponding type of the label stores two pieces of information:
--         a. an number that indicates how frequently a label's generator should be used used, and
--         b. the generator for the label's type
  => Record ("_" :: Tuple Number (Gen a) | otherGenRows)
  -> Gen (Veither errorRows a)
genVeitherFrequncy rec = do
  let
    -- 4. Use the type class to create the list of generators
    vaList :: L.List (Tuple Number (Gen (Variant ("_" :: a | errorRows))))
    vaList = mkFrequencyList rec (Proxy :: Proxy rowList)

    -- 5. Make the list nonempty, which is guaranteed to be safe because there will always be a ("_" :: a) row
    vaNEL :: NEA.NonEmptyArray (Tuple Number (Gen (Variant ("_" :: a | errorRows))))
    vaNEL = unsafePartial $ fromJust $ NEA.fromFoldable vaList

  -- 6. Use the function to determine how frequently a given label's generator should be used
  --     and use that generator to make a random variant whose rows fit the `Veither` rows
  randomVariant <- frequency vaNEL
  pure $ Veither randomVariant

instance arbitraryVeither :: (
  RL.RowToList ("_" :: a | errorRows) rowList,
  VariantArbitrarys ("_" :: a | errorRows) rowList
  ) => Arbitrary (Veither errorRows a) where
  arbitrary = do
    let
      -- Create the list of generators
      vaList :: L.List (Gen (Variant ("_" :: a | errorRows)))
      vaList = variantArbitrarys (Proxy :: Proxy ("_" :: a | errorRows)) (Proxy :: Proxy rowList)

      -- This is guaranteed to be non-empty because there will always be a ("_" :: a) row
      vaNEA = unsafePartial $ fromJust $ NEA.fromFoldable vaList

    -- Choose one of the rows' generators and use it to generate a
    -- `Variant` whose rows fit the `Veither` rows
    randomVariant <- oneOf vaNEA
    pure $ Veither randomVariant

-- | Creates a list where each generator within the list will produce a Variant
-- | for one of the rows in `("_" :: a | errorRows)`
class VariantArbitrarys :: Row Type -> RL.RowList Type -> Constraint
class VariantArbitrarys finalRow currentRL where
  variantArbitrarys :: Proxy finalRow -> Proxy currentRL -> L.List (Gen (Variant finalRow))

instance variantArbitrarysNil ∷ VariantArbitrarys ignore RL.Nil where
  variantArbitrarys _ _ = L.Nil

instance variantArbitrarysCons ∷ (
  IsSymbol sym,
  VariantArbitrarys final rlTail,
  Row.Cons sym a rowTail final,
  Arbitrary a
  ) ⇒ VariantArbitrarys final (RL.Cons sym a rlTail) where
  variantArbitrarys _ _ = do
    let
      va :: Gen (Variant final)
      va = do
        a <- arbitrary :: Gen a
        let
          v :: Variant final
          v = inj (Proxy :: Proxy sym) a
        pure v

    L.Cons va (variantArbitrarys (Proxy :: Proxy final) (Proxy ∷ Proxy rlTail))

foreign import data UnknownVariantValue :: Type

instance coarbitraryVeither :: (
  RL.RowToList ("_" :: a | errorRows) rl,
  VariantCoarbitrarys rl
  ) => Coarbitrary (Veither errorRows a) where
  coarbitrary :: forall r. Veither errorRows a -> Gen r -> Gen r
  coarbitrary (Veither v) = case coerceV v of
    VariantRep a -> variantCoarbitrarys (Proxy :: Proxy rl) a
    where
      coerceV ∷ Variant ("_" ∷ a | errorRows) → VariantRep UnknownVariantValue
      coerceV = unsafeCoerce

class VariantCoarbitrarys :: RL.RowList Type -> Constraint
class VariantCoarbitrarys currentRL where
  variantCoarbitrarys :: forall r. Proxy currentRL -> { type :: String, value :: UnknownVariantValue } -> (Gen r -> Gen r)

instance variantCoarbitrarysNil :: VariantCoarbitrarys RL.Nil where
  variantCoarbitrarys _ _ = impossible "coarbtirary"

instance variantCoarbitrarysCons :: (
  IsSymbol sym,
  Coarbitrary a,
  VariantCoarbitrarys tail) => VariantCoarbitrarys (RL.Cons sym a tail) where
  variantCoarbitrarys _ a =
    if a.type == reflectSymbol (Proxy :: Proxy sym)
      then coarbitrary (coerceA a.value)
      else variantCoarbitrarys (Proxy :: Proxy tail) a
    where
      coerceA ∷ UnknownVariantValue -> a
      coerceA = unsafeCoerce

class GenVariantUniform :: Row Type -> RL.RowList Type -> Row Type -> Constraint
class GenVariantUniform recordRows rl variantRows | recordRows -> variantRows where
  mkUniformList :: Record recordRows -> Proxy rl -> L.List (Gen (Variant variantRows))

instance genVariantUniformNil :: GenVariantUniform ignore1 RL.Nil ignore2 where
  mkUniformList _ _ = L.Nil

instance genVariantUniformCons :: (
  Row.Cons sym (Gen a) other recordRows,
  IsSymbol sym,
  Row.Cons sym a otherVariantRows variantRows,
  GenVariantUniform recordRows tail variantRows
  ) => GenVariantUniform recordRows (RL.Cons sym (Gen a) tail) variantRows where
  mkUniformList rec _ = do
    let
      _sym = Proxy :: Proxy sym

      genA :: Gen a
      genA = get _sym rec

      genV :: Gen (Variant variantRows)
      genV = do
        a <- genA
        pure (inj _sym a)

    L.Cons genV (mkUniformList rec (Proxy :: Proxy tail))

class GenVariantFrequency :: Row Type -> Type -> RL.RowList Type -> Row Type -> Constraint
class GenVariantFrequency recordRows b rl variantRows | recordRows -> b variantRows where
  mkFrequencyList :: Record recordRows -> Proxy rl -> L.List (Tuple b (Gen (Variant variantRows)))

instance genVariantFrequencyNil :: GenVariantFrequency ignore1 ignore2 RL.Nil ignore3 where
  mkFrequencyList _ _ = L.Nil

instance genVariantFrequencyCons :: (
  Row.Cons sym (Tuple b (Gen a)) other recordRows,
  IsSymbol sym,
  Row.Cons sym a otherVariantRows variantRows,
  GenVariantFrequency recordRows b tail variantRows
  ) => GenVariantFrequency recordRows b (RL.Cons sym (Tuple b (Gen a)) tail) variantRows where
  mkFrequencyList rec _ = do
    let
      _sym = Proxy :: Proxy sym

      theTuple :: Tuple b (Gen a)
      theTuple = get _sym rec

      genV :: Gen a -> Gen (Variant variantRows)
      genV genA = do
        a <- genA
        pure (inj _sym a)

    L.Cons (map genV theTuple) (mkFrequencyList rec (Proxy :: Proxy tail))
