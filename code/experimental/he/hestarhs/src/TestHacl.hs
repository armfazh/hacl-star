module TestHacl where

import Universum

import qualified Data.Time.Clock.POSIX as P
import System.Random (randomRIO)

import Hacl
import qualified Lib as L
import Playground


testBNs :: IO ()
testBNs = do
    a <- toBignumExact 500
    print =<< fromBignum 1 a
    b <- toBignumExact 100
    print =<< fromBignum 1 b

    c <- toBignumExact 0
    bnSub 1 1 a b c
    print =<< fromBignum 1 c

    d <- toBignumExact 0
    bnMulFitting 1 1 1 a b d
    print =<< fromBignum 1 d

    putText "mda\n"


testGM :: Int -> IO ()
testGM bits = do
    putTextLn "Testing GM"
    let test = do
          (p,q,y,r,m1,m2) <- genDataGM bits
          let n = p * q

          let bN = fromIntegral $ length $ inbase b64 n

          n' <- toBignum bN n
          p' <- toBignum bN p
          y' <- toBignum bN y
          r' <- toBignum bN r
          pmin1 <- toBignum bN (p-1)
          pmin1half <- toBignum bN ((p-1)`div`2)

          c1 <- toBignum bN 0
          c2 <- toBignum bN 0
          c3 <- toBignum bN 0


          time1 <- P.getPOSIXTime

          replicateM_ 99 $ gmEnc bN n' y' r' m1 c1
          gmEnc bN n' y' r' m2 c2

          time2 <- P.getPOSIXTime

          replicateM_ 99 $ gmDec bN p' pmin1 pmin1half c1
          m1' <- gmDec bN p' pmin1 pmin1half c1

          time3 <- P.getPOSIXTime

          replicateM_ 100 $ gmXor bN n' c1 c2 c3

          time4 <- P.getPOSIXTime


          when (m1 /= m1') $ error $ "GM failed: " <> show (p,q,y,r,m1,m2)
          pure (time2 - time1, time3 - time2, time4 - time3)

    let tries = 10
    timings <- replicateM tries test

    let average xs = foldr1 (+) xs / fromIntegral tries
    let avg1 = average $ map (view _1) timings
    let avg2 = average $ map (view _2) timings
    let avg3 = average $ map (view _3) timings

    putTextLn $ "Enc: " <> show (avg1 * 100) <> " ms"
    putTextLn $ "Dec: " <> show (avg2 * 100) <> " ms"
    putTextLn $ "Xor: " <> show (avg3 * 100) <> " ms"


testPaillier :: Int -> IO ()
testPaillier bits = do
    putTextLn "Testing paillier"
    let test = do
          (p,q,r,m1,m2) <- genDataPaillier bits
          let n = p * q
          let n2 = n * n

          let bN = fromIntegral $ length $ inbase b64 n2

          p' <- toBignum bN p
          q' <- toBignum bN q
          n' <- toBignum bN n
          n2' <- toBignum bN n2
          g' <- toBignum bN (n + 1)
          r' <- toBignum bN r
          m1' <- toBignum bN m1
          m2' <- toBignum bN m2
          lambda' <- toBignum bN 0
          l2inv' <- toBignum bN 0

          paillierToSec bN p' q' n' n2' g' lambda' l2inv'

          c1 <- toBignum bN 0
          c2 <- toBignum bN 0
          c3 <- toBignum bN 0
          d <- toBignum bN 0

          time1 <- P.getPOSIXTime

          replicateM_ 99 $ paillierEnc bN n' n2' g' r' m1' c1
          paillierEnc bN n' n2' g' r' m2' c2

          time2 <- P.getPOSIXTime

          replicateM_ 100 $ paillierDec bN p' q' n' n2' g' lambda' l2inv' c1 d

          time3 <- P.getPOSIXTime

          replicateM_ 100 $ paillierHomAdd bN n' n2' c1 c2 c3

          time4 <- P.getPOSIXTime

          replicateM_ 100 $ paillierHomMulScal bN n' n2' c1 m2' c3

          time5 <- P.getPOSIXTime


          m'' <- fromBignum bN d
          when (m1 /= m'') $ error $ "Paillier failed: " <> show (p,q,r,m1)

          pure (time2 - time1, time3 - time2, time4 - time3, time5 - time4)

    let tries = 100
    timings <- replicateM tries test

    let average xs = foldr1 (+) xs / fromIntegral tries
    let avg1 = average $ map (view _1) timings
    let avg2 = average $ map (view _2) timings
    let avg3 = average $ map (view _3) timings
    let avg4 = average $ map (view _4) timings

    putTextLn $ "Enc: " <> show (avg1 * 100) <> " ms"
    putTextLn $ "Dec: " <> show (avg2 * 100) <> " ms"
    putTextLn $ "Hom_add: " <> show (avg3 * 100) <> " ms"
    putTextLn $ "Hom_mul_scal: " <> show (avg4 * 100) <> " ms"

testPaillierPahe :: IO ()
testPaillierPahe = do
    putTextLn "Testing paillier PAHE"

    let n = 5
    sk <- paheKeyGen @PailSep n
    let pk = paheToPublic sk

    ms1 <- replicateM n $ randomRIO (0, 1000)
    ms2 <- replicateM n $ randomRIO (0, 1000)

    c1 <- paheEnc pk ms1
    c2 <- paheEnc pk ms2
    c3 <- paheSIMDAdd pk c1 c2
    d <- paheDec sk c3

    print $ d == map (uncurry (+)) (zip ms1 ms2)



testDGK :: IO ()
testDGK = do
    putTextLn "Testing DGK"

    let ufact = [(7,2),(5,1),(37,1),(41,1)]
    (p,q,u,v,g,h) <- genDataDGK ufact 512
    unless (L.exp (p*q) h v == 1) $ error "generated params are broken"
    unless (L.exp (p*q) g (u*v) == 1) $ error "generated params are broken"
    let n = p * q
    let bN = fromIntegral $ length $ inbase b64 n

    putTextLn "Params generated!"


    p' <- toBignum bN p
    q' <- toBignum bN q
    n' <- toBignum bN n
    u' <- toBignum bN u
    g' <- toBignum bN g
    h' <- toBignum bN h
    u_ps <- toBignumList bN $ map fst ufact
    u_es <- toBignumList bN $ map snd ufact
    v' <- toBignum bN v

    let test = do
          m1 <- randomRIO (0,u-1)
          m2 <- randomRIO (0,u-1)
          r <- randomRIO (0,n-1)

          r' <- toBignum bN r
          m1' <- toBignum bN m1
          m2' <- toBignum bN m2

          c1 <- toBignum bN 0
          c2 <- toBignum bN 0
          c3 <- toBignum bN 0
          c4 <- toBignum bN 0
          d <- toBignum bN 0

          let decrypt ciph =
                  dgkDec bN (fromIntegral $ length ufact)
                    p' q' n' u' u_ps u_es v' g' h' ciph d

          time1 <- P.getPOSIXTime

          replicateM_ 99 $ dgkEnc bN n' u' g' h' r' m1' c1
          dgkEnc bN n' u' g' h' r' m2' c2

          putTextLn "Pass1"
          time2 <- P.getPOSIXTime

          replicateM_ 100 $ decrypt c1

          putTextLn "Pass2"
          time3 <- P.getPOSIXTime

          replicateM_ 100 $ dgkHomAdd bN n' c1 c2 c3

          putTextLn "Pass3"
          time4 <- P.getPOSIXTime

          replicateM_ 100 $ dgkHomMulScal bN n' c1 m2' c4

          putTextLn "Pass4"
          time5 <- P.getPOSIXTime

          c'' <- fromBignum bN c1
          unless (c'' == (L.exp n g m1 * L.exp n h r) `mod` n) $
              error "encryption is broken"

          m'' <- fromBignum bN d
          when (m1 /= m'') $ error $ "DGK failed: " <> show (p,q,r,m1, m'')

          decrypt c3
          m3 <- fromBignum bN d
          when (m3 /= (m1 + m2) `mod` u) $ error "DGK hom add failed"

          decrypt c4
          m4 <- fromBignum bN d
          when (m4 /= (m1 * m2) `mod` u) $ error "DGK hom mul failed"

          pure (time2 - time1, time3 - time2, time4 - time3, time5 - time4)

    let tries = 5

    timings <- replicateM tries test

    let average xs = foldr1 (+) xs / fromIntegral tries
    let avg1 = average $ map (view _1) timings
    let avg2 = average $ map (view _2) timings
    let avg3 = average $ map (view _3) timings
    let avg4 = average $ map (view _4) timings

    putTextLn $ "Enc: " <> show (avg1 * 100) <> " ms"
    putTextLn $ "Dec: " <> show (avg2 * 100) <> " ms"
    putTextLn $ "Hom_add: " <> show (avg3 * 100) <> " ms"
    putTextLn $ "Hom_mul_scal: " <> show (avg4 * 100) <> " ms"