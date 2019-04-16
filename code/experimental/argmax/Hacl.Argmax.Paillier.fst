module Hacl.Argmax.Paillier

open FStar.Calc
open FStar.Mul

open Hacl.Argmax.Common


(* Internals *)

type fenu (n:comp) = r:fe n{isunit r}
type fen2 (n:comp) = fe (n * n)
type fen2u n = r:fen2 n{isunit r}

val in_base: #n:comp -> g:fe (n*n) -> Type0
let in_base #n g = exists (a:pos). b2t(fexp g (n * a) = 1)

type isg (n:comp) = g:fen2u n{in_base #n g}

// N plus one, for SMTPat not to throw warnings
val np1: #n:comp -> fen2 n
let np1 #n = 1 + n

val nplus1inbase: #n:comp -> Lemma
  (ensures (in_base (np1 #n) /\ isunit (np1 #n)))
  [SMTPat (np1 #n)]
let nplus1inbase #n = admit()

val encf: #n:comp -> g:isg n -> x:fe n -> y:fenu n -> fen2u n
let encf #n g x y =
  let r:fen2 n = fexp g x *% fexp (to_fe y) n in
  assume(isunit r);
  r

val is_res_class: #n:comp -> g:isg n -> w:fen2u n -> x:fe n -> Type0
let is_res_class #n g w x = exists y. encf g x y = w

// It is possible to get it checking every element of the preimage.
val res_class: #n:comp -> g:isg n -> w:fen2u n -> x:fe n{is_res_class g w x}
let res_class #n _ _ = admit()

val bigl:
     #n:comp
  -> u:fen2 n{u % n = 1}
  -> r:fe n{r = 0 <==> u = 1}
let bigl #n u = (u - 1) / n

// euler's totient
val etot: p:prm -> q:prm -> l:pos
let etot p q = lcm (p-1) (q-1)

val fltpq: p:prm -> q:prm -> w:fen2 (p*q) -> Lemma
  (ensures (let n = p*q in fexp w (etot p q) % n = 1))
  [SMTPat (fexp w (etot p q))]
let fltpq _ _ _ = admit()

// lemma 10 p227
val bigl_lemma1: p:prm -> q:prm -> w:fen2u (p*q) -> Lemma
  (ensures (let n = p * q in
            let x = res_class np1 w in
            let lm = etot p q in
            bigl (fexp w lm) = to_fe lm *% x))
let bigl_lemma1 _ _ _ = admit()

val bigl_lemma2: p:prm -> q:prm -> w:fen2u (p*q) -> g:isg (p*q) -> Lemma
  (ensures (let n = p * q in
            let a = res_class #n np1 w in
            let b = res_class #n np1 g in
            let c = res_class #n g w in
            isunit b /\ a *% finv b = c
            ))
let bigl_lemma2 _ _ _ _ = admit()


(* Keys *)

type secret =
  | Secret: p:prm
         -> q:prm{q <> p}
         -> g:isg (p*q)
         -> secret

type public =
  | Public: n:comp
         -> g:isg n
         -> public

val s2p: secret -> public
let s2p sec =
  Public (Secret?.p sec * Secret?.q sec)
         (Secret?.g sec)


(* Enc/Dec *)

type ciphertext (n:comp) = c:fen2u n

// TODO get rid of assumes in the enc/dec, move it to lemmas

val encrypt:
     p:public
  -> r:pos{r < Public?.n p}
  -> m:fe (Public?.n p)
  -> ciphertext (Public?.n p)
let encrypt pub r m =
  let res = fexp (Public?.g pub) m *% fexp (to_fe r) (Public?.n pub) in
  assume(isunit res);
  res


val decrypt:
     s:secret
  -> c:ciphertext (Public?.n (s2p s))
  -> m:fe (Public?.n (s2p s))
let decrypt sec c =
  let p = Secret?.p sec in
  let q = Secret?.q sec in
  let n = p * q in
  let g = Secret?.g sec in
  let lambda = etot p q in

  assume((fexp c lambda) % n = 1);
  let l1:fe n = bigl (fexp c lambda) in
  assume((fexp g lambda) % n = 1);
  let l2:fe n = bigl (fexp g lambda) in

  assume(isunit #n l2);
  let m = l1 *% finv l2 in
  m

(* Functional correctness *)

val decrypts_into_res_class:
     s:secret
  -> c:ciphertext (Public?.n (s2p s))
  -> Lemma
     (ensures (decrypt s c = res_class (Secret?.g s) c))
let decrypts_into_res_class sec c =
  let p = Secret?.p sec in
  let q = Secret?.q sec in
  let n = p * q in
  let g = Secret?.g sec in
  let lambda = etot p q in
  let lambda' = to_fe lambda in
  let r_c = res_class #n np1 c in
  let r_g = res_class #n np1 g in
  let r_z = res_class #n g c in

  assume((fexp c lambda) % n = 1);
  let l1:fe n = bigl (fexp c lambda) in
  assume((fexp g lambda) % n = 1);
  let l2:fe n = bigl (fexp g lambda) in
  assume(isunit l2);

  bigl_lemma1 p q c;
  assert(l1 = lambda' *% r_c);
  bigl_lemma1 p q g;
  assert(l2 = lambda' *% r_g);

  let m = l1 *% finv l2 in

  assert(decrypt sec c = m);

  bigl_lemma2 p q c g;
  // [g]_{1+n} = [1+n]_g^{-1}
  assert(isunit r_g);
  assert(r_c *% finv r_g = r_z);

  assume(isunit #n lambda');

  let lem1 (): Lemma (finv l2 = finv lambda' *% finv r_g) = finv_comm2 lambda' r_g in

  calc (==) {
    m;
   == { }
    l1 *% finv l2;
   == { lem1 () }
    (lambda' *% r_c) *% (finv lambda' *% finv r_g);
   == { mul4_assoc lambda' r_c (finv lambda') (finv r_g) }
    (lambda' *% finv lambda') *% (r_c *% finv r_g);
   == { }
    1 *% (r_c *% finv r_g);
   == { }
    r_c *% finv r_g;
   == { }
    r_z;
  }