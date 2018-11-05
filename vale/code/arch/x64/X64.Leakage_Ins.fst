module X64.Leakage_Ins
open X64.Machine_s
module S = X64.Bytes_Semantics_s
open X64.Taint_Semantics_s
open X64.Leakage_s
open X64.Leakage_Helpers
open X64.Bytes_Semantics

let rec has_mem_operand = function
  | [] -> false
  | a::q -> if OMem? a then true else has_mem_operand q

#reset-options "--initial_ifuel 2 --max_ifuel 2 --initial_fuel 4 --max_fuel 4 --z3rlimit 80"

let check_if_ins_consumes_fixed_time ins ts =
  let i = ins.i in
  let dsts, srcs = extract_operands i in
  let ftSrcs = operands_do_not_use_secrets srcs ts in
  let ftDsts = operands_do_not_use_secrets dsts ts in
  let fixedTime = ftSrcs && ftDsts in

  Classical.forall_intro_2 (fun x y -> lemma_operand_obs_list ts dsts x y);
  Classical.forall_intro_2 (fun x y -> lemma_operand_obs_list ts srcs x y);
  assert (fixedTime ==> (isConstantTime (Ins ins) ts));
  if S.Mulx64? i then begin
    let S.Mulx64 dst_hi dst_lo src = i in
    let taint = sources_taint srcs ts ins.t in
    if has_mem_operand dsts && taint <> ins.t then false, ts
    else let ts' = set_taint dst_lo ts taint in
    if operand_does_not_use_secrets dst_hi ts' then fixedTime, (set_taint dst_hi ts' taint)
    else false, ts
  end
  else
  let taint = sources_taint srcs ts ins.t in
  let taint = if S.AddCarry64? i || S.Adcx64? i then merge_taint taint ts.cfFlagsTaint else taint in
  if has_mem_operand dsts && taint <> ins.t then false, ts
  else
  let ts' = set_taints dsts ts taint in
  let b, ts' = match i with
    | S.Mov64 dst _ | S.AddLea64 dst _ _ -> begin
      match dst with
        | OConst _ -> false, ts (* Should not happen *)
        | OReg r -> fixedTime, ts'
        | OMem m -> fixedTime, ts'
    end
     | S.Mul64 _ -> fixedTime, (TaintState ts'.regTaint Secret Secret ts'.xmmTaint)

    | S.Xor64 dst src ->
        (* Special case for Xor : xor-ing an operand with itself erases secret data *)
        if dst = src then
              let ts' = set_taint dst ts' Public in
              fixedTime, TaintState ts'.regTaint Secret Secret ts'.xmmTaint
        else
            begin match dst with
              | OConst _ -> false, (TaintState ts'.regTaint Secret Secret ts'.xmmTaint) (* Should not happen *)
              | OReg r -> fixedTime, (TaintState ts'.regTaint Secret Secret ts'.xmmTaint)
              | OMem m -> fixedTime, (TaintState ts'.regTaint Secret Secret ts'.xmmTaint)
        end
   | S.Push src -> if Secret? (ts'.regTaint Rsp) || Secret? (operand_taint src ts' Public) then false, ts
     else fixedTime, ts'
   | S.Pop dst -> 
     // Pop should be a public instruction
     if Secret? (ts'.regTaint Rsp) || Secret? (ins.t) then false, ts 
     else fixedTime, ts'
   | S.Adox64 _ _ -> false, ts (* Unhandled yet *)
   | S.Add64 _ _ | S.AddCarry64 _ _ | S.Adcx64 _ _  -> begin
          match dsts with
        | [OConst _] -> true, (TaintState ts'.regTaint Secret taint ts'.xmmTaint) (* Should not happen *)
        | [OReg r] -> fixedTime, (TaintState ts'.regTaint Secret taint ts'.xmmTaint)
        | [OMem m] -> fixedTime, (TaintState ts'.regTaint Secret taint ts'.xmmTaint)
    end
    | _ ->
      match dsts with
      | [OConst _] -> false, (TaintState ts'.regTaint Secret Secret ts'.xmmTaint) (* Should not happen *)
      | [OReg r] -> fixedTime, (TaintState ts'.regTaint Secret Secret ts'.xmmTaint)
      | [OMem m] ->  fixedTime, (TaintState ts'.regTaint Secret Secret ts'.xmmTaint)
      | [] -> false, ts'  (* AR: this case was missing, Unhandled yet *)
  in
  b, ts'

val lemma_public_flags_same: (ts:taintState) -> (ins:tainted_ins{S.Mul64? ins.i}) -> Lemma (forall s1 s2.
  let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  b2t b ==>
publicFlagValuesAreSame ts s1 s2 ==> publicFlagValuesAreSame (snd (check_if_ins_consumes_fixed_time ins ts)) (taint_eval_ins ins s1) (taint_eval_ins ins s2))

let lemma_public_flags_same ts ins = ()

let frame_update_heap_x (ptr:int) (j:int) (v:nat64) (mem:S.heap) : Lemma
  (requires j < ptr \/ j >= ptr + 8)
  (ensures (let new_mem = S.update_heap64 ptr v mem in
    mem.[j] == new_mem.[j])) = frame_update_heap ptr v mem

let lemma_push_same_public_aux (ts:taintState) (ins:tainted_ins{S.Push? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2))
  = let S.Push src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    // We only need to help Z3 proving that public mem values are identical 
    // after executing this instruction

    let aux (x:int) : Lemma
      (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
      (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = ((S.eval_reg Rsp s1.state) - 8) % pow2_64 in
        let ptr2 = ((S.eval_reg Rsp s2.state) - 8) % pow2_64 in
        // Rsp is ensured to be Public if the taint analysis is successful
        assert (ptr1 == ptr2);
        let v1 = S.eval_operand src s1.state in
        let v2 = S.eval_operand src s2.state in
        // The instruction is executed after checking the taints of sources
        let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
        let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in
        if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? t then ()
          else (
            Opaque_s.reveal_opaque S.get_heap_val64_def;
            // If x is modified by Public values, values are identical            
            assert (v1 == v2);
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
        
    in Classical.forall_intro (Classical.move_requires aux)

let lemma_push_same_public (ts:taintState) (ins:tainted_ins{S.Push? ins.i}) (s1:traceState) (s2:traceState)
                           (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
          (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_push_same_public_aux ts ins s1 s2 fuel b) ts'

let lemma_pop_same_public_aux (ts:taintState) (ins:tainted_ins{S.Pop? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.Pop dst, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let op = OMem (MReg Rsp 0) in

    let v1 = S.eval_operand op s1.state in
    let v2 = S.eval_operand op s2.state in
    let aux_value () : Lemma (v1 == v2) = Opaque_s.reveal_opaque S.get_heap_val64_def in
    aux_value();

    // We only need to help Z3 proving that public mem values are identical 
    // after executing this instruction

    let aux (x:int) : Lemma
      (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
      (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        match dst with
        | OConst _ | OReg _ -> ()
        | OMem m -> begin
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        // Rsp is ensured to be Public if the taint analysis is successful
        assert (ptr1 == ptr2);
        // The instruction is executed after checking the taints of sources
        let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
        let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in
        if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? t then ()
          else (
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
        end
        
    in Classical.forall_intro (Classical.move_requires aux)


let lemma_pop_same_public (ts:taintState) (ins:tainted_ins{S.Pop? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_pop_same_public_aux ts ins s1 s2 fuel b) ts'

let lemma_mov_same_public_aux (ts:taintState) (ins:tainted_ins{S.Mov64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.Mov64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in

    let v1 = S.eval_operand src s1.state in
    let v2 = S.eval_operand src s2.state in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
        if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux)
    end

let lemma_mov_same_public (ts:taintState) (ins:tainted_ins{S.Mov64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_mov_same_public_aux ts ins s1 s2 fuel b) ts'

let lemma_add_same_public_aux (ts:taintState) (ins:tainted_ins{S.Add64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.Add64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in

    let v11 = S.eval_operand dst s1.state in
    let v12 = S.eval_operand src s1.state in
    let v21 = S.eval_operand dst s2.state in
    let v22 = S.eval_operand src s2.state in
    let sum1 = v11 + v12 in
    let sum2 = v21 + v22 in
    let new_carry1 = sum1 >= pow2_64 in
    let new_carry2 = sum2 >= pow2_64 in
    let v1 = sum1 % pow2_64 in
    let v2 = sum2 % pow2_64 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    let aux_carry () : Lemma 
      (requires Public? taint)
      (ensures new_carry1 == new_carry2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in


    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux_cf () : Lemma (publicCfFlagValuesAreSame ts' s1' s2') =
        if Secret? taint then () else aux_carry()
      in let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
         if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux); aux_cf()
    end

let lemma_add_same_public (ts:taintState) (ins:tainted_ins{S.Add64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_add_same_public_aux ts ins s1 s2 fuel b) ts'

let lemma_addlea_same_public_aux (ts:taintState) (ins:tainted_ins{S.AddLea64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.AddLea64 dst src1 src2, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in

    let v11 = S.eval_operand src1 s1.state in
    let v12 = S.eval_operand src2 s1.state in
    let v21 = S.eval_operand src1 s2.state in
    let v22 = S.eval_operand src2 s2.state in
    let sum1 = v11 + v12 in
    let sum2 = v21 + v22 in
    let v1 = sum1 % pow2_64 in
    let v2 = sum2 % pow2_64 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
         if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux)
    end

let lemma_addlea_same_public (ts:taintState) (ins:tainted_ins{S.AddLea64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_addlea_same_public_aux ts ins s1 s2 fuel b) ts'

#set-options "--z3rlimit 250"

let lemma_addcarry_same_public_aux (ts:taintState) (ins:tainted_ins{S.AddCarry64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.AddCarry64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in
    let taint = merge_taint taint ts.cfFlagsTaint in

    let v11 = S.eval_operand dst s1.state in
    let v12 = S.eval_operand src s1.state in
    let v21 = S.eval_operand dst s2.state in
    let v22 = S.eval_operand src s2.state in
    let c1 = if S.cf s1.state.S.flags then 1 else 0 in
    let c2 = if S.cf s2.state.S.flags then 1 else 0 in    
    let sum1 = v11 + v12 + c1 in
    let sum2 = v21 + v22 + c2 in
    let new_carry1 = sum1 >= pow2_64 in
    let new_carry2 = sum2 >= pow2_64 in
    let v1 = sum1 % pow2_64 in
    let v2 = sum2 % pow2_64 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) =
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    let aux_carry () : Lemma 
      (requires Public? taint)
      (ensures new_carry1 == new_carry2) =
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux_cf () : Lemma (publicCfFlagValuesAreSame ts' s1' s2') =
        if Secret? taint then () else aux_carry()    
      in let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
        if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux); aux_cf()
    end

let lemma_addcarry_same_public (ts:taintState) (ins:tainted_ins{S.AddCarry64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_addcarry_same_public_aux ts ins s1 s2 fuel b) ts'

#set-options "--z3rlimit 300"

let lemma_adcx_same_public_aux (ts:taintState) (ins:tainted_ins{S.Adcx64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.Adcx64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in
    let taint = merge_taint taint ts.cfFlagsTaint in

    let v11 = S.eval_operand dst s1.state in
    let v12 = S.eval_operand src s1.state in
    let v21 = S.eval_operand dst s2.state in
    let v22 = S.eval_operand src s2.state in
    let c1 = if S.cf s1.state.S.flags then 1 else 0 in
    let c2 = if S.cf s2.state.S.flags then 1 else 0 in    
    let sum1 = v11 + v12 + c1 in
    let sum2 = v21 + v22 + c2 in
    let new_carry1 = sum1 >= pow2_64 in
    let new_carry2 = sum2 >= pow2_64 in
    let v1 = sum1 % pow2_64 in
    let v2 = sum2 % pow2_64 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) =
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    let aux_carry () : Lemma 
      (requires Public? taint)
      (ensures new_carry1 == new_carry2) =
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux_cf () : Lemma (publicCfFlagValuesAreSame ts' s1' s2') =
        if Secret? taint then () else aux_carry()    
      in let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
        if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux); aux_cf()
    end

let lemma_adcx_same_public (ts:taintState) (ins:tainted_ins{S.Adcx64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_adcx_same_public_aux ts ins s1 s2 fuel b) ts'

#set-options "--z3rlimit 80"


let lemma_sub_same_public_aux (ts:taintState) (ins:tainted_ins{S.Sub64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.Sub64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in

    let v11 = S.eval_operand dst s1.state in
    let v12 = S.eval_operand src s1.state in
    let v21 = S.eval_operand dst s2.state in
    let v22 = S.eval_operand src s2.state in
    let v1 = (v11 - v12) % pow2_64 in
    let v2 = (v21 - v22) % pow2_64 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
         if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux)
    end

let lemma_sub_same_public (ts:taintState) (ins:tainted_ins{S.Sub64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_sub_same_public_aux ts ins s1 s2 fuel b) ts'

let lemma_mul_same_public_aux (ts:taintState) (ins:tainted_ins{S.Mul64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    lemma_public_flags_same ts ins;
    Opaque_s.reveal_opaque S.get_heap_val64_def

let lemma_mul_same_public (ts:taintState) (ins:tainted_ins{S.Mul64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_mul_same_public_aux ts ins s1 s2 fuel b) ts'

let lemma_mulx_same_public_aux (ts:taintState) (ins:tainted_ins{S.Mulx64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
  admit() // TODO

let lemma_mulx_same_public (ts:taintState) (ins:tainted_ins{S.Mulx64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_mulx_same_public_aux ts ins s1 s2 fuel b) ts'

(*val lemma_mulx_same_public: (ts:taintState) -> (ins:tainted_ins{let i, _, _ = ins.ops in S.Mulx64? i}) -> (s1:traceState) -> (s2:traceState) -> (fuel:nat) -> Lemma
(let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))

let lemma_mulx_same_public ts ins s1 s2 fuel =
  let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  let i, dsts, srcs = ins.ops in
  let r1 = taint_eval_ins ins s1 in
  let r2 = taint_eval_ins ins s2 in
  match dsts with
    | [OMem m1; OMem m2] ->
      let ptr1_hi = eval_maddr m1 s1.state in
      let ptr2_hi = eval_maddr m1 s2.state in
      let ptr1_lo = eval_maddr m2 s1.state in
      let ptr2_lo = eval_maddr m2 s2.state in
      begin match srcs with
      | [src1; src2] ->
      let v11 = eval_operand src1 s1.state in
      let v12 = eval_operand src2 s1.state in
      let v21 = eval_operand src1 s2.state in
      let v22 = eval_operand src2 s2.state in
      let v1_hi = FStar.UInt.mul_div #64 v11 v12 in
      let v1_lo = FStar.UInt.mul_mod #64 v11 v12 in
      let v2_hi = FStar.UInt.mul_div #64 v21 v22 in
      let v2_lo = FStar.UInt.mul_mod #64 v21 v22 in
      let s1' = update_operand_preserve_flags' (OMem m2) v1_lo s1.state in
      let s2' = update_operand_preserve_flags' (OMem m2) v2_lo s2.state in
      if not (valid_mem64 ptr1_hi s1'.mem) || not (valid_mem64 ptr2_hi s2'.mem)
        || not (valid_mem64 ptr1_lo s1.state.mem) || not (valid_mem64 ptr2_lo s2.state.mem) then ()
      else begin
      lemma_store_load_mem64 ptr1_hi v1_hi s1'.mem;
      lemma_store_load_mem64 ptr2_hi v2_hi s2'.mem;
      lemma_valid_store_mem64 ptr1_hi v1_hi s1'.mem;
      lemma_valid_store_mem64 ptr2_hi v2_hi s2'.mem;
      lemma_frame_store_mem64 ptr1_hi v1_hi s1'.mem;
      lemma_frame_store_mem64 ptr2_hi v2_hi s2'.mem;
      lemma_store_load_mem64 ptr1_lo v1_lo s1.state.mem;
      lemma_store_load_mem64 ptr2_lo v2_lo s2.state.mem;
      lemma_valid_store_mem64 ptr1_lo v1_lo s1.state.mem;
      lemma_valid_store_mem64 ptr2_lo v2_lo s2.state.mem;
      lemma_frame_store_mem64 ptr1_lo v1_lo s1.state.mem;
      lemma_frame_store_mem64 ptr2_lo v2_lo s2.state.mem;
      assert (b2t b ==> publicValuesAreSame ts s1 s2 /\ r1.state.X64.Memory_s.state.S.ok /\ r2.state.X64.Memory_s.state.S.ok /\ Public? ins.t ==> v1_hi == v2_hi);
      ()
      end
      end
    | [OMem m1; o] ->
      begin match srcs with
      | [src1; src2] ->
      let v11 = eval_operand src1 s1.state in
      let v12 = eval_operand src2 s1.state in
      let v21 = eval_operand src1 s2.state in
      let v22 = eval_operand src2 s2.state in
      let v1_hi = FStar.UInt.mul_div #64 v11 v12 in
      let v1_lo = FStar.UInt.mul_mod #64 v11 v12 in
      let v2_hi = FStar.UInt.mul_div #64 v21 v22 in
      let v2_lo = FStar.UInt.mul_mod #64 v21 v22 in
      let s1' = update_operand_preserve_flags' o v1_lo s1.state in
      let s2' = update_operand_preserve_flags' o v2_lo s2.state in
      let ptr1_hi = eval_maddr m1 s1' in
      let ptr2_hi = eval_maddr m1 s2' in
      if not (valid_mem64 ptr1_hi s1.state.mem) || not (valid_mem64 ptr2_hi s2.state.mem) then ()
      else begin
      lemma_store_load_mem64 ptr1_hi v1_hi s1'.mem;
      lemma_store_load_mem64 ptr2_hi v2_hi s2'.mem;
      lemma_valid_store_mem64 ptr1_hi v1_hi s1'.mem;
      lemma_valid_store_mem64 ptr2_hi v2_hi s2'.mem;
      lemma_frame_store_mem64 ptr1_hi v1_hi s1'.mem;
      lemma_frame_store_mem64 ptr2_hi v2_hi s2'.mem
      end
      end
    | [o; OMem m2] ->
      begin match srcs with
      | [src1; src2] ->
      let v11 = eval_operand src1 s1.state in
      let v12 = eval_operand src2 s1.state in
      let v21 = eval_operand src1 s2.state in
      let v22 = eval_operand src2 s2.state in
      let v1_hi = FStar.UInt.mul_div #64 v11 v12 in
      let v1_lo = FStar.UInt.mul_mod #64 v11 v12 in
      let v2_hi = FStar.UInt.mul_div #64 v21 v22 in
      let v2_lo = FStar.UInt.mul_mod #64 v21 v22 in
      let ptr1_lo = eval_maddr m2 s1.state in
      let ptr2_lo = eval_maddr m2 s2.state in
      if not (valid_mem64 ptr1_lo s1.state.mem) || not (valid_mem64 ptr2_lo s2.state.mem) then ()
      else begin
      lemma_store_load_mem64 ptr1_lo v1_lo s1.state.mem;
      lemma_store_load_mem64 ptr2_lo v2_lo s2.state.mem;
      lemma_valid_store_mem64 ptr1_lo v1_lo s1.state.mem;
      lemma_valid_store_mem64 ptr2_lo v2_lo s2.state.mem;
      lemma_frame_store_mem64 ptr1_lo v1_lo s1.state.mem;
      lemma_frame_store_mem64 ptr2_lo v2_lo s2.state.mem
      end
      end
    | _ -> ()
*)


let lemma_imul_same_public_aux (ts:taintState) (ins:tainted_ins{S.IMul64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.IMul64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in

    let v11 = S.eval_operand dst s1.state in
    let v12 = S.eval_operand src s1.state in
    let v21 = S.eval_operand dst s2.state in
    let v22 = S.eval_operand src s2.state in
    let v1 = FStar.UInt.mul_mod #64 v11 v12 in
    let v2 = FStar.UInt.mul_mod #64 v21 v22 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
         if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux)
    end

let lemma_imul_same_public (ts:taintState) (ins:tainted_ins{S.IMul64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_imul_same_public_aux ts ins s1 s2 fuel b) ts'

val lemma_aux_xor: (x:nat64) -> Lemma (Types_s.ixor x x = 0)

let lemma_aux_xor x =
  TypesNative_s.reveal_ixor 64 x x;
  FStar.UInt.logxor_self #64 x

let lemma_xor_same_public_aux (ts:taintState) (ins:tainted_ins{S.Xor64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.Xor64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    Classical.forall_intro lemma_aux_xor;

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in

    let v11 = S.eval_operand dst s1.state in
    let v12 = S.eval_operand src s1.state in
    let v21 = S.eval_operand dst s2.state in
    let v22 = S.eval_operand src s2.state in
    let v1 = Types_s.ixor v11 v12 in
    let v2 = Types_s.ixor v21 v22 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
         if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux)
    end

let lemma_xor_same_public (ts:taintState) (ins:tainted_ins{S.Xor64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_xor_same_public_aux ts ins s1 s2 fuel b) ts'


let lemma_and_same_public_aux (ts:taintState) (ins:tainted_ins{S.And64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.And64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in

    let v11 = S.eval_operand dst s1.state in
    let v12 = S.eval_operand src s1.state in
    let v21 = S.eval_operand dst s2.state in
    let v22 = S.eval_operand src s2.state in
    let v1 = Types_s.iand v11 v12 in
    let v2 = Types_s.iand v21 v22 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
         if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux)
    end

let lemma_and_same_public (ts:taintState) (ins:tainted_ins{S.And64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_and_same_public_aux ts ins s1 s2 fuel b) ts'

let lemma_shr_same_public_aux (ts:taintState) (ins:tainted_ins{S.Shr64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.Shr64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in

    let v11 = S.eval_operand dst s1.state in
    let v12 = S.eval_operand src s1.state in
    let v21 = S.eval_operand dst s2.state in
    let v22 = S.eval_operand src s2.state in
    let v1 = Types_s.ishr v11 v12 in
    let v2 = Types_s.ishr v21 v22 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
         if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux)
    end

let lemma_shr_same_public (ts:taintState) (ins:tainted_ins{S.Shr64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_shr_same_public_aux ts ins s1 s2 fuel b) ts'

let lemma_shl_same_public_aux (ts:taintState) (ins:tainted_ins{S.Shl64? ins.i}) (s1:traceState) (s2:traceState)
                               (fuel:nat) (b:bool) (ts':taintState)
  :Lemma (requires ((b, ts') == check_if_ins_consumes_fixed_time ins ts /\ b /\
                    is_explicit_leakage_free_lhs (Ins ins) fuel ts ts' s1 s2))
         (ensures  (is_explicit_leakage_free_rhs (Ins ins) fuel ts ts' s1 s2)) =
    let S.Shl64 dst src, t = ins.i, ins.t in
    let dsts, srcs = extract_operands ins.i in

    let r1 = taint_eval_code (Ins ins) fuel s1 in
    let r2 = taint_eval_code (Ins ins) fuel s2 in

    let s1' = Some?.v r1 in
    let s2' = Some?.v r2 in

    let s1b = S.run (S.check (taint_match_list srcs t s1.memTaint)) s1.state in
    let s2b = S.run (S.check (taint_match_list srcs t s2.memTaint)) s2.state in

    let taint = sources_taint srcs ts ins.t in

    let v11 = S.eval_operand dst s1.state in
    let v12 = S.eval_operand src s1.state in
    let v21 = S.eval_operand dst s2.state in
    let v22 = S.eval_operand src s2.state in
    let v1 = Types_s.ishl v11 v12 in
    let v2 = Types_s.ishl v21 v22 in

    let aux_value () : Lemma 
      (requires Public? taint)
      (ensures v1 == v2) = 
      Opaque_s.reveal_opaque S.get_heap_val64_def 
    in

    match dst with
    | OConst _ -> ()
    | OReg r -> if Secret? taint then () else aux_value()
    | OMem m -> begin
      let aux (x:int) : Lemma
        (requires Public? s1'.memTaint.[x] || Public? s2'.memTaint.[x])
        (ensures s1'.state.S.mem.[x] == s2'.state.S.mem.[x]) =
        let ptr1 = S.eval_maddr m s1.state in
        let ptr2 = S.eval_maddr m s2.state in
        assert (ptr1 == ptr2);
         if x < ptr1 || x >= ptr1 + 8 then (
          // If we're outside the modified area, nothing changed, the property still holds
          frame_update_heap_x ptr1 x v1 s1b.S.mem;
          frame_update_heap_x ptr1 x v2 s2b.S.mem
        ) else (
          if Secret? taint then ()
          else (
            aux_value();
            correct_update_get ptr1 v1 s1b.S.mem;
            correct_update_get ptr1 v2 s2b.S.mem;
            // If values are identical, the bytes also are identical
            same_mem_get_heap_val ptr1 s1'.state.S.mem s2'.state.S.mem
          )
        )
      
      in Classical.forall_intro (Classical.move_requires aux)
    end

let lemma_shl_same_public (ts:taintState) (ins:tainted_ins{S.Shl64? ins.i}) (s1:traceState) (s2:traceState) 
  (fuel:nat)
  :Lemma (let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))
  = let b, ts' = check_if_ins_consumes_fixed_time ins ts in
    Classical.move_requires (lemma_shl_same_public_aux ts ins s1 s2 fuel b) ts'

#reset-options "--initial_ifuel 2 --max_ifuel 2 --initial_fuel 4 --max_fuel 4 --z3rlimit 20"
val lemma_ins_same_public: (ts:taintState) -> (ins:tainted_ins{not (is_xmm_ins ins)}) -> (s1:traceState) -> (s2:traceState) -> (fuel:nat) -> Lemma
(let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  (b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2))

let lemma_ins_same_public ts ins s1 s2 fuel =
  match ins.i with
  | S.Cpuid -> admit() // TODO
  | S.Mov64 _ _ -> lemma_mov_same_public ts ins s1 s2 fuel
  | S.Add64 _ _ -> lemma_add_same_public ts ins s1 s2 fuel
  | S.AddLea64 _ _ _ -> lemma_addlea_same_public ts ins s1 s2 fuel
  | S.Sub64 _ _ -> lemma_sub_same_public ts ins s1 s2 fuel
  | S.IMul64 _ _ -> lemma_imul_same_public ts ins s1 s2 fuel
  | S.And64 _ _ -> lemma_and_same_public ts ins s1 s2 fuel
  | S.Mul64 _ -> lemma_mul_same_public ts ins s1 s2 fuel
  | S.Mulx64 _ _ _ -> lemma_mulx_same_public ts ins s1 s2 fuel // TODO
  | S.Xor64 _ _ -> lemma_xor_same_public ts ins s1 s2 fuel
  | S.AddCarry64 _ _ -> lemma_addcarry_same_public ts ins s1 s2 fuel
  | S.Adcx64 _ _ -> lemma_adcx_same_public ts ins s1 s2 fuel
  | S.Shl64 _ _ -> lemma_shl_same_public ts ins s1 s2 fuel
  | S.Shr64 _ _ -> lemma_shr_same_public ts ins s1 s2 fuel
  | S.Push _ -> lemma_push_same_public ts ins s1 s2 fuel
  | S.Pop _ -> lemma_pop_same_public ts ins s1 s2 fuel
  | S.Adox64 _ _ -> () // TODO

let lemma_ins_leakage_free ts ins =
  let b, ts' = check_if_ins_consumes_fixed_time ins ts in
  let p s1 s2 fuel = b2t b ==> isExplicitLeakageFreeGivenStates (Ins ins) fuel ts ts' s1 s2 in
  let my_lemma s1 s2 fuel : Lemma(p s1 s2 fuel) = lemma_ins_same_public ts ins s1 s2 fuel in
  let open FStar.Classical in
  forall_intro_3 my_lemma
