{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Base of DynamicState SSC.

module Pos.Ssc.DynamicState.Base
       (
         -- * Types
         Commitment (..)
       , CommitmentSignature
       , SignedCommitment
       , CommitmentsMap
       , Opening (..)
       , OpeningsMap
       , SharesMap
       , VssCertificate
       , VssCertificatesMap

         -- * Helpers
       , genCommitmentAndOpening
       , isCommitmentId
       , isCommitmentIdx
       , isOpeningId
       , isOpeningIdx
       , isSharesId
       , isSharesIdx
       , mkSignedCommitment
       , secretToFtsSeed
       , xorFtsSeed

       -- * Verification
       , verifyCommitment
       , verifyCommitmentSignature
       , verifySignedCommitment
       , verifyOpening
       ) where


import           Data.Binary         (Binary)

import qualified Data.ByteString     as BS (pack, zipWith)
import qualified Data.HashMap.Strict as HM
import           Data.Ix             (inRange)
import           Data.List.NonEmpty  (NonEmpty (..))
import           Data.MessagePack    (MessagePack)
import           Data.SafeCopy       (base, deriveSafeCopySimple)
import           Data.Text.Buildable (Buildable (..))
import           Serokell.Util       (VerificationRes, verifyGeneric)
import           Universum

import           Pos.Constants       (k)
import           Pos.Crypto          (EncShare, PublicKey, Secret, SecretKey, SecretProof,
                                      SecretSharingExtra, SecureRandom (..), Share,
                                      Signature, Signed, Threshold, VssPublicKey,
                                      genSharedSecret, getDhSecret, secretToDhSecret,
                                      sign, verify, verifyEncShare, verifySecretProof)
import           Pos.Types.Types     (EpochIndex, FtsSeed (..), LocalSlotIndex,
                                      SlotId (..))

----------------------------------------------------------------------------
-- Types, instances
----------------------------------------------------------------------------

-- | Commitment is a message generated during the first stage of
-- MPC. It contains encrypted shares and proof of secret.
data Commitment = Commitment
    { commExtra  :: !SecretSharingExtra
    , commProof  :: !SecretProof
    , commShares :: !(HashMap VssPublicKey EncShare)
    } deriving (Show, Eq, Generic)

instance Binary Commitment
instance MessagePack Commitment

-- | Signature which ensures that commitment was generated by node
-- with given public key for given epoch.
type CommitmentSignature = Signature (EpochIndex, Commitment)

type SignedCommitment = (Commitment, CommitmentSignature)

type CommitmentsMap = HashMap PublicKey (Commitment, CommitmentSignature)

-- | Opening reveals secret.
newtype Opening = Opening
    { getOpening :: Secret
    } deriving (Show, Eq, Generic, Binary, Buildable)

instance MessagePack Opening

type OpeningsMap = HashMap PublicKey Opening

-- | Each node generates a 'FtsSeed', breaks it into 'Share's, and sends
-- those encrypted shares to other nodes. In a 'SharesMap', for each node we
-- collect shares which said node has received and decrypted.
--
-- Specifically, if node identified by 'PublicKey' X has received a share
-- from node identified by key Y, this share will be at @sharesMap ! X ! Y@.
type SharesMap = HashMap PublicKey (HashMap PublicKey Share)

-- | VssCertificate allows VssPublicKey to participate in MPC.
-- Each stakeholder should create a Vss keypair, sign public key with signing
-- key and send it into blockchain.
--
-- Other nodes accept this certificate if it is valid and if node really
-- has some stake.
type VssCertificate = Signed VssPublicKey

-- | VssCertificatesMap contains all valid certificates collected
-- during some period of time.
type VssCertificatesMap = HashMap PublicKey VssCertificate

deriveSafeCopySimple 0 'base ''Opening
deriveSafeCopySimple 0 'base ''Commitment

----------------------------------------------------------------------------
-- Functions
----------------------------------------------------------------------------

-- | Convert Secret to FtsSeed.
secretToFtsSeed :: Secret -> FtsSeed
secretToFtsSeed = FtsSeed . getDhSecret . secretToDhSecret

-- | Generate securely random FtsSeed.
genCommitmentAndOpening
    :: MonadIO m
    => Threshold -> NonEmpty VssPublicKey -> m (Commitment, Opening)
genCommitmentAndOpening n pks =
    liftIO . runSecureRandom . fmap convertRes . genSharedSecret n $ pks
  where
    convertRes (extra, secret, proof, shares) =
        ( Commitment
          { commExtra = extra
          , commProof = proof
          , commShares = HM.fromList $ zip (toList pks) shares
          }
        , Opening secret)

-- | Verify that Commitment is correct.
verifyCommitment :: Commitment -> Bool
verifyCommitment Commitment {..} = all verifyCommitmentDo $ HM.toList commShares
  where
    verifyCommitmentDo = uncurry (verifyEncShare commExtra)

-- | Verify signature in SignedCommitment using public key and epoch index.
verifyCommitmentSignature :: PublicKey -> EpochIndex -> SignedCommitment -> Bool
verifyCommitmentSignature pk epoch (comm, commSig) =
    verify pk (epoch, comm) commSig

-- | Verify SignedCommitment using public key and epoch index.
verifySignedCommitment :: PublicKey -> EpochIndex -> SignedCommitment -> VerificationRes
verifySignedCommitment pk epoch sc =
    verifyGeneric
        [ ( verifyCommitmentSignature pk epoch sc
          , "commitment has bad signature (e. g. for wrong epoch)")
        , ( verifyCommitment (fst sc)
          , "commitment itself is bad (e. g. bad shares")
        ]

-- | Verify that Secret provided with Opening corresponds to given commitment.
verifyOpening :: Commitment -> Opening -> Bool
verifyOpening Commitment {..} (Opening secret) =
    verifySecretProof commExtra secret commProof

-- | Apply bitwise xor to two FtsSeeds
xorFtsSeed :: FtsSeed -> FtsSeed -> FtsSeed
xorFtsSeed (FtsSeed a) (FtsSeed b) =
    FtsSeed $ BS.pack (BS.zipWith xor a b) -- fast due to rewrite rules

-- | Make signed commitment from commitment and epoch index using secret key.
mkSignedCommitment :: SecretKey -> EpochIndex -> Commitment -> SignedCommitment
mkSignedCommitment sk i c = (c, sign sk (i, c))

isCommitmentIdx :: LocalSlotIndex -> Bool
isCommitmentIdx = inRange (0, k - 1)

isOpeningIdx :: LocalSlotIndex -> Bool
isOpeningIdx = inRange (2 * k, 3 * k - 1)

isSharesIdx :: LocalSlotIndex -> Bool
isSharesIdx = inRange (4 * k, 5 * k - 1)

isCommitmentId :: SlotId -> Bool
isCommitmentId = isCommitmentIdx . siSlot

isOpeningId :: SlotId -> Bool
isOpeningId = isOpeningIdx . siSlot

isSharesId :: SlotId -> Bool
isSharesId = isSharesIdx . siSlot
