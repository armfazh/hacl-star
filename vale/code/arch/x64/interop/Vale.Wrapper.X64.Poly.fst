module Vale.Wrapper.X64.Poly

module DV = LowStar.BufferView.Down
open Vale.Interop.Base
open Vale.AsLowStar.MemoryHelpers
open Vale.Poly1305.Spec_s
module LSig = Vale.AsLowStar.LowStarSig
open Vale.X64.MemoryAdapters
module V = Vale.X64.Decls

#set-options "--z3rlimit 100 --max_fuel 0 --max_ifuel 0"

let x64_poly1305 ctx_b inp_b len finish =
  let h0 = get () in
  DV.length_eq (get_downview inp_b);
  DV.length_eq (get_downview ctx_b);
  math_aux inp_b (readable_words (UInt64.v len));
  Classical.forall_intro (bounded_buffer_addrs TUInt8 TUInt64 h0 inp_b);
  as_vale_buffer_len #TUInt8 #TUInt64 inp_b;
  let x, _ = Vale.Stdcalls.X64.Poly.x64_poly1305 ctx_b inp_b len finish () in
  let h1 = get () in
  assert (Seq.equal
    (LSig.uint_to_nat_seq_t TUInt64 (UV.as_seq h1 (UV.mk_buffer (get_downview inp_b) Vale.Interop.Views.up_view64)))
    (uint64_to_nat_seq (UV.as_seq h1 (UV.mk_buffer (get_downview inp_b) Vale.Interop.Views.up_view64))));
  ()
