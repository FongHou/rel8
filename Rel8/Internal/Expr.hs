{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Rel8.Internal.Expr where

import Data.Coerce (Coercible)
import Data.Proxy (Proxy(..))
import Data.String (IsString(..))
import Data.Text
import qualified Opaleye as O
import qualified Opaleye.Internal.Column as O
import qualified Opaleye.Internal.HaskellDB.PrimQuery as O
import qualified Opaleye.PGTypes as O
import Rel8.Internal.DBType

--------------------------------------------------------------------------------
-- | Database-side PostgreSQL expressions of a given type.

data ExprT (m :: * -> *) t
  = ExprT O.PrimExpr 
  | Aggregate (Maybe (O.AggrOp, [O.OrderExpr], O.AggrDistinct))
              O.PrimExpr

type role ExprT representational representational

instance (IsString a, DBType a) => IsString (ExprT m a) where
  fromString = lit . fromString

instance {-# OVERLAPS#-} (IsString a, DBType a) => IsString (ExprT m (Maybe a)) where
  fromString = lit . Just . fromString

type Expr = ExprT O.Query

-- | It is assumed that any Haskell types that have a 'Num' instance also have
-- the corresponding operations in the database. Hence, Num a => Num (Expr a).
-- *However*, if this is not the case, you should `newtype` the Haskell type
-- and avoid providing a 'Num' instance, or you may write be able to write
-- ill-typed queries!
instance (DBType a, Num a) => Num (ExprT m a) where
  a + b = columnToExpr (O.binOp (O.:+) (exprToColumn a) (exprToColumn b))
  a * b = columnToExpr (O.binOp (O.:*) (exprToColumn a) (exprToColumn b))
  abs = dbFunction "abs"
  signum = columnToExpr @O.PGInt8 . signum . exprToColumn
  fromInteger = lit . fromInteger
  negate = columnToExpr @O.PGInt8 . negate . exprToColumn

--------------------------------------------------------------------------------
-- | (Unsafely) coerce the phantom type given to 'Expr'. This operation is
-- not witnessed by the database at all, so use with care! For example,
-- @unsafeCoerceExpr :: Expr Int -> Expr Text@ /will/ end up with an exception
-- when you finally try and run a query!
unsafeCoerceExpr :: forall b a m. ExprT m a -> ExprT m b
unsafeCoerceExpr (ExprT a) = ExprT a


--------------------------------------------------------------------------------
-- | Use a cast operation in the database layer to convert between Expr types.
-- This is unsafe as it is possible to introduce casts that cannot be performed
-- by PostgreSQL. For example,
-- @unsafeCastExpr "timestamptz" :: Expr Bool -> Expr UTCTime@ makes no sense.
unsafeCastExpr :: forall b a m. String -> ExprT m a -> ExprT m b
unsafeCastExpr t = columnToExpr . O.unsafeCast t . exprToColumn


--------------------------------------------------------------------------------
-- | Lift an 'Expr' to be nullable. Like the 'Just' constructor.
--
-- If an Expr is already nullable, then this acts like the identity function.
-- This is useful as it allows projecting an already-nullable column from a left
-- join.
class ToNullable a maybeA | a -> maybeA where
  toNullable :: ExprT m a -> ExprT m maybeA

instance ToNullableHelper a maybeA (IsMaybe a) => ToNullable a maybeA where
  toNullable = toNullableHelper (Proxy @(IsMaybe a))

--------------------------------------------------------------------------------
-- | A helper class to implement 'ToNullable' by scrutenising the argument
-- and partioning into 'Maybe'/'NotMaybe' while retaining functional
-- dependencies.
class isMaybe ~ IsMaybe a =>
        ToNullableHelper a maybeA isMaybe | isMaybe a -> maybeA where
  toNullableHelper :: proxy (join :: Bool) -> ExprT m a -> ExprT m maybeA

instance IsMaybe a ~ 'False => ToNullableHelper a (Maybe a) 'False where
  toNullableHelper _ = unsafeCoerceExpr @(Maybe a)

instance ToNullableHelper (Maybe a) (Maybe a) 'True where
  toNullableHelper _ = id


--------------------------------------------------------------------------------
type family IsMaybe a :: Bool where
  IsMaybe (Maybe a) = 'True
  IsMaybe _ = 'False


--------------------------------------------------------------------------------
-- | Convert an 'Expr' into an @opaleye@ 'O.Column'. Does not preserve the
-- phantom type.
exprToColumn :: forall a b m. ExprT m a -> O.Column b
exprToColumn (ExprT a) = O.Column a


--------------------------------------------------------------------------------
-- | Convert an @opaleye 'O.Column' into an 'Expr'. Does not preserve the
-- phantom type.
columnToExpr :: O.Column a -> ExprT m b
columnToExpr (O.Column a) = ExprT a


--------------------------------------------------------------------------------
-- | Safely coerce between 'Expr's. This uses GHC's 'Coercible' type class,
-- where instances are only available if the underlying representations of the
-- data types are equal. This routine is useful to cast out a newtype wrapper
-- and work with the underlying data.
--
-- If the @newtype@ wrapper has a custom 'DBType' (one not derived with
-- @GeneralizedNewtypeDeriving@) this function may be unsafe and could lead to
-- runtime exceptions.
coerceExpr :: Coercible a b => ExprT m a -> ExprT m b
coerceExpr (ExprT a) = ExprT a


--------------------------------------------------------------------------------
-- | Casts an 'Expr' as @text@.
dbShow :: DBType a => ExprT m a -> ExprT m Text
dbShow = unsafeCastExpr "text"


--------------------------------------------------------------------------------
-- | Lift a Haskell value into a literal database expression.
lit :: DBType a => a -> ExprT m a
lit = ExprT . formatLit dbTypeInfo


--------------------------------------------------------------------------------
class Function arg res where
  -- | Build a function of multiple arguments.
  mkFunctionGo :: ([O.PrimExpr] -> O.PrimExpr) -> arg -> res

instance (DBType a, arg ~ ExprT m a) =>
         Function arg (ExprT m res) where
  mkFunctionGo mkExpr (ExprT a) = ExprT (mkExpr [a])

instance (DBType a, arg ~ ExprT m a, Function args res) =>
         Function arg (args -> res) where
  mkFunctionGo f (ExprT a) = mkFunctionGo (f . (a :))

dbFunction :: Function args result => String -> args -> result
dbFunction = mkFunctionGo . O.FunExpr

nullaryFunction :: DBType a => String -> ExprT m a
nullaryFunction name = ExprT (O.FunExpr name [])
