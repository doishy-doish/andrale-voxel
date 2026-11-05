(module
  (memory (export "memory") 200 512)
  (global $SEED (mut i32) (i32.const 0))

  ;; ==========================================================================
  ;; DEEP TIME — world-gen version + arena geometry + GEO parameter table.
  ;;
  ;; $WGV selects the generator. 1 = the original generator, FROZEN FOREVER
  ;; byte-for-byte (a save's terrain is regenerated from its seed on every
  ;; load, so changing genChunk would retroactively reshape every existing
  ;; world — the gate makes that impossible). 2 = DEEP TIME. The JS side picks
  ;; per save (buildSaveObj.worldgen) and calls setWorldgen before any gen.
  ;;
  ;; $AW/$WH/$ASL are the block-arena geometry: width (x AND z extent, with a
  ;; 1-block x/z halo), the WORLD height (interior voxels meshed), and the
  ;; z-slice byte stride (AW * (WH + 2)). They were literals 18/64/1188; as
  ;; globals a world can be taller than 64 without touching the kernel text.
  ;;
  ;; THE BOUND. $packV stores a corner's y as y+1 in the 7 bits at 5..11, so the
  ;; largest corner it can represent is 126 — and $cornerGrid writes the TOP
  ;; corner of a block at y as y+1 too, so the tallest corner a WH-tall world can
  ;; emit is WH. Hence WH <= 126 and the arena is at most 18 x 128 x 18 = 41 472
  ;; bytes. (Going to 128 INTERIOR levels would need an 8-bit y field; the only
  ;; spare bit is a second one out of the light field, which costs 4x the
  ;; brightness quantisation step — see the JS note at the top of index.html.)
  ;; setGeom is called by the JS World constructor with the addresses/sizes it
  ;; already passes to genChunk/meshChunk, so the two can never disagree.
  ;;
  ;; THE FAR-EDGE OOB READ (frozen behaviour - do not "fix" without a new
  ;; worldgen version). $cornerAO starts its three samples from the quad's
  ;; corner CELL and walks out by dir/aA/aB. When the greedy pass extends a quad
  ;; all the way to the slice's far halo edge (z = 16 of 18), that corner cell IS
  ;; the halo cell, so the deepest sample lands ~1170 bytes PAST the end of the
  ;; arena (the arena is 21 384 bytes at WH = 64) with no bounds check. Whatever
  ;; memory the map happens to put there is read as a voxel and feeds AO/light,
  ;; which is why the post-arena layout is load-bearing: the legacy map put
  ;; HEIGHTS, OUT, a 12-byte pad and the head of MASK in that window, and every
  ;; existing world's chunk borders were shaded from those bytes. $SCR (the
  ;; corner scratch) is passed in via setGeom for the same reason - it sits in
  ;; the window too. A bounds-checked $cornerAO is a candidate for a later worldgen
  ;; version (6 was spent on the cave system); it cannot be a quiet fix to this one.
  ;;
  ;; GEO (0x800, below the face table) is a f64 parameter table: every
  ;; altitude, noise scale/amplitude and threshold the generator uses. v1
  ;; writes exactly today's constants into it (bit-identical doubles), so the
  ;; numbers become data without moving a single voxel.
  ;; ==========================================================================
  (global $WGV (mut i32) (i32.const 1))
  ;; v3's relief-bias switch (see $relief). Kept SEPARATE from $WGV so a world made
  ;; by v1 or v2 evaluates the height exactly as it always did: with $RELBIAS = 0
  ;; the extra block in $genChunkV2 is a branch that is never taken, i.e. v2's
  ;; output stays bit-identical (verified with the 400-hash corpus).
  (global $RELBIAS (mut i32) (i32.const 0))
  (global $AW (mut i32) (i32.const 18))
  (global $WH (mut i32) (i32.const 64))
  (global $ASL (mut i32) (i32.const 1188))
  ;; Stride of one province's slice of the stratigraphic-column table (COL_BASE,
  ;; see $genChunkV2). It is WH + 2 because the table is indexed by ABSOLUTE y,
  ;; so the kernel can read "what rock is at this world height in this province"
  ;; with one byte load and no per-column state. setGeom keeps it in step with
  ;; the arena, so a taller world needs no kernel change.
  (global $COLSL (mut i32) (i32.const 66))
  ;; The 12-byte corner-grid scratch that $greedyPass hands to $cornerGrid (and
  ;; reads back through $cornerAO's neighbouring samples). JS supplies the live
  ;; value via setGeom because this slot must stay where the legacy map put it:
  ;; $cornerAO can sample past the arena's far edge, so whatever bytes live here
  ;; are read as if they were voxels (see the OOB note in the header).
  (global $SCR (mut i32) (i32.const 0x157F0))

  ;; GEO slot indices (JS: core.js GEO_* must match)
  ;;  0 hBase  1 hAmp1  2 hAmp2  3 hAmp3  4 s1     5 s2     6 s3
  ;;  7 hMin   8 hMax   9 seaY  10 snowY  11 shoreHi 12 deepHi 13 bandLo
  ;; 14 bandHi 15 moistT 16 waterMaxY 17 moistS 18 moistOx 19 moistOz
  ;; 20 caveA 21 caveB 22 caveA2 23 caveB2   (v1-v5's 3-D cave thresholds; v6
  ;;                                          reads none of them)
  ;; 24 n3xy 25 n3y 26 denMin 27 denMax 28 denLo 29 denHi 30 pvMul 31 ovhMul
  ;; 32 contS 33 eroS 34 pvS 35 fldGain 36 denPad 37 denA 38 denB
  ;; 39 cavSat 40 cavDriftF 41 cavPilT 42 cavKarst 43 cavPhrW 44 cavPhrH
  ;; 45 cavOct 46 cavDOct 47 cavRoof        (v6 cave scalars; see $caveNet)
  (func $g (param $i i32) (result f64)
    (f64.load (i32.add (i32.const 0x800) (i32.mul (local.get $i) (i32.const 8)))))

  (func (export "setWorldgen") (param $v i32)
    (global.set $WGV (local.get $v))
    (global.set $RELBIAS (if (result i32) (i32.ge_s (local.get $v) (i32.const 3)) (then (i32.const 1)) (else (i32.const 0)))))
  (func (export "setGeom") (param $aw i32) (param $wh i32) (param $asl i32) (param $scr i32)
    (global.set $AW (local.get $aw))
    (global.set $WH (local.get $wh))
    (global.set $ASL (local.get $asl))
    (global.set $SCR (local.get $scr))
    (global.set $COLSL (i32.add (local.get $wh) (i32.const 2))))
  (func (export "getArenaBytes") (result i32)
    (i32.mul (global.get $AW) (global.get $ASL)))

  (data (i32.const 0x1000)
    "\01\02\00\00\01\00"
    "\02\01\00\00\00\01"
    "\02\00\01\00\01\02"
    "\00\02\01\00\00\03"
    "\00\01\02\00\01\04"
    "\01\00\02\00\00\05")

  (func $g8 (param $p i32) (result i32)
    (i32.load8_u (local.get $p)))

  (func $mix (param $x i32) (result i32)
    (local $t i32)
    (local.set $t (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 16))))
    (local.set $t (i32.mul (local.get $t) (i32.const 0x7FEB352D)))
    (local.set $t (i32.xor (local.get $t) (i32.shr_u (local.get $t) (i32.const 15))))
    (local.set $t (i32.mul (local.get $t) (i32.const 0x846CA68B)))
    (i32.xor (local.get $t) (i32.shr_u (local.get $t) (i32.const 16))))

  (func $hash2 (param $ix i32) (param $iz i32) (param $salt i32) (result i32)
    (local $h i32)
    (local.set $h (i32.xor (global.get $SEED)
      (i32.xor (i32.mul (local.get $ix) (i32.const 0x9E3779B9))
               (i32.mul (local.get $iz) (i32.const 0x85EBCA6B)))))
    (local.set $h (i32.xor (local.get $h) (local.get $salt)))
    (call $mix (local.get $h)))

  (func $rand01 (param $h i32) (result f64)
    (f64.div (f64.convert_i32_u (i32.and (local.get $h) (i32.const 0xFFFFFF)))
             (f64.const 16777216.0)))

  (func $noise2 (param $x f64) (param $z f64) (param $salt i32) (result f64)
    (local $ix i32) (local $iz i32) (local $fx f64) (local $fz f64)
    (local $a f64) (local $b f64) (local $c f64) (local $d f64)
    (local $sx f64) (local $sz f64) (local $mx f64)
    (local.set $ix (i32.trunc_f64_s (f64.floor (local.get $x))))
    (local.set $iz (i32.trunc_f64_s (f64.floor (local.get $z))))
    (local.set $fx (f64.sub (local.get $x) (f64.convert_i32_s (local.get $ix))))
    (local.set $fz (f64.sub (local.get $z) (f64.convert_i32_s (local.get $iz))))
    (local.set $a (call $rand01 (call $hash2 (local.get $ix) (local.get $iz) (local.get $salt))))
    (local.set $b (call $rand01 (call $hash2 (i32.add (local.get $ix) (i32.const 1)) (local.get $iz) (local.get $salt))))
    (local.set $c (call $rand01 (call $hash2 (local.get $ix) (i32.add (local.get $iz) (i32.const 1)) (local.get $salt))))
    (local.set $d (call $rand01 (call $hash2 (i32.add (local.get $ix) (i32.const 1)) (i32.add (local.get $iz) (i32.const 1)) (local.get $salt))))
    (local.set $sx (f64.mul (f64.mul (local.get $fx) (local.get $fx))
                            (f64.sub (f64.const 3.0) (f64.mul (f64.const 2.0) (local.get $fx)))))
    (local.set $sz (f64.mul (f64.mul (local.get $fz) (local.get $fz))
                            (f64.sub (f64.const 3.0) (f64.mul (f64.const 2.0) (local.get $fz)))))
    (local.set $mx (f64.mul (f64.mul (f64.add (f64.sub (f64.sub (local.get $a) (local.get $b)) (local.get $c)) (local.get $d))
                                     (local.get $sx))
                            (local.get $sz)))
    (f64.add (f64.add (f64.add (local.get $a)
                               (f64.mul (f64.sub (local.get $b) (local.get $a)) (local.get $sx)))
                      (f64.mul (f64.sub (local.get $c) (local.get $a)) (local.get $sz)))
             (local.get $mx)))

  (func $fbm (param $x f64) (param $z f64) (param $oct i32) (param $salt i32) (result f64)
    (local $i i32) (local $sum f64) (local $tot f64) (local $w f64) (local $s f64) (local $sc f64)
    (local.set $i (i32.const 0))
    (local.set $sum (f64.const 0.0))
    (local.set $tot (f64.const 0.0))
    (local.set $w (f64.const 1.0))
    (local.set $sc (f64.const 1.0))
    (block $bEnd
      (loop $bLoop
        (br_if $bEnd (i32.ge_s (local.get $i) (local.get $oct)))
        (local.set $s (call $noise2 (f64.mul (local.get $x) (local.get $sc))
                                    (f64.mul (local.get $z) (local.get $sc))
                                    (i32.add (local.get $salt) (i32.mul (local.get $i) (i32.const 0x9E3779B9)))))
        (local.set $sum (f64.add (local.get $sum) (f64.mul (local.get $s) (local.get $w))))
        (local.set $tot (f64.add (local.get $tot) (local.get $w)))
        (local.set $w (f64.mul (local.get $w) (f64.const 0.5)))
        (local.set $sc (f64.mul (local.get $sc) (f64.const 2.0)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $bLoop)))
    (f64.div (local.get $sum) (local.get $tot)))

  (func $heightAt (param $gx i32) (param $gz i32) (result i32)
    (local $n1 f64) (local $n2 f64) (local $n3 f64) (local $h f64)
    (local $fx f64) (local $fz f64)
    (local.set $fx (f64.mul (f64.convert_i32_s (local.get $gx)) (call $g (i32.const 4))))
    (local.set $fz (f64.mul (f64.convert_i32_s (local.get $gz)) (call $g (i32.const 4))))
    (local.set $n1 (call $fbm (local.get $fx) (local.get $fz) (i32.const 3) (i32.const 0xD3E4F5)))
    (local.set $fx (f64.mul (f64.convert_i32_s (local.get $gx)) (call $g (i32.const 5))))
    (local.set $fz (f64.mul (f64.convert_i32_s (local.get $gz)) (call $g (i32.const 5))))
    (local.set $n2 (call $fbm (local.get $fx) (local.get $fz) (i32.const 2) (i32.const 0x123456)))
    (local.set $fx (f64.mul (f64.convert_i32_s (local.get $gx)) (call $g (i32.const 6))))
    (local.set $fz (f64.mul (f64.convert_i32_s (local.get $gz)) (call $g (i32.const 6))))
    (local.set $n3 (call $fbm (local.get $fx) (local.get $fz) (i32.const 2) (i32.const 0xA1B2C3)))
    (local.set $h (f64.add (call $g (i32.const 0))
      (f64.add (f64.mul (f64.sub (local.get $n1) (f64.const 0.5)) (call $g (i32.const 1)))
        (f64.add (f64.mul (f64.sub (local.get $n2) (f64.const 0.5)) (call $g (i32.const 2)))
                 (f64.mul (f64.sub (local.get $n3) (f64.const 0.5)) (call $g (i32.const 3)))))))
    (if (f64.lt (local.get $h) (call $g (i32.const 7))) (then (local.set $h (call $g (i32.const 7)))))
    (if (f64.gt (local.get $h) (call $g (i32.const 8))) (then (local.set $h (call $g (i32.const 8)))))
    (i32.trunc_f64_s (local.get $h)))

  ;; ---- measurement primitives (DEEP TIME Phase 1b) -------------------------
  ;; $heightAt is the RAW generator height — before v3's relief bias is applied —
  ;; as a pure function of ($SEED, the GEO table, gx, gz). Exporting it means a
  ;; probe can sample the height field directly instead of generating a chunk per
  ;; 256 columns. That is what makes a GLOBAL quantile of the field affordable:
  ;; H_RAW_P95 anchors every province's package top, and a chunk-based sample of
  ;; it is both ~10^4x more expensive and spatially correlated with GEO's own
  ;; ~180-block harmonics (the first revision of the census measured it inside one
  ;; 161-block box, i.e. less than one wavelength, and read 3 levels high — see
  ;; __dbg.heightField and OPTIMIZATION_RESEARCH §70).
  ;; Both are ADDITIVE: no existing function body or export changes, so the v1/v2
  ;; byte-level freeze gate is unaffected.
  (func (export "setSeed") (param $s i32)
    (global.set $SEED (local.get $s)))
  (func (export "heightAt") (param $gx i32) (param $gz i32) (result i32)
    (call $heightAt (local.get $gx) (local.get $gz)))

  ;; v4 measurement primitives (additive; no existing function changes).
  ;; `denH0` is the density field's mean surface WITHOUT the province term, and
  ;; `denOvh100` is the 3-D half-amplitude in hundredths of a block. Together they
  ;; are how the host measures the v4 height distribution the way it measures v1's
  ;; — by sampling the FIELD, not by reading a chunk's heightmap (which is the
  ;; canopy). __dbg.census is the authority; these are what feed it.
  (func (export "denH0") (param $gx i32) (param $gz i32) (result i32)
    (i32.trunc_f64_s (f64.floor (f64.add
      (call $spline (i32.const 0) (call $contAt (local.get $gx) (local.get $gz)))
      (f64.mul (call $spline (i32.const 1) (call $pvAt (local.get $gx) (local.get $gz))) (call $g (i32.const 30)))))))
  (func (export "denOvh100") (param $gx i32) (param $gz i32) (result i32)
    (i32.trunc_f64_s (f64.mul
      (f64.mul (call $spline (i32.const 2) (call $eroAt (local.get $gx) (local.get $gz))) (call $g (i32.const 31)))
      (f64.const 100.0))))
  ;; The noise itself, exported so the host can measure its AMPLITUDE AND ITS
  ;; VERTICAL SLOPE instead of arguing about them from the literature. The fold
  ;; condition for a column is `ovh * |dn/dy| > 1` — the density gradient
  ;; -1 + ovh*dn/dy turns positive — so the amount of three-dimensional terrain is
  ;; a one-line consequence of the slope distribution, and the slope distribution
  ;; is a property of the noise, not of the design. Additive: nothing else changes.
  (func (export "noise3") (param $x f64) (param $y f64) (param $z f64) (result f64)
    (call $noise3 (local.get $x) (local.get $y) (local.get $z) (i32.const 0x3DDE5E)))
  (func (export "spline") (param $pid i32) (param $v f64) (result f64)
    (call $spline (local.get $pid) (local.get $v)))

  (func $moistAt (param $gx i32) (param $gz i32) (result f64)
    (call $fbm (f64.add (f64.mul (f64.convert_i32_s (local.get $gx)) (call $g (i32.const 17))) (call $g (i32.const 18)))
               (f64.add (f64.mul (f64.convert_i32_s (local.get $gz)) (call $g (i32.const 17))) (call $g (i32.const 19)))
               (i32.const 3) (i32.const 0x51AB7F)))

  ;; SHORE FOLD-DAMP helper: C1 ramp 0 at/below waterMaxY ($g16) to 1 at +8.
  ;; Per-column pure function of h0: continuous across columns (no seams),
  ;; chunk-independent, deterministic. Used by $genChunkV6 only.
  (func $shoreDamp (param $h0 f64) (result f64)
    (local $t f64)
    (local.set $t (f64.div (f64.sub (local.get $h0) (call $g (i32.const 16))) (f64.const 8.0)))
    (if (f64.lt (local.get $t) (f64.const 0.0)) (then (local.set $t (f64.const 0.0))))
    (if (f64.gt (local.get $t) (f64.const 1.0)) (then (local.set $t (f64.const 1.0))))
    (f64.mul (f64.mul (local.get $t) (local.get $t)) (f64.sub (f64.const 3.0) (f64.mul (f64.const 2.0) (local.get $t)))))


  (func $absI (param $x i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $x) (i32.const 0))
      (then (i32.sub (i32.const 0) (local.get $x)))
      (else (local.get $x))))
  (func $genChunkV1
    (param $cx i32) (param $cz i32) (param $seed i32) (param $block i32) (param $height i32)
    (local $lx i32) (local $lz i32) (local $gx i32) (local $gz i32)
    (local $h i32) (local $moist f64) (local $surf i32) (local $sub i32) (local $ly i32)
    (local $bi i32) (local $cave1 f64) (local $cave2 f64)
    (local $r f64) (local $trunkH i32) (local $top i32) (local $dy i32) (local $dx i32) (local $dz i32)
    (local $lcx i32) (local $lcz i32) (local $tidx i32)
    ;; LICM: the geometry and the two cave thresholds are constant for the whole
    ;; chunk, so read them once here instead of per-voxel. 21 384 cells x 2-3
    ;; global.get + $g (f64.load through a call) was 0.71 ms/chunk (2.6x) of pure
    ;; indirection — measured, see src/DEEP_TIME.md Phase 0.
    (local $aw i32) (local $asl i32) (local $wh i32) (local $wt i32)
    (local $ca f64) (local $cb f64)
    (local.set $aw (global.get $AW))
    (local.set $asl (global.get $ASL))
    (local.set $wh (global.get $WH))
    (local.set $wt (i32.trunc_f64_s (call $g (i32.const 16))))
    (local.set $ca (call $g (i32.const 20)))
    (local.set $cb (call $g (i32.const 21)))
    (global.set $SEED (local.get $seed))
    (local.set $lz (i32.const 0))
    (block $lzEnd
      (loop $lzLoop
        (br_if $lzEnd (i32.ge_s (local.get $lz) (local.get $aw)))
        (local.set $gz (i32.sub (i32.add (i32.mul (local.get $cz) (i32.const 16)) (local.get $lz)) (i32.const 1)))
        (local.set $lx (i32.const 0))
        (block $lxEnd
          (loop $lxLoop
            (br_if $lxEnd (i32.ge_s (local.get $lx) (local.get $aw)))
            (local.set $gx (i32.sub (i32.add (i32.mul (local.get $cx) (i32.const 16)) (local.get $lx)) (i32.const 1)))
            (local.set $h (call $heightAt (local.get $gx) (local.get $gz)))
            (local.set $moist (call $moistAt (local.get $gx) (local.get $gz)))
            (local.set $surf (i32.const 1))
            (if (i32.le_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 11)))) (then (local.set $surf (i32.const 4))))
            (if (i32.gt_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 10)))) (then (local.set $surf (i32.const 8))))
            (if (i32.and (i32.and (i32.gt_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 13))))
                                 (i32.le_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 14)))))
                          (f64.gt (local.get $moist) (call $g (i32.const 15))))
              (then (local.set $surf (i32.const 1))))
            (if (i32.and (i32.and (i32.gt_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 13))))
                                 (i32.le_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 14)))))
                          (f64.le (local.get $moist) (call $g (i32.const 15))))
              (then (local.set $surf (i32.const 2))))
            (local.set $sub (i32.const 2))
            (if (i32.lt_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 12)))) (then (local.set $sub (i32.const 4))))
            (local.set $ly (i32.const 0))
            (block $yEnd
              (loop $yLoop
                (br_if $yEnd (i32.ge_s (local.get $ly) (i32.add (local.get $wh) (i32.const 2))))
                (local.set $bi (i32.add (local.get $lx)
                  (i32.add (i32.mul (local.get $ly) (local.get $aw)) (i32.mul (local.get $lz) (local.get $asl)))))
                (if (i32.eq (local.get $ly) (i32.const 0))
                  (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 3))))
                (if (i32.gt_s (local.get $ly) (local.get $h))
                  (then
                    (if (i32.and (i32.le_s (local.get $ly) (local.get $wt)) (i32.lt_s (local.get $h) (local.get $wt)))
                      (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 5)))
                      (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 0))))))
                (if (i32.and (i32.le_s (local.get $ly) (local.get $h)) (i32.gt_s (local.get $ly) (i32.const 0)))
                  (then
                    (if (i32.lt_s (local.get $ly) (i32.sub (local.get $h) (i32.const 3)))
                      (then
                        (local.set $cave1 (call $noise2
                          (f64.add (f64.mul (f64.convert_i32_s (local.get $gx)) (f64.const 0.031))
                                   (f64.mul (f64.convert_i32_s (local.get $ly)) (f64.const 0.17)))
                          (f64.mul (f64.convert_i32_s (local.get $gz)) (f64.const 0.031))
                          (i32.const 0xCAF3BEEF)))
                        (local.set $cave2 (call $noise2
                          (f64.sub (f64.mul (f64.convert_i32_s (local.get $gx)) (f64.const 0.09))
                                   (f64.mul (f64.convert_i32_s (local.get $ly)) (f64.const 0.23)))
                          (f64.sub (f64.mul (f64.convert_i32_s (local.get $gz)) (f64.const 0.09)) (f64.const 3.1))
                          (i32.const 0xBEEFCAFE)))
                        (if (i32.or (f64.gt (local.get $cave1) (call $g (i32.const 20))) (f64.gt (local.get $cave2) (call $g (i32.const 21))))
                          (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 0)))
                          (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 3)))))
                      (else
                        (if (i32.lt_s (local.get $ly) (i32.sub (local.get $h) (i32.const 1)))
                          (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $sub)))
                          (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $surf))))))))
                (local.set $ly (i32.add (local.get $ly) (i32.const 1)))
                (br $yLoop)))
            (if (i32.and (i32.and (i32.and (i32.ge_s (local.get $lx) (i32.const 1)) (i32.le_s (local.get $lx) (i32.const 16))) (i32.ge_s (local.get $lz) (i32.const 1))) (i32.le_s (local.get $lz) (i32.const 16)))
              (then
                (i32.store16 (i32.add (local.get $height)
                  (i32.shl (i32.add (i32.sub (local.get $lx) (i32.const 1))
                                    (i32.mul (i32.sub (local.get $lz) (i32.const 1)) (i32.const 16)))
                           (i32.const 1)))
                  (local.get $h))))
            (local.set $lx (i32.add (local.get $lx) (i32.const 1)))
            (br $lxLoop)))
        (local.set $lz (i32.add (local.get $lz) (i32.const 1)))
        (br $lzLoop))))

  ;; ---- generator dispatch (the version gate) -------------------------------
  ;; v1 is frozen; v2 is DEEP TIME; v3 adds the province relief bias inside the v2
  ;; body (gated on $RELBIAS, so v2's output is unchanged). selector =
  ;; setWorldgen($WGV), set by the JS World constructor from the save's worldgen
  ;; field before any chunk is gen'd.
  (func $genChunk (export "genChunk")
    (param $cx i32) (param $cz i32) (param $seed i32) (param $block i32) (param $height i32)
    (if (i32.eq (global.get $WGV) (i32.const 1))
      (then
        (call $genChunkV1 (local.get $cx) (local.get $cz) (local.get $seed) (local.get $block) (local.get $height))
        (return)))
    (if (i32.ge_s (global.get $WGV) (i32.const 6))
      (then
        (call $genChunkV6 (local.get $cx) (local.get $cz) (local.get $seed) (local.get $block) (local.get $height))
        (return)))
    (if (i32.ge_s (global.get $WGV) (i32.const 4))
      (then
        (call $genChunkV4 (local.get $cx) (local.get $cz) (local.get $seed) (local.get $block) (local.get $height))
        (return)))
    (call $genChunkV2 (local.get $cx) (local.get $cz) (local.get $seed) (local.get $block) (local.get $height)))

  ;; ==========================================================================
  ;; v2 — DEEP TIME (Phase 1b). The surface, the climate, the water table, the
  ;; caves and the heightmap are EXACTLY v1's: Phase 1b is about what is *under*
  ;; the surface, so the shape of the world is deliberately unchanged and the new
  ;; thing (the rock under the cover) is measurable in isolation. What changes is
  ;; that the ~4 blocks of regolith now sit on a real stratigraphic column
  ;; instead of on undifferentiated stone.
  ;;
  ;; Three JS-written tables in page 0 (below the arena at 0x10000):
  ;;   COL_BASE  0x4000  u8[6][WH+2]  province -> rock id by ABSOLUTE y
  ;;   PROV_BASE 0x5000  u8[18*18]    province index per column of THIS chunk
  ;;   PH_BASE   0x5800  f64[6*4]     per-province scalars [bare, rel, bias, rsv]
  ;;                                  rel = v3's relief gain, bias = its elevation
  ;;                                  offset; v1/v2 ignore both.
  ;;
  ;; The column table is the load-bearing idea. It is a pure function of
  ;; (province, y, seed) — NOT of the column — so beds are HORIZONTAL and run
  ;; unbroken across an entire province, and the terrain surface h simply CUTS
  ;; into the package. That is why high ground exposes deeper (older) rock and a
  ;; basin never leaves its sedimentary fill: the erosion profile reads the
  ;; stratigraphy. It also means the kernel needs no per-column bed state at all
  ;; — one `i32.load8_u` per voxel. Wikipedia *Bed (geology)*: a bed is a
  ;; coherent layer >= 1 cm; at one block per metre a bed is a run of voxels, and
  ;; lateral continuity is what makes a cliff face readable as strata.
  ;; ==========================================================================
  (func $colRock (param $p i32) (param $y i32) (result i32)
    (i32.load8_u (i32.add (i32.const 0x4000)
      (i32.add (i32.mul (local.get $p) (global.get $COLSL)) (local.get $y)))))

  (func $colProv (param $i i32) (result i32)
    (i32.load8_u (i32.add (i32.const 0x5000) (local.get $i))))

  (func $phv (param $p i32) (param $k i32) (result f64)
    (f64.load (i32.add (i32.const 0x5800)
      (i32.mul (i32.add (i32.mul (local.get $p) (i32.const 4)) (local.get $k)) (i32.const 8)))))

  ;; v3 — THE PROVINCE RELIEF BIAS. GEOLOGY.md 4.2 promises that a province biases
  ;; the terrain splines, "which is what keeps the rocks and the shape agreeing".
  ;; Measurement said it was never wired: every province had the identical height
  ;; distribution (p50 = 32, p95 = 46, ~20 % flooded), so a "basin" sat as high as
  ;; an "orogen" and — because the column is indexed by ABSOLUTE y — the top of
  ;; every province's column lay ABOVE the ground and could never be generated at
  ;; all. An affine map of the deviation from the GEO datum fixes both at once:
  ;;   h = hBase + bias[p] + (hRaw - hBase) * rel[p]
  ;; `rel` is the relief multiplier (a basin is flat) and `bias` the mean
  ;; elevation (a basin is low, an orogen high). Affine, so it commutes with the
  ;; clamp: h stays in [hMin, hMax] and the column table is indexed safely.
  (func $relief (param $hy i32) (param $p i32) (result i32)
    (local $h f64) (local $hb f64)
    (local.set $hb (call $g (i32.const 0)))
    (local.set $h (f64.add
      (f64.add (local.get $hb) (call $phv (local.get $p) (i32.const 2)))
      (f64.mul (f64.sub (f64.convert_i32_s (local.get $hy)) (local.get $hb))
               (call $phv (local.get $p) (i32.const 1)))))
    (if (f64.lt (local.get $h) (call $g (i32.const 7))) (then (local.set $h (call $g (i32.const 7)))))
    (if (f64.gt (local.get $h) (call $g (i32.const 8))) (then (local.set $h (call $g (i32.const 8)))))
    (i32.trunc_f64_s (local.get $h)))

  (func $genChunkV2
    (param $cx i32) (param $cz i32) (param $seed i32) (param $block i32) (param $height i32)
    (local $lx i32) (local $lz i32) (local $gx i32) (local $gz i32)
    (local $h i32) (local $moist f64) (local $surf i32) (local $sub i32) (local $ly i32)
    (local $bi i32) (local $cave1 f64) (local $cave2 f64)
    (local $aw i32) (local $asl i32) (local $wh i32) (local $wt i32)
    (local $ca f64) (local $cb f64)
    (local $p i32) (local $veneer i32) (local $rock i32)
    (local $colp i32) (local $csl i32) (local $yN i32)
    (local.set $aw (global.get $AW))
    (local.set $asl (global.get $ASL))
    (local.set $wh (global.get $WH))
    (local.set $wt (i32.trunc_f64_s (call $g (i32.const 16))))
    (local.set $ca (call $g (i32.const 20)))
    (local.set $cb (call $g (i32.const 21)))
    (local.set $csl (global.get $COLSL))
    (local.set $yN (i32.add (local.get $wh) (i32.const 2)))
    (global.set $SEED (local.get $seed))
    (local.set $lz (i32.const 0))
    (block $lzEnd
      (loop $lzLoop
        (br_if $lzEnd (i32.ge_s (local.get $lz) (local.get $aw)))
        (local.set $gz (i32.sub (i32.add (i32.mul (local.get $cz) (i32.const 16)) (local.get $lz)) (i32.const 1)))
        (local.set $lx (i32.const 0))
        (block $lxEnd
          (loop $lxLoop
            (br_if $lxEnd (i32.ge_s (local.get $lx) (local.get $aw)))
            (local.set $gx (i32.sub (i32.add (i32.mul (local.get $cx) (i32.const 16)) (local.get $lx)) (i32.const 1)))
            (local.set $h (call $heightAt (local.get $gx) (local.get $gz)))
            ;; v3: the province's relief bias (see $relief). $RELBIAS is 0 for a
            ;; v1/v2 world, so this is a branch that is never taken there and their
            ;; output is untouched. The province is re-read here (one load) rather
            ;; than hoisting the later column's `$p`, which keeps the v1/v2
            ;; instruction stream unchanged except for this never-taken block.
            (if (global.get $RELBIAS)
              (then (local.set $h (call $relief (local.get $h)
                      (i32.and (call $colProv (i32.add (local.get $lx) (i32.mul (local.get $lz) (local.get $aw))))
                               (i32.const 7))))))
            (local.set $moist (call $moistAt (local.get $gx) (local.get $gz)))
            ;; ---- surface material: v1's rule, verbatim ---------------------
            (local.set $surf (i32.const 1))
            (if (i32.le_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 11)))) (then (local.set $surf (i32.const 4))))
            (if (i32.gt_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 10)))) (then (local.set $surf (i32.const 8))))
            (if (i32.and (i32.and (i32.gt_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 13))))
                                 (i32.le_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 14)))))
                          (f64.gt (local.get $moist) (call $g (i32.const 15))))
              (then (local.set $surf (i32.const 1))))
            (if (i32.and (i32.and (i32.gt_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 13))))
                                 (i32.le_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 14)))))
                          (f64.le (local.get $moist) (call $g (i32.const 15))))
              (then (local.set $surf (i32.const 2))))
            (local.set $sub (i32.const 2))
            (if (i32.lt_s (local.get $h) (i32.trunc_f64_s (call $g (i32.const 12)))) (then (local.set $sub (i32.const 4))))
            ;; ---- province, and the exposed-basement decision ---------------
            ;; A Shield and an Orogen are old, uplifted and bare: wherever the
            ;; column is not regolith-covered the actual rock is what you stand
            ;; on. This is the "$4.10 exposed basement" of GEOLOGY.md, and it is
            ;; what makes a shield read as a shield from a distance.
            (local.set $p (i32.and (call $colProv (i32.add (local.get $lx) (i32.mul (local.get $lz) (local.get $aw)))) (i32.const 7)))
            ;; LICM: the column's byte offset is constant for all 66 levels of
            ;; this column, so fold it once here — the per-voxel rock read is then
            ;; one add + one load8_u and nothing else.
            (local.set $colp (i32.add (i32.const 0x4000) (i32.mul (local.get $p) (local.get $csl))))
            (local.set $veneer (i32.const 4))
            (if (f64.lt (call $rand01 (call $hash2 (local.get $gx) (local.get $gz) (i32.const 0x42415245)))
                        (call $phv (local.get $p) (i32.const 0)))
              (then (local.set $veneer (i32.const 0))))
            ;; LICM: the arena index advances by exactly $aw per level, so the
            ;; two multiplies the old form did per voxel (21 384 x) become one add.
            (local.set $bi (i32.add (i32.mul (local.get $lz) (local.get $asl)) (local.get $lx)))
            (local.set $ly (i32.const 0))
            (block $yEnd
              (loop $yLoop
                (br_if $yEnd (i32.ge_s (local.get $ly) (local.get $yN)))
                (if (i32.eq (local.get $ly) (i32.const 0))
                  (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 3))))
                (if (i32.gt_s (local.get $ly) (local.get $h))
                  (then
                    (if (i32.and (i32.le_s (local.get $ly) (local.get $wt)) (i32.lt_s (local.get $h) (local.get $wt)))
                      (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 5)))
                      (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 0))))))
                (if (i32.and (i32.le_s (local.get $ly) (local.get $h)) (i32.gt_s (local.get $ly) (i32.const 0)))
                  (then
                    (if (i32.gt_s (local.get $ly) (i32.sub (local.get $h) (local.get $veneer)))
                      ;; ---- regolith: v1's exact 2 surf + 2 sub veneer --------
                      (then
                        (if (i32.gt_s (local.get $ly) (i32.sub (local.get $h) (i32.const 2)))
                          (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $surf)))
                          (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $sub)))))
                      ;; ---- bedrock: the stratigraphic column -----------------
                      (else
                        (local.set $rock (i32.load8_u (i32.add (local.get $colp) (local.get $ly))))
                        ;; Caves gate on `ly < h - 3` — the SAME absolute gate v1
                        ;; used. It is vacuous for a regolith column (whose rock
                        ;; region already starts at h-4) and it is what stops a
                        ;; bare column from having its own ground surface carved
                        ;; into a hole.
                        (if (i32.lt_s (local.get $ly) (i32.sub (local.get $h) (i32.const 3)))
                          (then
                            (local.set $cave1 (call $noise2
                              (f64.add (f64.mul (f64.convert_i32_s (local.get $gx)) (f64.const 0.031))
                                       (f64.mul (f64.convert_i32_s (local.get $ly)) (f64.const 0.17)))
                              (f64.mul (f64.convert_i32_s (local.get $gz)) (f64.const 0.031))
                              (i32.const 0xCAF3BEEF)))
                            (local.set $cave2 (call $noise2
                              (f64.sub (f64.mul (f64.convert_i32_s (local.get $gx)) (f64.const 0.09))
                                       (f64.mul (f64.convert_i32_s (local.get $ly)) (f64.const 0.23)))
                              (f64.sub (f64.mul (f64.convert_i32_s (local.get $gz)) (f64.const 0.09)) (f64.const 3.1))
                              (i32.const 0xBEEFCAFE)))
                            (if (i32.or (f64.gt (local.get $cave1) (local.get $ca)) (f64.gt (local.get $cave2) (local.get $cb)))
                              (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 0)))
                              (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $rock)))))
                          (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $rock))))))))
                (local.set $bi (i32.add (local.get $bi) (local.get $aw)))
                (local.set $ly (i32.add (local.get $ly) (i32.const 1)))
                (br $yLoop)))
            (if (i32.and (i32.and (i32.and (i32.ge_s (local.get $lx) (i32.const 1)) (i32.le_s (local.get $lx) (i32.const 16))) (i32.ge_s (local.get $lz) (i32.const 1))) (i32.le_s (local.get $lz) (i32.const 16)))
              (then
                (i32.store16 (i32.add (local.get $height)
                  (i32.shl (i32.add (i32.sub (local.get $lx) (i32.const 1))
                                    (i32.mul (i32.sub (local.get $lz) (i32.const 1)) (i32.const 16)))
                           (i32.const 1)))
                  (local.get $h))))
            (local.set $lx (i32.add (local.get $lx) (i32.const 1)))
            (br $lxLoop)))
        (local.set $lz (i32.add (local.get $lz) (i32.const 1)))
        (br $lzLoop))))


  ;; ==========================================================================
  ;; v4 — TERRAIN IN THREE DIMENSIONS (DEEP TIME Phase 2; GEOLOGY.md 4.4)
  ;;
  ;; v1-v3 pick a SURFACE HEIGHT per column and fill down from it. That is a
  ;; heightmap, and a heightmap cannot make an overhang, an arch, a mesa with a
  ;; wider cap than its base, or a floating island — not because the code is
  ;; simple, but because "one solid run per column" IS the definition. v4
  ;; replaces the height with a DENSITY FIELD, which is what Minecraft did in
  ;; 1.18 (minecraft.wiki *Density function*: "Density functions make up
  ;; mathematical expressions to obtain a number from a position"):
  ;;
  ;;     D(x,y,z) = (h0(x,z) - y) + n3(x,y,z) * ovh(x,z)
  ;;     SOLID  <=>  D > 0
  ;;
  ;; h0 is the mean surface — a spline of continentalness plus a peaks/valleys
  ;; term plus the province's elevation — and ovh is the vertical half-amplitude
  ;; of the 3-D noise, a spline of erosion times the province's overhang gain.
  ;;
  ;; WHY THERE IS NO SEPARATE "VERTICAL STRETCH" PARAMETER. GEOLOGY.md 4.4 writes
  ;; the field as  D = n3d + offset - (y - base) * bias;  at a fixed column that
  ;; has three quantities, but the sign of D is unchanged by a positive
  ;; rescaling, so only two of them are independent:
  ;;     h0 = base + offset/bias   and   ovh = 1/bias.
  ;; A third knob would be a knob with no effect. What 4.4 calls the vertical
  ;; stretch factor is 1/ovh here, and that is the number that decides whether an
  ;; overhang can exist:
  ;;
  ;;   SOLID is a single interval iff D is monotone in y, i.e. iff
  ;;         1 - ovh * dn3/dy > 0 everywhere, and it is MULTI-INTERVAL — an
  ;;   overhang, an arch, a floating island — as soon as ovh*max|dn3/dy| > 1.
  ;;   One octave of Perlin noise has max slope ~ 1.5 * (its vertical frequency)
  ;;   (Perlin 1985/2002; the 12 edge gradients bound |dn3/dy| at ~1.5 f), so an
  ;;   overhang needs   ovh > 1 / (1.5 * n3y).  With n3y = 0.085 that is
  ;;   ovh > 7.8 blocks. ovh is a spline of EROSION, so plains and basins
  ;;   (ovh 0.5..2) stay single-interval and smooth, and an orogen or a coast
  ;;   (ovh 8..16) is where the world folds over itself. That is the whole
  ;;   mechanism, and it is why the overhang gate in __dbg counts columns with
  ;;   rock above air instead of looking at a picture.
  ;;
  ;; Everything else is v2's: the stratigraphic column still supplies the rock by
  ;; ABSOLUTE y, the regolith is still the top `veneer` solid blocks, and the two
  ;; cave fields remove levels below the local top (v6 replaces those with the
  ;; per-column model in $caveNet). The one thing that changes for
  ;; the rest of the game is that the heightmap is now the TOPMOST SOLID level
  ;; rather than a field value — which is what a heightmap always meant.
  ;;
  ;; Tables written by JS (page 0, alongside COL/PROV/PH):
  ;;   PH2_BASE 0x5940  f64[6][2]  per-province [elevation offset, overhang mul]
  ;;   SPL_BASE 0x6000  u32[8]     control-point count per spline
  ;;   SPL_PTS  0x6100  f64[8][24][3]  (x, y, tangent) per point; the tangents are
  ;;                    the Fritsch-Carlson (1980) monotone ones, computed in JS.
  ;;   CAV_TAB  0x5B00  f64[8][9]  per-NETWORK cave parameters (v6): band half-width,
  ;;                    frequency, ceiling, floor, storey fraction, joint anisotropy,
  ;;                    passage azimuth as cos/sin, and storey drift amplitude. Row
  ;;                    layout and the argument for every field: $caveNet.
  ;;   CAV_IV   0x5D80  i32[8]     kernel-private: the current column's three cave
  ;;                    intervals ([2k] = lo, [2k+1] = hi) and the pillar flag at
  ;;                    [6]. Rewritten for every column by $caveCols and read six
  ;;                    levels deep by the pass-2 loop.
  ;;   DBAND    0x5A00  u8[96]     kernel-private: one solid/air flag per level of
  ;;                    the CURRENT column's density band (see the band clamp in
  ;;                    $genChunkV4). Sized for the tallest world's widest band,
  ;;                    not for WH = 64's — the comment there carries the argument.
  ;; ==========================================================================

  (func $hash3 (param $ix i32) (param $iy i32) (param $iz i32) (param $salt i32) (result i32)
    (local $h i32)
    (local.set $h (i32.xor (global.get $SEED)
      (i32.xor (i32.xor (i32.mul (local.get $ix) (i32.const 0x9E3779B9))
                        (i32.mul (local.get $iy) (i32.const 0x85EBCA6B)))
               (i32.mul (local.get $iz) (i32.const 0xC2B2AE35)))))
    (local.set $h (i32.xor (local.get $h) (local.get $salt)))
    (call $mix (local.get $h)))

  ;; Ken Perlin's improved-noise gradient: the 12 edge vectors of a cube picked by
  ;; 4 hash bits and evaluated as a dot product, with no table and no per-axis
  ;; branch ("Improving Noise", SIGGRAPH 2002, the grad() function).
  (func $grad3 (param $h i32) (param $x f64) (param $y f64) (param $z f64) (result f64)
    (local $hb i32) (local $u f64) (local $v f64)
    (local.set $hb (i32.and (local.get $h) (i32.const 15)))
    (local.set $u (if (result f64) (i32.lt_s (local.get $hb) (i32.const 8))
      (then (local.get $x)) (else (local.get $y))))
    (local.set $v (if (result f64) (i32.lt_s (local.get $hb) (i32.const 4))
      (then (local.get $y))
      (else (if (result f64)
              (i32.or (i32.eq (local.get $hb) (i32.const 12)) (i32.eq (local.get $hb) (i32.const 14)))
              (then (local.get $x)) (else (local.get $z))))))
    (f64.add
      (if (result f64) (i32.ne (i32.and (local.get $hb) (i32.const 1)) (i32.const 0))
        (then (f64.neg (local.get $u))) (else (local.get $u)))
      (if (result f64) (i32.ne (i32.and (local.get $hb) (i32.const 2)) (i32.const 0))
        (then (f64.neg (local.get $v))) (else (local.get $v)))))

  ;; Perlin's improved fade  6t^5 - 15t^4 + 10t^3 : C2, and zero slope at both
  ;; lattice ends. The old smoothstep 3t^2-2t^3 is only C1, and a density field
  ;; shows its lattice as rows of parallel terracing wherever the second
  ;; derivative jumps — which is exactly at every integer y in a 64-tall world.
  (func $fade (param $t f64) (result f64)
    (local $t2 f64) (local $t3 f64)
    (local.set $t2 (f64.mul (local.get $t) (local.get $t)))
    (local.set $t3 (f64.mul (local.get $t2) (local.get $t)))
    (f64.mul (local.get $t3)
      (f64.add (f64.add (f64.mul (f64.const 6.0) (local.get $t2))
                        (f64.mul (f64.const -15.0) (local.get $t)))
               (f64.const 10.0))))

  ;; 3-D gradient (Perlin) noise, one octave. Range is about [-0.87, 0.87]: the
  ;; 12 edge gradients have length sqrt(2) and the theoretical bound of the
  ;; trilinear blend is sqrt(3)/2. 8 hashes and 8 dot products, no array.
  (func $noise3 (param $x f64) (param $y f64) (param $z f64) (param $salt i32) (result f64)
    (local $ix i32) (local $iy i32) (local $iz i32)
    (local $fx f64) (local $fy f64) (local $fz f64)
    (local $gx f64) (local $gy f64) (local $gz f64)
    (local $ux f64) (local $uy f64) (local $uz f64)
    (local $n000 f64) (local $n100 f64) (local $n010 f64) (local $n110 f64)
    (local $n001 f64) (local $n101 f64) (local $n011 f64) (local $n111 f64)
    (local $x1 f64) (local $x2 f64) (local $y1 f64) (local $y2 f64)
    (local.set $ix (i32.trunc_f64_s (f64.floor (local.get $x))))
    (local.set $iy (i32.trunc_f64_s (f64.floor (local.get $y))))
    (local.set $iz (i32.trunc_f64_s (f64.floor (local.get $z))))
    (local.set $fx (f64.sub (local.get $x) (f64.convert_i32_s (local.get $ix))))
    (local.set $fy (f64.sub (local.get $y) (f64.convert_i32_s (local.get $iy))))
    (local.set $fz (f64.sub (local.get $z) (f64.convert_i32_s (local.get $iz))))
    (local.set $gx (f64.sub (local.get $fx) (f64.const 1.0)))
    (local.set $gy (f64.sub (local.get $fy) (f64.const 1.0)))
    (local.set $gz (f64.sub (local.get $fz) (f64.const 1.0)))
    (local.set $ux (call $fade (local.get $fx)))
    (local.set $uy (call $fade (local.get $fy)))
    (local.set $uz (call $fade (local.get $fz)))
    (local.set $n000 (call $grad3 (call $hash3 (local.get $ix) (local.get $iy) (local.get $iz) (local.get $salt))
                                  (local.get $fx) (local.get $fy) (local.get $fz)))
    (local.set $n100 (call $grad3 (call $hash3 (i32.add (local.get $ix) (i32.const 1)) (local.get $iy) (local.get $iz) (local.get $salt))
                                  (local.get $gx) (local.get $fy) (local.get $fz)))
    (local.set $n010 (call $grad3 (call $hash3 (local.get $ix) (i32.add (local.get $iy) (i32.const 1)) (local.get $iz) (local.get $salt))
                                  (local.get $fx) (local.get $gy) (local.get $fz)))
    (local.set $n110 (call $grad3 (call $hash3 (i32.add (local.get $ix) (i32.const 1)) (i32.add (local.get $iy) (i32.const 1)) (local.get $iz) (local.get $salt))
                                  (local.get $gx) (local.get $gy) (local.get $fz)))
    (local.set $n001 (call $grad3 (call $hash3 (local.get $ix) (local.get $iy) (i32.add (local.get $iz) (i32.const 1)) (local.get $salt))
                                  (local.get $fx) (local.get $fy) (local.get $gz)))
    (local.set $n101 (call $grad3 (call $hash3 (i32.add (local.get $ix) (i32.const 1)) (local.get $iy) (i32.add (local.get $iz) (i32.const 1)) (local.get $salt))
                                  (local.get $gx) (local.get $fy) (local.get $gz)))
    (local.set $n011 (call $grad3 (call $hash3 (local.get $ix) (i32.add (local.get $iy) (i32.const 1)) (i32.add (local.get $iz) (i32.const 1)) (local.get $salt))
                                  (local.get $fx) (local.get $gy) (local.get $gz)))
    (local.set $n111 (call $grad3 (call $hash3 (i32.add (local.get $ix) (i32.const 1)) (i32.add (local.get $iy) (i32.const 1)) (i32.add (local.get $iz) (i32.const 1)) (local.get $salt))
                                  (local.get $gx) (local.get $gy) (local.get $gz)))
    (local.set $x1 (f64.add (local.get $n000) (f64.mul (local.get $ux) (f64.sub (local.get $n100) (local.get $n000)))))
    (local.set $x2 (f64.add (local.get $n010) (f64.mul (local.get $ux) (f64.sub (local.get $n110) (local.get $n010)))))
    (local.set $y1 (f64.add (local.get $x1) (f64.mul (local.get $uy) (f64.sub (local.get $x2) (local.get $x1)))))
    (local.set $x1 (f64.add (local.get $n001) (f64.mul (local.get $ux) (f64.sub (local.get $n101) (local.get $n001)))))
    (local.set $x2 (f64.add (local.get $n011) (f64.mul (local.get $ux) (f64.sub (local.get $n111) (local.get $n011)))))
    (local.set $y2 (f64.add (local.get $x1) (f64.mul (local.get $uy) (f64.sub (local.get $x2) (local.get $x1)))))
    (f64.add (local.get $y1) (f64.mul (local.get $uz) (f64.sub (local.get $y2) (local.get $y1)))))

  ;; One control-point spline, evaluated as a cubic HERMITE with the tangents the
  ;; JS host computed (Fritsch & Carlson 1980, "Monotone Piecewise Cubic
  ;; Interpolation", SIAM J. Numer. Anal. 17(2):238-246). Monotone matters here:
  ;; an ordinary cubic running through the control points can overshoot between
  ;; them, and an overshoot in the OFFSET spline is a mountain range that the
  ;; control points did not ask for. Points are (x, y, tangent) f64 triples at
  ;; SPL_PTS + pid*576; the count is a u32 at SPL_BASE + pid*4.
  (func $spline (param $pid i32) (param $v f64) (result f64)
    (local $n i32) (local $b i32) (local $k i32) (local $o0 i32)
    (local $x0 f64) (local $x1 f64) (local $y0 f64) (local $y1 f64)
    (local $m0 f64) (local $m1 f64) (local $d f64) (local $t f64)
    (local $t2 f64) (local $t3 f64) (local $h00 f64) (local $h10 f64)
    (local $h01 f64) (local $h11 f64)
    (local.set $n (i32.load (i32.add (i32.const 0x6000) (i32.shl (local.get $pid) (i32.const 2)))))
    (if (i32.lt_s (local.get $n) (i32.const 2)) (then (return (f64.const 0.0))))
    (local.set $b (i32.add (i32.const 0x6100) (i32.mul (local.get $pid) (i32.const 576))))
    (local.set $x0 (f64.load (local.get $b)))
    (if (f64.le (local.get $v) (local.get $x0))
      (then (return (f64.load (i32.add (local.get $b) (i32.const 8))))))
    (local.set $o0 (i32.add (local.get $b) (i32.mul (i32.sub (local.get $n) (i32.const 1)) (i32.const 24))))
    (local.set $x1 (f64.load (local.get $o0)))
    (if (f64.ge (local.get $v) (local.get $x1))
      (then (return (f64.load (i32.add (local.get $o0) (i32.const 8))))))
    (local.set $k (i32.const 0))
    (block $seg (loop $segL
      (local.set $x1 (f64.load (i32.add (local.get $b) (i32.mul (i32.add (local.get $k) (i32.const 1)) (i32.const 24)))))
      (br_if $seg (f64.lt (local.get $v) (local.get $x1)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br_if $seg (i32.ge_s (local.get $k) (i32.sub (local.get $n) (i32.const 1))))
      (br $segL)))
    (local.set $o0 (i32.add (local.get $b) (i32.mul (local.get $k) (i32.const 24))))
    (local.set $x0 (f64.load (local.get $o0)))
    (local.set $x1 (f64.load (i32.add (local.get $o0) (i32.const 24))))
    (local.set $y0 (f64.load (i32.add (local.get $o0) (i32.const 8))))
    (local.set $y1 (f64.load (i32.add (local.get $o0) (i32.const 32))))
    (local.set $m0 (f64.load (i32.add (local.get $o0) (i32.const 16))))
    (local.set $m1 (f64.load (i32.add (local.get $o0) (i32.const 40))))
    (local.set $d (f64.sub (local.get $x1) (local.get $x0)))
    (if (f64.le (local.get $d) (f64.const 0.0)) (then (return (local.get $y0))))
    (local.set $t (f64.div (f64.sub (local.get $v) (local.get $x0)) (local.get $d)))
    (local.set $t2 (f64.mul (local.get $t) (local.get $t)))
    (local.set $t3 (f64.mul (local.get $t2) (local.get $t)))
    (local.set $h00 (f64.add (f64.sub (f64.mul (f64.const 2.0) (local.get $t3)) (f64.mul (f64.const 3.0) (local.get $t2))) (f64.const 1.0)))
    (local.set $h10 (f64.add (f64.sub (local.get $t3) (f64.mul (f64.const 2.0) (local.get $t2))) (local.get $t)))
    (local.set $h01 (f64.add (f64.mul (f64.const -2.0) (local.get $t3)) (f64.mul (f64.const 3.0) (local.get $t2))))
    (local.set $h11 (f64.sub (local.get $t3) (local.get $t2)))
    (f64.add
      (f64.add (f64.mul (local.get $h00) (local.get $y0))
               (f64.mul (local.get $h10) (f64.mul (local.get $d) (local.get $m0))))
      (f64.add (f64.mul (local.get $h01) (local.get $y1))
               (f64.mul (local.get $h11) (f64.mul (local.get $d) (local.get $m1))))))

  (func $phv2 (param $p i32) (param $k i32) (result f64)
    (f64.load (i32.add (i32.const 0x5940)
      (i32.mul (i32.add (i32.mul (local.get $p) (i32.const 2)) (local.get $k)) (i32.const 8)))))

  ;; A 2-D climate/terrain field in [0,1]. Four octaves of value noise average to
  ;; a bell around 0.5, so the result is stretched about the mean before clamping:
  ;; without the stretch the spline control points at 0.1 and 0.9 would never be
  ;; reached and the world would use the middle of every curve it is given.
  (func $field2 (param $gx i32) (param $gz i32) (param $sc f64) (param $salt i32) (param $gain f64) (result f64)
    (local $n f64)
    (local.set $n (call $fbm (f64.mul (f64.convert_i32_s (local.get $gx)) (local.get $sc))
                             (f64.mul (f64.convert_i32_s (local.get $gz)) (local.get $sc))
                             (i32.const 4) (local.get $salt)))
    (local.set $n (f64.add (f64.mul (f64.sub (local.get $n) (f64.const 0.5)) (local.get $gain)) (f64.const 0.5)))
    (if (f64.lt (local.get $n) (f64.const 0.0)) (then (local.set $n (f64.const 0.0))))
    (if (f64.gt (local.get $n) (f64.const 1.0)) (then (local.set $n (f64.const 1.0))))
    (local.get $n))

  (func $contAt (param $gx i32) (param $gz i32) (result f64)
    (call $field2 (local.get $gx) (local.get $gz) (call $g (i32.const 32)) (i32.const 0xC07A17) (call $g (i32.const 35))))
  (func $eroAt (param $gx i32) (param $gz i32) (result f64)
    (call $field2 (local.get $gx) (local.get $gz) (call $g (i32.const 33)) (i32.const 0xE20A91) (call $g (i32.const 35))))
  (func $pvAt (param $gx i32) (param $gz i32) (result f64)
    (call $field2 (local.get $gx) (local.get $gz) (call $g (i32.const 34)) (i32.const 0x9B1D43) (call $g (i32.const 35))))

  (func $genChunkV4
    (param $cx i32) (param $cz i32) (param $seed i32) (param $block i32) (param $height i32)
    (local $lx i32) (local $lz i32) (local $gx i32) (local $gz i32)
    (local $ly i32) (local $bi i32)
    (local $aw i32) (local $asl i32) (local $wh i32) (local $yN i32) (local $wt i32)
    (local $ca f64) (local $cb f64)
    (local $cont f64) (local $ero f64) (local $pv f64)
    (local $h0 f64) (local $ovh f64) (local $d f64) (local $n3 f64)
    (local $yHi i32) (local $yLo i32)
    (local $top i32) (local $depth i32) (local $veneer i32) (local $h0i i32)
    (local $p i32) (local $colp i32) (local $csl i32) (local $rock i32)
    (local $surf i32) (local $sub i32) (local $moist f64)
    (local $cave1 f64) (local $cave2 f64)
    (local $n3xy f64) (local $n3y f64)
    (local.set $aw (global.get $AW))
    (local.set $asl (global.get $ASL))
    (local.set $wh (global.get $WH))
    (local.set $yN (i32.add (local.get $wh) (i32.const 2)))
    (local.set $wt (i32.trunc_f64_s (call $g (i32.const 16))))
    (local.set $ca (call $g (i32.const 20)))
    (local.set $cb (call $g (i32.const 21)))
    (local.set $csl (global.get $COLSL))
    (local.set $n3xy (call $g (i32.const 24)))
    (local.set $n3y (call $g (i32.const 25)))
    (global.set $SEED (local.get $seed))
    (local.set $lz (i32.const 0))
    (block $lzEnd
      (loop $lzLoop
        (br_if $lzEnd (i32.ge_s (local.get $lz) (local.get $aw)))
        (local.set $gz (i32.sub (i32.add (i32.mul (local.get $cz) (i32.const 16)) (local.get $lz)) (i32.const 1)))
        (local.set $lx (i32.const 0))
        (block $lxEnd
          (loop $lxLoop
            (br_if $lxEnd (i32.ge_s (local.get $lx) (local.get $aw)))
            (local.set $gx (i32.sub (i32.add (i32.mul (local.get $cx) (i32.const 16)) (local.get $lx)) (i32.const 1)))
            ;; ---- the column's two spline outputs -------------------------
            (local.set $p (i32.and (call $colProv (i32.add (local.get $lx) (i32.mul (local.get $lz) (local.get $aw)))) (i32.const 7)))
            (local.set $cont (call $contAt (local.get $gx) (local.get $gz)))
            (local.set $ero (call $eroAt (local.get $gx) (local.get $gz)))
            (local.set $pv (call $pvAt (local.get $gx) (local.get $gz)))
            (local.set $h0 (f64.add
              (f64.add (call $spline (i32.const 0) (local.get $cont))
                       (f64.mul (call $spline (i32.const 1) (local.get $pv)) (call $g (i32.const 30))))
              (call $phv2 (local.get $p) (i32.const 0))))
            (local.set $ovh (f64.mul
              (f64.mul (call $spline (i32.const 2) (local.get $ero)) (call $g (i32.const 31)))
              (call $phv2 (local.get $p) (i32.const 1))))
            (if (f64.lt (local.get $h0) (call $g (i32.const 26))) (then (local.set $h0 (call $g (i32.const 26)))))
            (if (f64.gt (local.get $h0) (call $g (i32.const 27))) (then (local.set $h0 (call $g (i32.const 27)))))
            (if (f64.lt (local.get $ovh) (call $g (i32.const 28))) (then (local.set $ovh (call $g (i32.const 28)))))
            (if (f64.gt (local.get $ovh) (call $g (i32.const 29))) (then (local.set $ovh (call $g (i32.const 29)))))
            ;; ---- the band that may contain the surface -------------------
            ;; D <= h0 - y + 0.87*ovh, so above yHi the sign is proven negative;
            ;; D >= h0 - y - 0.87*ovh, so below yLo it is proven positive. Only
            ;; the band between them needs the 3-D noise, and only the band's
            ;; TOPMOST solid level is the column's surface. This is the whole
            ;; reason a density field costs what a heightmap costs: the band is
            ;; ~1.74*ovh tall instead of the whole column.
            (local.set $yHi (i32.add (i32.trunc_f64_s (f64.floor (f64.add (local.get $h0) (f64.mul (local.get $ovh) (f64.const 0.8727))))) (i32.const 1)))
            (local.set $yLo (i32.sub (i32.trunc_f64_s (f64.floor (f64.sub (local.get $h0) (f64.mul (local.get $ovh) (f64.const 0.8727))))) (i32.const 1)))
            (if (i32.gt_s (local.get $yHi) (i32.sub (local.get $yN) (i32.const 1))) (then (local.set $yHi (i32.sub (local.get $yN) (i32.const 1)))))
            (if (i32.lt_s (local.get $yLo) (i32.const 1)) (then (local.set $yLo (i32.const 1))))
            (if (i32.lt_s (local.get $yHi) (local.get $yLo)) (then (local.set $yHi (local.get $yLo))))
            ;; DBAND holds one flag per band level, so the band must fit it. The
            ;; scratch is 96 bytes at 0x5A00 (leaving room up to 0x5A60) and the
            ;; clamp below is 95, i.e. ONE LESS than the capacity.
            ;;
            ;; The clamp is only CORRECT where every level it clips is already
            ;; proven solid, which is the case when h0 - 0.87*ovh falls below the
            ;; world floor. At WH = 64 that is the only case that can arise: ovh
            ;; is clamped to denHi = 22, so the band is at most
            ;; 1.7454*22 + 2 = 40 levels and the clamp NEVER fires (it is dead
            ;; code for worldgen 1-4, which is what keeps them frozen). A taller
            ;; world scales denHi with the vertical extent (worldgen 5:
            ;; denHi = 43.31), so the band can reach 1.7454*43.31 + 2 = 78 levels
            ;; and the clamp WOULD fire in deep orogens — and there it is NOT
            ;; free: yLo would be raised ~18 levels and a slab 18 deep around
            ;; h0 - 20 .. h0 - 38 would be marked solid from the flag array
            ;; instead of from the field, filling real cave voids with rock.
            ;; Hence the capacity went 61 -> 96 bytes (a scratch inside the
            ;; kernel's own region, read by no JS address) when worldgen 5 was
            ;; added. Anything that raises denHi further must re-check this.
            (if (i32.gt_s (i32.sub (local.get $yHi) (local.get $yLo)) (i32.const 95))
              (then (local.set $yLo (i32.sub (local.get $yHi) (i32.const 95)))))
            ;; ---- regolith / surface material: v1's rule, verbatim ---------
            (local.set $moist (call $moistAt (local.get $gx) (local.get $gz)))
            (local.set $h0i (i32.trunc_f64_s (f64.floor (local.get $h0))))
            (local.set $surf (i32.const 1))
            (if (i32.le_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 11)))) (then (local.set $surf (i32.const 4))))
            (if (i32.gt_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 10)))) (then (local.set $surf (i32.const 8))))
            (if (i32.and (i32.and (i32.gt_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 13))))
                                 (i32.le_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 14)))))
                          (f64.gt (local.get $moist) (call $g (i32.const 15))))
              (then (local.set $surf (i32.const 1))))
            (if (i32.and (i32.and (i32.gt_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 13))))
                                 (i32.le_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 14)))))
                          (f64.le (local.get $moist) (call $g (i32.const 15))))
              (then (local.set $surf (i32.const 2))))
            (local.set $sub (i32.const 2))
            (if (i32.lt_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 12)))) (then (local.set $sub (i32.const 4))))
            (local.set $veneer (i32.const 4))
            (if (f64.lt (call $rand01 (call $hash2 (local.get $gx) (local.get $gz) (i32.const 0x42415245)))
                        (call $phv (local.get $p) (i32.const 0)))
              (then (local.set $veneer (i32.const 0))))
            (local.set $colp (i32.add (i32.const 0x4000) (i32.mul (local.get $p) (local.get $csl))))
            ;; ---- pass 1: the band, top-down, into the DBAND flags --------
            (local.set $top (i32.const -1))
            (local.set $ly (local.get $yHi))
            (block $bEnd (loop $bLoop
              (local.set $d (f64.add
                (f64.sub (local.get $h0) (f64.convert_i32_s (local.get $ly)))
                (f64.mul (call $noise3
                           (f64.mul (f64.convert_i32_s (local.get $gx)) (local.get $n3xy))
                           (f64.mul (f64.convert_i32_s (local.get $ly)) (local.get $n3y))
                           (f64.mul (f64.convert_i32_s (local.get $gz)) (local.get $n3xy))
                           (i32.const 0x3DDE5E)) (local.get $ovh))))
              (if (f64.gt (local.get $d) (f64.const 0.0))
                (then
                  (i32.store8 (i32.add (i32.const 0x5a00) (i32.sub (local.get $ly) (local.get $yLo))) (i32.const 1))
                  (if (i32.lt_s (local.get $top) (i32.const 0)) (then (local.set $top (local.get $ly)))))
                (else (i32.store8 (i32.add (i32.const 0x5a00) (i32.sub (local.get $ly) (local.get $yLo))) (i32.const 0))))
              (br_if $bEnd (i32.le_s (local.get $ly) (local.get $yLo)))
              (local.set $ly (i32.sub (local.get $ly) (i32.const 1)))
              (br $bLoop)))
            (if (i32.lt_s (local.get $top) (i32.const 0)) (then (local.set $top (i32.const 0))))
            ;; ---- pass 2: the whole column, top-down ----------------------
            (local.set $bi (i32.add (i32.add (i32.mul (local.get $lz) (local.get $asl)) (local.get $lx))
                                    (i32.mul (i32.sub (local.get $yN) (i32.const 1)) (local.get $aw))))
            (local.set $ly (i32.sub (local.get $yN) (i32.const 1)))
            (block $yEnd (loop $yLoop
              (local.set $d (f64.const 0.0))
              (local.set $rock (i32.const 0))
              ;; solid? -> band flag, or the proven regions either side of it
              (if (i32.gt_s (local.get $ly) (local.get $yHi))
                (then (local.set $rock (i32.const 0)))
                (else (if (i32.lt_s (local.get $ly) (local.get $yLo))
                  (then (local.set $rock (i32.const 1)))
                  (else (local.set $rock (i32.load8_u (i32.add (i32.const 0x5a00) (i32.sub (local.get $ly) (local.get $yLo)))))))))
              (if (local.get $rock)
                (then
                  (local.set $depth (i32.sub (local.get $top) (local.get $ly)))
                  (if (i32.lt_s (local.get $depth) (local.get $veneer))
                    (then
                      (if (i32.lt_s (local.get $depth) (i32.const 2))
                        (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $surf)))
                        (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $sub)))))
                    (else
                      (local.set $rock (i32.load8_u (i32.add (local.get $colp) (local.get $ly))))
                      ;; Caves gate on the LOCAL depth below the local top (v1/v2
                      ;; used the absolute `ly < h - 3`; with a 3-D surface the
                      ;; local depth is the version of that which still means
                      ;; "never carve the ground you stand on"). Every path here
                      ;; stores exactly one byte: the arena is a recycled pool, so
                      ;; a carve MUST write air rather than write nothing.
                      (if (i32.le_s (local.get $depth) (i32.const 3))
                        (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $rock)))
                        (else
                          (local.set $cave1 (call $noise2
                            (f64.add (f64.mul (f64.convert_i32_s (local.get $gx)) (f64.const 0.031))
                                     (f64.mul (f64.convert_i32_s (local.get $ly)) (f64.const 0.17)))
                            (f64.mul (f64.convert_i32_s (local.get $gz)) (f64.const 0.031))
                            (i32.const 0xCAF3BEEF)))
                          (local.set $cave2 (call $noise2
                            (f64.sub (f64.mul (f64.convert_i32_s (local.get $gx)) (f64.const 0.09))
                                     (f64.mul (f64.convert_i32_s (local.get $ly)) (f64.const 0.23)))
                            (f64.sub (f64.mul (f64.convert_i32_s (local.get $gz)) (f64.const 0.09)) (f64.const 3.1))
                            (i32.const 0xBEEFCAFE)))
                          (if (i32.and (f64.le (local.get $cave1) (local.get $ca)) (f64.le (local.get $cave2) (local.get $cb)))
                            (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $rock)))
                            (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 0)))))))))
                (else
                  ;; air or water above the surface
                  (if (i32.and (i32.le_s (local.get $ly) (local.get $wt)) (i32.lt_s (local.get $top) (local.get $wt)))
                    (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 5)))
                    (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 0))))))
              (br_if $yEnd (i32.le_s (local.get $ly) (i32.const 1)))
              (local.set $bi (i32.sub (local.get $bi) (local.get $aw)))
              (local.set $ly (i32.sub (local.get $ly) (i32.const 1)))
              (br $yLoop)))
            (i32.store8 (i32.add (local.get $block) (i32.add (i32.mul (local.get $lz) (local.get $asl)) (local.get $lx))) (i32.const 3))
            (if (i32.and (i32.and (i32.and (i32.ge_s (local.get $lx) (i32.const 1)) (i32.le_s (local.get $lx) (i32.const 16))) (i32.ge_s (local.get $lz) (i32.const 1))) (i32.le_s (local.get $lz) (i32.const 16)))
              (then
                (i32.store16 (i32.add (local.get $height)
                  (i32.shl (i32.add (i32.sub (local.get $lx) (i32.const 1))
                                    (i32.mul (i32.sub (local.get $lz) (i32.const 1)) (i32.const 16)))
                           (i32.const 1)))
                  (local.get $top))))
            (local.set $lx (i32.add (local.get $lx) (i32.const 1)))
            (br $lxLoop)))
        (local.set $lz (i32.add (local.get $lz) (i32.const 1)))
        (br $lzLoop))))

  ;; ==========================================================================
  ;; v6 — THE PER-COLUMN CAVE MODEL (DEEP TIME Phase 3)
  ;; ==========================================================================
  ;; The cave system v1-v5 shipped was two 3-D noise thresholds tested against
  ;; every solid cell: carve unless `c1 <= caveA AND c2 <= caveB`. Measured on a
  ;; 25-chunk window of the shipped world (__dbg.caveStats, OPTIMIZATION_RESEARCH
  ;; §75) it removed 23.7 % of all stone into ONE connected blob holding 98 % of
  ;; the cave volume, with runs of ~15 blocks in x and z against 4.5 in y —
  ;; pancakes, not passages. The numbers are bad, but the interesting finding is
  ;; WHY the shape is wrong, because it is not a tuning error:
  ;;
  ;; A threshold on a band-limited field carves a BLOB whose surface is as smooth
  ;; as the field, and its cost is one field evaluation per candidate cell
  ;; REGARDLESS of how much it carves. There is therefore no cheap way to have a
  ;; rare feature (the field must be evaluated everywhere just to find out) and no
  ;; cheap way to have a thin one (a thin set needs a steep field, i.e. a high
  ;; frequency, i.e. exactly the frequencies that alias). Hence v1-v5's price:
  ;; ~2 noise2 taps (~8 hashes) on every solid cell below depth 3, ~38 000 taps per
  ;; chunk, ~57 % of the whole generator — and the only shape that price can buy is
  ;; a large smooth blob.
  ;;
  ;; v6 inverts it. A PASSAGE is a 1-D curve in plan view, so it is the level set
  ;; of a 2-D field, and the columns it crosses are a BAND around that level set —
  ;; one evaluation per COLUMN, not per cell. Everything else about a passage is
  ;; then a per-column number: how deep it runs (a slow 2-D field) and how tall it
  ;; is (the cross-section, derived). The kernel evaluates 3 networks x (3-octave
  ;; band + 2-octave drift) + 1 pillar octave = 16 noise2 taps per COLUMN — 4 096
  ;; per chunk, 11 % of v1-v5's — and the y-loop becomes compares. The shape
  ;; improves at the same time, which is the point:
  ;;
  ;;   THE CROSS-SECTION falls out of the band distance for free. With d = |band|,
  ;;   t = the network's half-width and sq = sqrt(1 - (d/t)^2), the network removes
  ;;   levels [ty - fl, ty + h*sq] in the columns it crosses. At the passage's
  ;;   centre (d = 0) that spans the full height; at its edge (d -> t) only the
  ;;   floor slab is left. The result is a FLAT FLOOR and a ceiling that curves
  ;;   down to meet the walls — a dissolved conduit's shape, and the one thing a
  ;;   thresholded 3-D field cannot make, because there the floor waves with the
  ;;   field.
  ;;
  ;;   PHREATIC vs VADOSE is one compare against the water table (GEO's waterMaxY,
  ;;   the level the kernel already floods to). Speleogenesis: "phreatic passages
  ;;   develop in conditions of complete water-fill, meaning that ceilings and walls
  ;;   may be eroded as readily as floors; vadose passages develop where the water
  ;;   has a free surface and are varieties of entrenched, canyon-like channels."
  ;;   Below the table a network is therefore a WIDE FLAT LENS (cavPhrW x the
  ;;   width, cavPhrH x the ceiling); above it, a TALL CANYON.
  ;;
  ;;   STOREYS are the citation's other half: the table falls as the land is
  ;;   uplifted, so a passage abandoned above the new table is a dry upper storey
  ;;   and the active one is below it. Each network's level here is a SUBDUED COPY
  ;;   of the column's own surface (tymin + (top - tymin) * sf) plus a slow drift
  ;;   field, so passages follow the hills at three different fractions of their
  ;;   height and the cave-per-level histogram is multi-modal instead of flat.
  ;;
  ;;   JOINT SETS are the structural template every real network inherits
  ;;   (GEOLOGY.md §4.5). The band field is sampled in a ROTATED frame — the
  ;;   passage azimuth is (ca, sa) in the table — with the along-passage axis
  ;;   scaled by `aniso` < 1, which stretches every level set along that azimuth:
  ;;   long straight passages along the joint, and two conjugate networks crossing
  ;;   at an angle. It costs nothing: it is a coordinate change in a call that was
  ;;   already being made.
  ;;
  ;;   KARST is why cave country is limestone. A dissolved conduit needs a soluble
  ;;   host, so each network's width is multiplied by `cavKarst` where the rock at
  ;;   the storey's own level is not a carbonate (Limestone 33, Chalk 34, Dolomite
  ;;   35, Marble 43 — the four ROCK_DEFS entries whose mineralogy is CaCO3 or
  ;;   CaMg(CO3)2). Because the column table is indexed by ABSOLUTE y this is a
  ;;   single byte load, and it makes the cave fraction a function of where each
  ;;   storey happens to intersect a carbonate bed — which is what a karst map is.
  ;;   Wikipedia *Aquifer*: USGS dye tracing found that models "assuming a uniform
  ;;   distribution of porosity are not applicable to karst aquifers" — the flow is
  ;;   LOCALISED. This gate is that statement as one multiply.
  ;;
  ;;   PILLARS are the strongest "this is a cave" read a voxel world has and what
  ;;   stops a big room from being a featureless bubble: one extra octave per
  ;;   column decides whether the column is stone, and a stone column is left
  ;;   standing through the room network's interval.
  ;;
  ;; Tables (page 0, alongside COL/PROV/PH/DBAND; both are kernel-private — no JS
  ;; address reads them, so a later phase may move them freely):
  ;;   CAV_TAB 0x5B00  f64[8][9]  per network, stride 72 B:
  ;;     +0  w       band half-width, in band-field units
  ;;     +8  f       band frequency, blocks^-1 (across a passage)
  ;;     +16 h       ceiling height above the storey, blocks (vadose)
  ;;     +24 fl      floor depth below the storey, blocks
  ;;     +32 sf      storey fraction of the way from tymin to this column's surface
  ;;     +40 aniso   along-passage frequency multiplier (1 = no joint set)
  ;;     +48 ca      cos of the passage azimuth
  ;;     +56 sa      sin of the passage azimuth
  ;;     +64 driftA  storey drift amplitude, blocks
  ;;   CAV_IV  0x5D80  i32[8]     the CURRENT column's result (see $caveCols):
  ;;                 [0..5] = lo,hi per network; [6] = the pillar flag.
  ;;   tymin is GEO's denMin (the lowest mean surface the world can have), which is
  ;;   the only sane "sea floor of the crust" the column model can use, and it is
  ;;   already a per-version altitude — no new knob.
  ;; ==========================================================================

  ;; One network's intersection with ONE column. Writes lo/hi to CAV_IV[k] and,
  ;; for the room network (k = 2), the pillar flag to CAV_IV[6].
  ;;
  ;; `hi < lo` means "this column is not in the network". It is written when the
  ;; column misses the band, when the host rock gates the width down to nothing,
  ;; and when the resulting interval would be empty. That last case is what keeps
  ;; the surface intact: the ceiling is clamped to top - cavRoof, the same reserve
  ;; the depth <= 3 rule below already enforces, so a v6 column can never have its
  ;; topmost rock removed and `openCols` stays 0 exactly as it does for v1-v5.
  (func $caveNet
    (param $k i32) (param $gx i32) (param $gz i32) (param $top i32) (param $wt i32)
    (param $colp i32) (param $wh i32)
    (local $o i32) (local $fx f64) (local $fz f64)
    (local $cw f64) (local $cf f64) (local $ch f64) (local $cfl f64) (local $csf f64)
    (local $can f64) (local $cca f64) (local $csa f64) (local $cdr f64)
    (local $cal f64) (local $cax f64) (local $cnv f64) (local $cad f64)
    (local $cwE f64) (local $chE f64) (local $cty f64)
    (local $chi i32) (local $clo i32) (local $csq f64) (local $chost i32)
    (local $ctyI i32) (local $tmin f64) (local $coc f64) (local $roof i32)
    (local.set $o (i32.add (i32.const 0x5B00) (i32.mul (local.get $k) (i32.const 72))))
    (local.set $cw  (f64.load (local.get $o)))
    (local.set $cf  (f64.load (i32.add (local.get $o) (i32.const 8))))
    (local.set $ch  (f64.load (i32.add (local.get $o) (i32.const 16))))
    (local.set $cfl (f64.load (i32.add (local.get $o) (i32.const 24))))
    (local.set $csf (f64.load (i32.add (local.get $o) (i32.const 32))))
    (local.set $can (f64.load (i32.add (local.get $o) (i32.const 40))))
    (local.set $cca (f64.load (i32.add (local.get $o) (i32.const 48))))
    (local.set $csa (f64.load (i32.add (local.get $o) (i32.const 56))))
    (local.set $cdr (f64.load (i32.add (local.get $o) (i32.const 64))))
    (local.set $fx (f64.convert_i32_s (local.get $gx)))
    (local.set $fz (f64.convert_i32_s (local.get $gz)))
    ;; joint-frame coordinates: `cal` runs ALONG the passage azimuth, `cax` across it
    (local.set $cal (f64.add (f64.mul (local.get $fx) (local.get $cca)) (f64.mul (local.get $fz) (local.get $csa))))
    (local.set $cax (f64.sub (f64.mul (local.get $fz) (local.get $cca)) (f64.mul (local.get $fx) (local.get $csa))))
    ;; the band field, centred on zero. Across carries the whole frequency; along
    ;; carries `aniso` of it, so every level set is stretched along the azimuth.
    (local.set $cnv (f64.sub (call $fbm
        (f64.mul (local.get $cax) (local.get $cf))
        (f64.mul (local.get $cal) (f64.mul (local.get $cf) (local.get $can)))
        (i32.trunc_f64_s (call $g (i32.const 45)))
        (i32.add (i32.const 0xC0FFEE00) (i32.mul (local.get $k) (i32.const 0x9E3779B9))))
      (f64.const 0.5)))
    (local.set $cad (f64.abs (local.get $cnv)))
    ;; the storey: a subdued copy of this column's OWN surface plus a slow drift
    (local.set $tmin (call $g (i32.const 26)))
    (local.set $cty (f64.add
      (f64.add (local.get $tmin)
        (f64.mul (f64.sub (f64.convert_i32_s (local.get $top)) (local.get $tmin)) (local.get $csf)))
      (f64.mul (f64.sub (call $fbm
          (f64.mul (local.get $fx) (call $g (i32.const 40)))
          (f64.mul (local.get $fz) (call $g (i32.const 40)))
          (i32.trunc_f64_s (call $g (i32.const 46)))
          (i32.add (i32.const 0x5A5A0000) (i32.mul (local.get $k) (i32.const 0x9E3779B9))))
        (f64.const 0.5)) (local.get $cdr))))
    ;; the karst gate: how soluble is the rock AT THE STOREY'S OWN LEVEL
    (local.set $ctyI (i32.trunc_f64_s (f64.floor (local.get $cty))))
    (if (i32.lt_s (local.get $ctyI) (i32.const 1)) (then (local.set $ctyI (i32.const 1))))
    (if (i32.gt_s (local.get $ctyI) (local.get $wh)) (then (local.set $ctyI (local.get $wh))))
    (local.set $chost (i32.load8_u (i32.add (local.get $colp) (local.get $ctyI))))
    (local.set $coc (f64.const 1.0))
    (if (i32.eqz (i32.or (i32.and (i32.ge_s (local.get $chost) (i32.const 33))
                                  (i32.le_s (local.get $chost) (i32.const 35)))
                         (i32.eq (local.get $chost) (i32.const 43))))
      (then (local.set $coc (call $g (i32.const 42)))))
    ;; width: saturation x host solubility x the phreatic widening
    (local.set $cwE (f64.mul (f64.mul (local.get $cw) (call $g (i32.const 39))) (local.get $coc)))
    (local.set $chE (local.get $ch))
    (if (i32.le_s (local.get $ctyI) (local.get $wt))
      (then
        (local.set $cwE (f64.mul (local.get $cwE) (call $g (i32.const 43))))
        (local.set $chE (f64.mul (local.get $chE) (call $g (i32.const 44))))))
    (local.set $roof (i32.trunc_f64_s (call $g (i32.const 47))))
    ;; the interval
    (local.set $clo (i32.const 1))
    (local.set $chi (i32.const 0))
    (if (i32.and (f64.gt (local.get $cwE) (f64.const 1e-6)) (f64.lt (local.get $cad) (local.get $cwE)))
      (then
        (local.set $csq (f64.div (local.get $cad) (local.get $cwE)))
        (local.set $csq (f64.sqrt (f64.max (f64.const 0.0)
          (f64.sub (f64.const 1.0) (f64.mul (local.get $csq) (local.get $csq))))))
        (local.set $chi (i32.trunc_f64_s (f64.floor (f64.add (local.get $cty) (f64.mul (local.get $chE) (local.get $csq))))))
        (local.set $clo (i32.trunc_f64_s (f64.floor (f64.sub (local.get $cty) (local.get $cfl)))))
        (if (i32.lt_s (local.get $clo) (i32.const 1)) (then (local.set $clo (i32.const 1))))
        (if (i32.gt_s (local.get $chi) (i32.sub (local.get $top) (local.get $roof)))
          (then (local.set $chi (i32.sub (local.get $top) (local.get $roof)))))
        (if (i32.lt_s (local.get $chi) (local.get $clo))
          (then (local.set $clo (i32.const 1)) (local.set $chi (i32.const 0))))))
    (i32.store (i32.add (i32.const 0x5D80) (i32.shl (local.get $k) (i32.const 3))) (local.get $clo))
    (i32.store (i32.add (i32.const 0x5D84) (i32.shl (local.get $k) (i32.const 3))) (local.get $chi))
    ;; the pillar tap: ONE octave, so a pillar is a blob a few blocks across and the
    ;; same column stays stone for every level of the room interval.
    (if (i32.eq (local.get $k) (i32.const 2))
      (then
        (i32.store (i32.const 0x5D98)
          (if (result i32)
            (f64.gt (call $fbm
                      (f64.mul (local.get $fx) (f64.const 0.35))
                      (f64.mul (local.get $fz) (f64.const 0.35))
                      (i32.const 1) (i32.const 0x9B1D5A11))
                    (call $g (i32.const 41)))
            (then (i32.const 1)) (else (i32.const 0)))))))

  ;; Every network for ONE column, in table order. The pillar flag is cleared first
  ;; because only the room network writes it: a stale 1 from the previous column
  ;; would leave a stray stone column standing in a room.
  (func $caveCols
    (param $gx i32) (param $gz i32) (param $top i32) (param $wt i32)
    (param $colp i32) (param $wh i32)
    (local $k i32)
    (i32.store (i32.const 0x5D98) (i32.const 0))
    (local.set $k (i32.const 0))
    (block $kEnd (loop $kLoop
      (br_if $kEnd (i32.ge_s (local.get $k) (i32.const 3)))
      (call $caveNet (local.get $k) (local.get $gx) (local.get $gz) (local.get $top)
                     (local.get $wt) (local.get $colp) (local.get $wh))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $kLoop))))


  ;; The v6 column generator. Byte-for-byte v4's body except for the cave block:
  ;; the locals, the GEO reads, the $caveCols call between pass 1 and pass 2, and
  ;; the carve test in pass 2. That is deliberate -- everything above the caves is
  ;; IDENTICAL to the frozen v4/v5 generator, so a difference between a v6 and a
  ;; v5 chunk is a difference in the caves and nowhere else, which is what makes
  ;; __dbg.caveStats' two-arm comparison on the same seed meaningful.
  (func $genChunkV6
    (param $cx i32) (param $cz i32) (param $seed i32) (param $block i32) (param $height i32)
    (local $lx i32) (local $lz i32) (local $gx i32) (local $gz i32)
    (local $ly i32) (local $bi i32)
    (local $aw i32) (local $asl i32) (local $wh i32) (local $yN i32) (local $wt i32)
    (local $cont f64) (local $ero f64) (local $pv f64)
    (local $h0 f64) (local $ovh f64) (local $d f64) (local $n3 f64)
    (local $yHi i32) (local $yLo i32)
    (local $top i32) (local $depth i32) (local $veneer i32) (local $h0i i32)
    (local $p i32) (local $colp i32) (local $csl i32) (local $rock i32)
    (local $surf i32) (local $sub i32) (local $moist f64)
    (local $n3xy f64) (local $n3y f64)
    ;; --- v6 cross-section state: three intervals + one pillar flag ---------
    (local $lo0 i32) (local $hi0 i32) (local $lo1 i32) (local $hi1 i32)
    (local $lo2 i32) (local $hi2 i32) (local $pil i32) (local $cav i32)
    (local.set $aw (global.get $AW))
    (local.set $asl (global.get $ASL))
    (local.set $wh (global.get $WH))
    (local.set $yN (i32.add (local.get $wh) (i32.const 2)))
    (local.set $wt (i32.trunc_f64_s (call $g (i32.const 16))))
    (local.set $csl (global.get $COLSL))
    (local.set $n3xy (call $g (i32.const 24)))
    (local.set $n3y (call $g (i32.const 25)))
    (global.set $SEED (local.get $seed))
    (local.set $lz (i32.const 0))
    (block $lzEnd
      (loop $lzLoop
        (br_if $lzEnd (i32.ge_s (local.get $lz) (local.get $aw)))
        (local.set $gz (i32.sub (i32.add (i32.mul (local.get $cz) (i32.const 16)) (local.get $lz)) (i32.const 1)))
        (local.set $lx (i32.const 0))
        (block $lxEnd
          (loop $lxLoop
            (br_if $lxEnd (i32.ge_s (local.get $lx) (local.get $aw)))
            (local.set $gx (i32.sub (i32.add (i32.mul (local.get $cx) (i32.const 16)) (local.get $lx)) (i32.const 1)))
            ;; ---- the column's two spline outputs -------------------------
            (local.set $p (i32.and (call $colProv (i32.add (local.get $lx) (i32.mul (local.get $lz) (local.get $aw)))) (i32.const 7)))
            (local.set $cont (call $contAt (local.get $gx) (local.get $gz)))
            (local.set $ero (call $eroAt (local.get $gx) (local.get $gz)))
            (local.set $pv (call $pvAt (local.get $gx) (local.get $gz)))
            (local.set $h0 (f64.add
              (f64.add (call $spline (i32.const 0) (local.get $cont))
                       (f64.mul (call $spline (i32.const 1) (local.get $pv)) (call $g (i32.const 30))))
              (call $phv2 (local.get $p) (i32.const 0))))
            (local.set $ovh (f64.mul
              (f64.mul (call $spline (i32.const 2) (local.get $ero)) (call $g (i32.const 31)))
              (call $phv2 (local.get $p) (i32.const 1))))
            (if (f64.lt (local.get $h0) (call $g (i32.const 26))) (then (local.set $h0 (call $g (i32.const 26)))))
            (if (f64.gt (local.get $h0) (call $g (i32.const 27))) (then (local.set $h0 (call $g (i32.const 27)))))
            (if (f64.lt (local.get $ovh) (call $g (i32.const 28))) (then (local.set $ovh (call $g (i32.const 28)))))
            (if (f64.gt (local.get $ovh) (call $g (i32.const 29))) (then (local.set $ovh (call $g (i32.const 29)))))
            ;; SHORE FOLD-DAMP (worldgen 6+ only: v1-v5 frozen, corpus-gated). Still
            ;; water wants a bank, not a lip: ramp the fold amplitude to a pure
            ;; heightmap at/below the waterline, full strength 8 blocks above it.
            (local.set $ovh (f64.mul (local.get $ovh) (call $shoreDamp (local.get $h0))))
            ;; ---- the band that may contain the surface -------------------
            ;; D <= h0 - y + 0.87*ovh, so above yHi the sign is proven negative;
            ;; D >= h0 - y - 0.87*ovh, so below yLo it is proven positive. Only
            ;; the band between them needs the 3-D noise, and only the band's
            ;; TOPMOST solid level is the column's surface. This is the whole
            ;; reason a density field costs what a heightmap costs: the band is
            ;; ~1.74*ovh tall instead of the whole column.
            (local.set $yHi (i32.add (i32.trunc_f64_s (f64.floor (f64.add (local.get $h0) (f64.mul (local.get $ovh) (f64.const 0.8727))))) (i32.const 1)))
            (local.set $yLo (i32.sub (i32.trunc_f64_s (f64.floor (f64.sub (local.get $h0) (f64.mul (local.get $ovh) (f64.const 0.8727))))) (i32.const 1)))
            (if (i32.gt_s (local.get $yHi) (i32.sub (local.get $yN) (i32.const 1))) (then (local.set $yHi (i32.sub (local.get $yN) (i32.const 1)))))
            (if (i32.lt_s (local.get $yLo) (i32.const 1)) (then (local.set $yLo (i32.const 1))))
            (if (i32.lt_s (local.get $yHi) (local.get $yLo)) (then (local.set $yHi (local.get $yLo))))
            ;; DBAND holds one flag per band level, so the band must fit it. The
            ;; scratch is 96 bytes at 0x5A00 (leaving room up to 0x5A60) and the
            ;; clamp below is 95, i.e. ONE LESS than the capacity.
            ;;
            ;; The clamp is only CORRECT where every level it clips is already
            ;; proven solid, which is the case when h0 - 0.87*ovh falls below the
            ;; world floor. At WH = 64 that is the only case that can arise: ovh
            ;; is clamped to denHi = 22, so the band is at most
            ;; 1.7454*22 + 2 = 40 levels and the clamp NEVER fires (it is dead
            ;; code for worldgen 1-4, which is what keeps them frozen). A taller
            ;; world scales denHi with the vertical extent (worldgen 5:
            ;; denHi = 43.31), so the band can reach 1.7454*43.31 + 2 = 78 levels
            ;; and the clamp WOULD fire in deep orogens — and there it is NOT
            ;; free: yLo would be raised ~18 levels and a slab 18 deep around
            ;; h0 - 20 .. h0 - 38 would be marked solid from the flag array
            ;; instead of from the field, filling real cave voids with rock.
            ;; Hence the capacity went 61 -> 96 bytes (a scratch inside the
            ;; kernel's own region, read by no JS address) when worldgen 5 was
            ;; added. Anything that raises denHi further must re-check this.
            (if (i32.gt_s (i32.sub (local.get $yHi) (local.get $yLo)) (i32.const 95))
              (then (local.set $yLo (i32.sub (local.get $yHi) (i32.const 95)))))
            ;; ---- regolith / surface material: v1's rule, verbatim ---------
            (local.set $moist (call $moistAt (local.get $gx) (local.get $gz)))
            (local.set $h0i (i32.trunc_f64_s (f64.floor (local.get $h0))))
            (local.set $surf (i32.const 1))
            (if (i32.le_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 11)))) (then (local.set $surf (i32.const 4))))
            (if (i32.gt_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 10)))) (then (local.set $surf (i32.const 8))))
            (if (i32.and (i32.and (i32.gt_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 13))))
                                 (i32.le_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 14)))))
                          (f64.gt (local.get $moist) (call $g (i32.const 15))))
              (then (local.set $surf (i32.const 1))))
            (if (i32.and (i32.and (i32.gt_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 13))))
                                 (i32.le_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 14)))))
                          (f64.le (local.get $moist) (call $g (i32.const 15))))
              (then (local.set $surf (i32.const 2))))
            (local.set $sub (i32.const 2))
            (if (i32.lt_s (local.get $h0i) (i32.trunc_f64_s (call $g (i32.const 12)))) (then (local.set $sub (i32.const 4))))
            (local.set $veneer (i32.const 4))
            (if (f64.lt (call $rand01 (call $hash2 (local.get $gx) (local.get $gz) (i32.const 0x42415245)))
                        (call $phv (local.get $p) (i32.const 0)))
              (then (local.set $veneer (i32.const 0))))
            (local.set $colp (i32.add (i32.const 0x4000) (i32.mul (local.get $p) (local.get $csl))))
            ;; ---- pass 1: the band, top-down, into the DBAND flags --------
            (local.set $top (i32.const -1))
            (local.set $ly (local.get $yHi))
            (block $bEnd (loop $bLoop
              (local.set $d (f64.add
                (f64.sub (local.get $h0) (f64.convert_i32_s (local.get $ly)))
                (f64.mul (call $noise3
                           (f64.mul (f64.convert_i32_s (local.get $gx)) (local.get $n3xy))
                           (f64.mul (f64.convert_i32_s (local.get $ly)) (local.get $n3y))
                           (f64.mul (f64.convert_i32_s (local.get $gz)) (local.get $n3xy))
                           (i32.const 0x3DDE5E)) (local.get $ovh))))
              (if (f64.gt (local.get $d) (f64.const 0.0))
                (then
                  (i32.store8 (i32.add (i32.const 0x5a00) (i32.sub (local.get $ly) (local.get $yLo))) (i32.const 1))
                  (if (i32.lt_s (local.get $top) (i32.const 0)) (then (local.set $top (local.get $ly)))))
                (else (i32.store8 (i32.add (i32.const 0x5a00) (i32.sub (local.get $ly) (local.get $yLo))) (i32.const 0))))
              (br_if $bEnd (i32.le_s (local.get $ly) (local.get $yLo)))
              (local.set $ly (i32.sub (local.get $ly) (i32.const 1)))
              (br $bLoop)))
            (if (i32.lt_s (local.get $top) (i32.const 0)) (then (local.set $top (i32.const 0))))
            ;; ---- v6: the column's cave intervals -------------------------
            ;; ONE call for the whole column; the y-loop below then reads six
            ;; integers. The storey needs this column's top, which is why this
            ;; sits after pass 1 rather than in the column preamble.
            (call $caveCols (local.get $gx) (local.get $gz) (local.get $top)
                            (local.get $wt) (local.get $colp) (local.get $wh))
            (local.set $lo0 (i32.load (i32.const 0x5D80)))
            (local.set $hi0 (i32.load (i32.const 0x5D84)))
            (local.set $lo1 (i32.load (i32.const 0x5D88)))
            (local.set $hi1 (i32.load (i32.const 0x5D8C)))
            (local.set $lo2 (i32.load (i32.const 0x5D90)))
            (local.set $hi2 (i32.load (i32.const 0x5D94)))
            (local.set $pil (i32.load (i32.const 0x5D98)))
            ;; ---- pass 2: the whole column, top-down ----------------------
            (local.set $bi (i32.add (i32.add (i32.mul (local.get $lz) (local.get $asl)) (local.get $lx))
                                    (i32.mul (i32.sub (local.get $yN) (i32.const 1)) (local.get $aw))))
            (local.set $ly (i32.sub (local.get $yN) (i32.const 1)))
            (block $yEnd (loop $yLoop
              (local.set $d (f64.const 0.0))
              (local.set $rock (i32.const 0))
              ;; solid? -> band flag, or the proven regions either side of it
              (if (i32.gt_s (local.get $ly) (local.get $yHi))
                (then (local.set $rock (i32.const 0)))
                (else (if (i32.lt_s (local.get $ly) (local.get $yLo))
                  (then (local.set $rock (i32.const 1)))
                  (else (local.set $rock (i32.load8_u (i32.add (i32.const 0x5a00) (i32.sub (local.get $ly) (local.get $yLo)))))))))
              (if (local.get $rock)
                (then
                  (local.set $depth (i32.sub (local.get $top) (local.get $ly)))
                  (if (i32.lt_s (local.get $depth) (local.get $veneer))
                    (then
                      (if (i32.lt_s (local.get $depth) (i32.const 2))
                        (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $surf)))
                        (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $sub)))))
                    (else
                      (local.set $rock (i32.load8_u (i32.add (local.get $colp) (local.get $ly))))
                      ;; Caves gate on the LOCAL depth below the local top (v1/v2
                      ;; used the absolute `ly < h - 3`; with a 3-D surface the
                      ;; local depth is the version of that which still means
                      ;; "never carve the ground you stand on"). Every path here
                      ;; stores exactly one byte: the arena is a recycled pool, so
                      ;; a carve MUST write air rather than write nothing.
                      (if (i32.le_s (local.get $depth) (i32.const 3))
                        (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $rock)))
                        (else
                          ;; v6: NO NOISE IS EVALUATED IN THIS LOOP ANY MORE. The
                          ;; column already decided which levels its three networks
                          ;; remove (see $caveCols), so this is three interval tests
                          ;; and one flag. That is the whole of Phase 3's
                          ;; restructuring: v1-v5 paid two noise taps on every SOLID
                          ;; CELL, and a tap costs the same whether the passage it
                          ;; finds is common or rare, so a rare thin winding passage
                          ;; was simply unaffordable at any threshold.
                          (local.set $cav (i32.const 0))
                          (if (i32.and (i32.ge_s (local.get $ly) (local.get $lo0)) (i32.le_s (local.get $ly) (local.get $hi0)))
                            (then (local.set $cav (i32.const 1))))
                          (if (i32.and (i32.ge_s (local.get $ly) (local.get $lo1)) (i32.le_s (local.get $ly) (local.get $hi1)))
                            (then (local.set $cav (i32.const 1))))
                          ;; the pillar cancels the ROOM network only: a conduit that
                          ;; crosses a chamber still cuts its own passage through it,
                          ;; which is what stops one big blob from being one big room.
                          (if (i32.and (i32.ge_s (local.get $ly) (local.get $lo2)) (i32.le_s (local.get $ly) (local.get $hi2)))
                            (then (if (i32.eqz (local.get $pil)) (then (local.set $cav (i32.const 1))))))
                          (if (local.get $cav)
                            (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 0)))
                            (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (local.get $rock)))))))))
                (else
                  ;; air or water above the surface
                  (if (i32.and (i32.le_s (local.get $ly) (local.get $wt)) (i32.lt_s (local.get $top) (local.get $wt)))
                    (then (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 5)))
                    (else (i32.store8 (i32.add (local.get $block) (local.get $bi)) (i32.const 0))))))
              (br_if $yEnd (i32.le_s (local.get $ly) (i32.const 1)))
              (local.set $bi (i32.sub (local.get $bi) (local.get $aw)))
              (local.set $ly (i32.sub (local.get $ly) (i32.const 1)))
              (br $yLoop)))
            (i32.store8 (i32.add (local.get $block) (i32.add (i32.mul (local.get $lz) (local.get $asl)) (local.get $lx))) (i32.const 3))
            (if (i32.and (i32.and (i32.and (i32.ge_s (local.get $lx) (i32.const 1)) (i32.le_s (local.get $lx) (i32.const 16))) (i32.ge_s (local.get $lz) (i32.const 1))) (i32.le_s (local.get $lz) (i32.const 16)))
              (then
                (i32.store16 (i32.add (local.get $height)
                  (i32.shl (i32.add (i32.sub (local.get $lx) (i32.const 1))
                                    (i32.mul (i32.sub (local.get $lz) (i32.const 1)) (i32.const 16)))
                           (i32.const 1)))
                  (local.get $top))))
            (local.set $lx (i32.add (local.get $lx) (i32.const 1)))
            (br $lxLoop)))
        (local.set $lz (i32.add (local.get $lz) (i32.const 1)))
        (br $lzLoop))))


  (func $solid (param $t i32) (result i32)
    (if (result i32)
      (i32.and (i32.ne (local.get $t) (i32.const 0)) (i32.ne (local.get $t) (i32.const 5)))
      (then (i32.const 1)) (else (i32.const 0))))

  ;; ---------- greedy mesher ----------
  ;; Vertices are packed u32: x+1(5) | y+1(7) | z+1(5) | bcode(6) | norm(3) | light(6).
  ;; DEEP TIME Phase 1a took the material-space decision of GEOLOGY.md 4.3(A): the
  ;; 7th light bit was handed to bcode, so the meshable material count went 32 -> 64
  ;; (31 used -> 33 free) at ZERO vertex cost. Brightness is quantised 1/127 -> 1/63,
  ;; which is ~1.6 % on a value that is already a smooth lighting product; the
  ;; minimum-brightness clamp moved 35 -> 17 with it (70/255 == 35/127 == 17/63), so
  ;; the darkest cave face keeps exactly the floor it always had. `y+1` is still 7 bits
  ;; (holds y <= 126), so a 128-tall world needs no further vertex change.
  ;; The greedy mesher merges coplanar same-block same-light faces per slice into
  ;; one quad (0fps mask-scan), recomputing the 4 corner AOs from live block data.

  ;; AO for one quad corner. bi = arena index of the corner's support block;
  ;; dir = arena offset along the face normal; sA/sB = arena strides of the two
  ;; tangents; sgnA/sgnB (+-1) select which side of the corner to sample (each
  ;; quad corner looks outward along its own tangent directions). The 3 samples
  ;; are the blocks in the face plane around the corner.
  (func $cornerAO (param $bp i32) (param $bi i32) (param $dir i32) (param $sA i32) (param $sB i32) (param $sgnA i32) (param $sgnB i32) (result i32)
    (local $aA i32) (local $aB i32) (local $o1 i32) (local $o2 i32) (local $s1 i32) (local $s2 i32) (local $cc i32)
    (local.set $aA (i32.mul (local.get $sgnA) (local.get $sA)))
    (local.set $aB (i32.mul (local.get $sgnB) (local.get $sB)))
    (local.set $o1 (i32.add (i32.add (local.get $bi) (local.get $dir)) (local.get $aA)))
    (local.set $o2 (i32.add (i32.add (local.get $bi) (local.get $dir)) (local.get $aB)))
    (local.set $s1 (call $solid (i32.load8_u (i32.add (local.get $bp) (local.get $o1)))))
    (local.set $s2 (call $solid (i32.load8_u (i32.add (local.get $bp) (local.get $o2)))))
    (local.set $cc (call $solid (i32.load8_u (i32.add (local.get $bp) (i32.add (local.get $o1) (local.get $aB))))))
    (if (i32.and (local.get $s1) (local.get $s2)) (then (return (i32.const 3))))
    (if (i32.xor (local.get $s1) (local.get $s2)) (then (return (i32.const 2))))
    (if (local.get $cc) (then (return (i32.const 1))))
    (i32.const 0))

  (func $vl (param $lb i32) (param $ao i32) (result i32)
    (local $v f64)
    (local.set $v (f64.mul (f64.convert_i32_s (local.get $lb))
      (f64.sub (f64.const 1.0) (f64.mul (f64.convert_i32_s (local.get $ao)) (f64.const 0.10)))))
    (if (result i32) (f64.lt (local.get $v) (f64.const 17.0))
      (then (i32.const 17))
      (else (i32.trunc_f64_s (local.get $v)))))

  (func $packV (param $cx i32) (param $cy i32) (param $cz i32) (param $code i32) (param $norm i32) (param $lt i32) (result i32)
    (local $p i32)
    (local.set $p (i32.or (i32.add (local.get $cx) (i32.const 1))
      (i32.shl (i32.add (local.get $cy) (i32.const 1)) (i32.const 5))))
    (local.set $p (i32.or (local.get $p) (i32.shl (i32.add (local.get $cz) (i32.const 1)) (i32.const 12))))
    (local.set $p (i32.or (local.get $p) (i32.shl (local.get $code) (i32.const 17))))
    (local.set $p (i32.or (local.get $p) (i32.or (i32.shl (local.get $norm) (i32.const 23)) (i32.shl (local.get $lt) (i32.const 26)))))
    (local.get $p))

  ;; emit one quad: 4 verts + 6 indices. vc/ic live in out[0]/out[1].
  (func $emitQuad
    (param $vox i32) (param $idx i32) (param $out i32) (param $maxVox i32) (param $maxIdx i32)
    (param $x0 i32) (param $y0 i32) (param $z0 i32)
    (param $x1 i32) (param $y1 i32) (param $z1 i32)
    (param $x2 i32) (param $y2 i32) (param $z2 i32)
    (param $x3 i32) (param $y3 i32) (param $z3 i32)
    (param $code i32) (param $norm i32) (param $lb i32)
    (param $ao0 i32) (param $ao1 i32) (param $ao2 i32) (param $ao3 i32)
    (local $vc i32) (local $ic i32) (local $p i32)
    (local.set $vc (i32.load (local.get $out)))
    (local.set $ic (i32.load (i32.add (local.get $out) (i32.const 4))))
    (if (i32.or (i32.gt_s (local.get $vc) (i32.sub (local.get $maxVox) (i32.const 4)))
                (i32.gt_s (local.get $ic) (i32.sub (local.get $maxIdx) (i32.const 6))))
      (then
        (i32.store (local.get $out) (i32.const -1))
        (i32.store (i32.add (local.get $out) (i32.const 4)) (i32.const -1))
        (return)))
    (local.set $p (i32.add (local.get $vox) (i32.shl (local.get $vc) (i32.const 2))))
    (i32.store (local.get $p) (call $packV (local.get $x0) (local.get $y0) (local.get $z0) (local.get $code) (local.get $norm) (call $vl (local.get $lb) (local.get $ao0))))
    (i32.store (i32.add (local.get $p) (i32.const 4)) (call $packV (local.get $x1) (local.get $y1) (local.get $z1) (local.get $code) (local.get $norm) (call $vl (local.get $lb) (local.get $ao1))))
    (i32.store (i32.add (local.get $p) (i32.const 8)) (call $packV (local.get $x2) (local.get $y2) (local.get $z2) (local.get $code) (local.get $norm) (call $vl (local.get $lb) (local.get $ao2))))
    (i32.store (i32.add (local.get $p) (i32.const 12)) (call $packV (local.get $x3) (local.get $y3) (local.get $z3) (local.get $code) (local.get $norm) (call $vl (local.get $lb) (local.get $ao3))))
    (local.set $p (i32.add (local.get $idx) (i32.shl (local.get $ic) (i32.const 2))))
    (i32.store (local.get $p) (local.get $vc))
    (i32.store (i32.add (local.get $p) (i32.const 4)) (i32.add (local.get $vc) (i32.const 1)))
    (i32.store (i32.add (local.get $p) (i32.const 8)) (i32.add (local.get $vc) (i32.const 2)))
    (i32.store (i32.add (local.get $p) (i32.const 12)) (i32.add (local.get $vc) (i32.const 2)))
    (i32.store (i32.add (local.get $p) (i32.const 16)) (i32.add (local.get $vc) (i32.const 1)))
    (i32.store (i32.add (local.get $p) (i32.const 20)) (i32.add (local.get $vc) (i32.const 3)))
    (i32.store (local.get $out) (i32.add (local.get $vc) (i32.const 4)))
    (i32.store (i32.add (local.get $out) (i32.const 4)) (i32.add (local.get $ic) (i32.const 6))))

  ;; arena index of the support block at mask cell (i,j) of a slice at level s
  (func $cellBi (param $bp i32) (param $axis i32) (param $s i32) (param $i i32) (param $j i32)
    (param $aw i32) (param $asl i32) (result i32)
    (local $bi i32)
    (local.set $bi (i32.const 0))
    (if (i32.eq (local.get $axis) (i32.const 1))
      (then
        (local.set $bi (i32.add (i32.add (i32.add (local.get $i) (i32.const 1)) (i32.mul (local.get $s) (local.get $aw))) (i32.mul (i32.add (local.get $j) (i32.const 1)) (local.get $asl))))))
    (if (i32.eq (local.get $axis) (i32.const 0))
      (then
        (local.set $bi (i32.add (i32.add (i32.add (local.get $s) (i32.const 1)) (i32.mul (local.get $j) (local.get $aw))) (i32.mul (i32.add (local.get $i) (i32.const 1)) (local.get $asl))))))
    (if (i32.eq (local.get $axis) (i32.const 2))
      (then
        (local.set $bi (i32.add (i32.add (i32.add (local.get $i) (i32.const 1)) (i32.mul (local.get $j) (local.get $aw))) (i32.mul (i32.add (local.get $s) (i32.const 1)) (local.get $asl))))))
    (local.get $bi))

  ;; grid coords (x,y,z) of the quad corner at mask cell (i,j), slice s.
  ;; The face plane sits at the block boundary: +s along the normal for the
  ;; positive direction (sg=1), i.e. at s for -norm faces, s+1 for +norm faces.
  ;; axis 1 (Y): (i, s+sg, j); axis 0 (X): (s+sg, j, i); axis 2 (Z): (i, j, s+sg)
  ;; Writes x,y,z to the 3 i32s at ptr (avoids multi-value; wabt-safe).
  (func $cornerGrid (param $axis i32) (param $sg i32) (param $s i32) (param $i i32) (param $j i32) (param $ptr i32)
    (local $po i32)
    (local.set $po (i32.add (local.get $s) (local.get $sg)))
    (if (i32.eq (local.get $axis) (i32.const 1))
      (then
        (i32.store (local.get $ptr) (local.get $i))
        (i32.store (i32.add (local.get $ptr) (i32.const 4)) (local.get $po))
        (i32.store (i32.add (local.get $ptr) (i32.const 8)) (local.get $j)))
      (else (if (i32.eq (local.get $axis) (i32.const 0))
        (then
          (i32.store (local.get $ptr) (local.get $po))
          (i32.store (i32.add (local.get $ptr) (i32.const 4)) (local.get $j))
          (i32.store (i32.add (local.get $ptr) (i32.const 8)) (local.get $i)))
        (else
          (i32.store (local.get $ptr) (local.get $i))
          (i32.store (i32.add (local.get $ptr) (i32.const 4)) (local.get $j))
          (i32.store (i32.add (local.get $ptr) (i32.const 8)) (local.get $po)))))))

  ;; one greedy pass: fill a 16-wide mask for every slice along (axis, sign),
  ;; merge equal-valued cells into quads, emit. vc/ic live in out[0]/out[1].
  (func $greedyPass
    (param $bp i32) (param $hp i32) (param $mask i32)
    (param $axis i32) (param $sg i32)
    (param $vox i32) (param $idx i32) (param $out i32) (param $maxVox i32) (param $maxIdx i32)
    (param $aw i32) (param $asl i32) (param $wh i32)
    (local $dir i32) (local $norm i32) (local $sA i32) (local $sB i32)
    (local $sCnt i32) (local $hCnt i32)
    (local $s i32) (local $i i32) (local $j i32) (local $bi i32) (local $biV i32) (local $adjV i32)
    (local $colX i32) (local $colZ i32) (local $ly i32) (local $ch i32) (local $d i32)
    (local $lf f64) (local $lb i32) (local $code i32) (local $val i32)
    (local $w2 i32) (local $h2 i32) (local $iw i32) (local $jh i32)
    (local $k i32) (local $k2 i32) (local $mt i32)
    (local $flip i32) (local $i1 i32) (local $j1 i32) (local $i2 i32) (local $j2 i32)
    (local $cx0 i32) (local $cy0 i32) (local $cz0 i32)
    (local $cx1 i32) (local $cy1 i32) (local $cz1 i32)
    (local $cx2 i32) (local $cy2 i32) (local $cz2 i32)
    (local $cx3 i32) (local $cy3 i32) (local $cz3 i32)
    (local $a0 i32) (local $a1 i32) (local $a2 i32) (local $a3 i32)
    (local $law i32) (local $lasl i32) (local $lwh i32)
    (local.set $law (local.get $aw)) (local.set $lasl (local.get $asl)) (local.set $lwh (local.get $wh))
    (if (i32.eq (local.get $axis) (i32.const 1))
      (then
        (local.set $dir (if (result i32) (i32.eqz (local.get $sg)) (then (i32.sub (i32.const 0) (local.get $law))) (else (local.get $law))))
        (local.set $norm (if (result i32) (i32.eqz (local.get $sg)) (then (i32.const 3)) (else (i32.const 2))))
        (local.set $sA (if (result i32) (i32.eqz (local.get $sg)) (then (i32.const 1)) (else (local.get $lasl))))
        (local.set $sB (if (result i32) (i32.eqz (local.get $sg)) (then (local.get $lasl)) (else (i32.const 1))))
        (local.set $sCnt (local.get $lwh)) (local.set $hCnt (i32.const 16)))
      (else (if (i32.eq (local.get $axis) (i32.const 0))
        (then
          (local.set $dir (if (result i32) (i32.eqz (local.get $sg)) (then (i32.const -1)) (else (i32.const 1))))
          (local.set $norm (if (result i32) (i32.eqz (local.get $sg)) (then (i32.const 1)) (else (i32.const 0))))
          (local.set $sA (if (result i32) (i32.eqz (local.get $sg)) (then (local.get $lasl)) (else (local.get $law))))
          (local.set $sB (if (result i32) (i32.eqz (local.get $sg)) (then (local.get $law)) (else (local.get $lasl))))
          (local.set $sCnt (i32.const 16)) (local.set $hCnt (local.get $lwh)))
        (else
          (local.set $dir (if (result i32) (i32.eqz (local.get $sg)) (then (i32.sub (i32.const 0) (local.get $lasl))) (else (local.get $lasl))))
          (local.set $norm (if (result i32) (i32.eqz (local.get $sg)) (then (i32.const 5)) (else (i32.const 4))))
          (local.set $sA (if (result i32) (i32.eqz (local.get $sg)) (then (local.get $law)) (else (i32.const 1))))
          (local.set $sB (if (result i32) (i32.eqz (local.get $sg)) (then (i32.const 1)) (else (local.get $law))))
          (local.set $sCnt (i32.const 16)) (local.set $hCnt (local.get $lwh))))))
    (local.set $s (i32.const 0))
    (block $sEnd
      (loop $sLoop
        (br_if $sEnd (i32.ge_s (local.get $s) (local.get $sCnt)))
        ;; ---- build mask (u16 per cell: light<<8 | bcode) ----
        (local.set $j (i32.const 0))
            (block $mJEnd
              (loop $mJLoop
                (br_if $mJEnd (i32.ge_s (local.get $j) (local.get $hCnt)))
                (local.set $i (i32.const 0))
                (block $mIEnd
                  (loop $mILoop
                    (br_if $mIEnd (i32.ge_s (local.get $i) (i32.const 16)))
                    (local.set $bi (call $cellBi (local.get $bp) (local.get $axis) (local.get $s) (local.get $i) (local.get $j) (local.get $law) (local.get $lasl)))
                    (local.set $val (i32.const 0))
                    ;; THIN BLOCKS (bamboo 32, torch 17) never emit cube faces --
                    ;; they render as instanced flora cut-outs (atlas cells 29/30)
                    ;; -- but a solid neighbour's faces AGAINST them are emitted,
                    ;; because a 2px stalk occludes nothing. $solid itself stays
                    ;; (0/5) on purpose: $cornerAO samples past the arena edge,
                    ;; and the bytes there (heights, counters, scratch) hold
                    ;; 17/32 values whose frozen-worldgen AO must not move
                    ;; (see kernel-gate). Thin blocks therefore still occlude AO
                    ;; like cubes, which reads as a contact shadow at their base.
                    (local.set $biV (i32.load8_u (i32.add (local.get $bp) (local.get $bi))))
                    (local.set $adjV (i32.load8_u (i32.add (local.get $bp) (i32.add (local.get $bi) (local.get $dir)))))
                    (if (i32.and
                          (i32.and (call $solid (local.get $biV))
                                   (i32.eqz (i32.or (i32.eq (local.get $biV) (i32.const 17)) (i32.eq (local.get $biV) (i32.const 32)))))
                          (i32.or (i32.eqz (call $solid (local.get $adjV)))
                                   (i32.or (i32.eq (local.get $adjV) (i32.const 17)) (i32.eq (local.get $adjV) (i32.const 32)))))
                      (then
                        (if (i32.eq (local.get $axis) (i32.const 1))
                          (then (local.set $colX (local.get $i)) (local.set $colZ (local.get $j)) (local.set $ly (local.get $s)))
                          (else (if (i32.eq (local.get $axis) (i32.const 0))
                            (then (local.set $colX (local.get $s)) (local.set $colZ (local.get $i)) (local.set $ly (local.get $j)))
                            (else (local.set $colX (local.get $i)) (local.set $colZ (local.get $s)) (local.set $ly (local.get $j))))))
                        (local.set $ch (i32.load16_u (i32.add (local.get $hp) (i32.shl (i32.add (local.get $colX) (i32.mul (local.get $colZ) (i32.const 16))) (i32.const 1)))))
                        (local.set $d (i32.sub (local.get $ch) (local.get $ly)))
                        (if (i32.lt_s (local.get $d) (i32.const 0)) (then (local.set $d (i32.const 0))))
                        (local.set $lf (f64.const 1.0))
                        (if (i32.lt_s (local.get $ch) (i32.const 28)) (then (local.set $lf (f64.const 0.75))))
                        ;; treesJS raises the heightmap over a canopy footprint to shade the
                        ;; leaves, but that raise must not darken the ground top faces under the
                        ;; tree (that baked patch is not the sun shadow). Depth shading still
                        ;; applies to leaf faces (canopy volume), all vertical faces (cliffs)
                        ;; and downward faces; upward-facing tops of non-leaf blocks are exempt.
                        (if (i32.or (i32.ne (local.get $dir) (local.get $law))
                                    (i32.eq (i32.load8_u (i32.add (local.get $bp) (local.get $bi))) (i32.const 7)))
                          (then
                            (local.set $lf (f64.mul (local.get $lf) (f64.max (f64.const 0.30) (f64.sub (f64.const 1.0) (f64.mul (f64.convert_i32_s (local.get $d)) (f64.const 0.10))))))))
                        (local.set $lb (i32.trunc_f64_s (f64.mul (local.get $lf) (f64.const 63.0))))
                        (local.set $code (i32.sub (i32.load8_u (i32.add (local.get $bp) (local.get $bi))) (i32.const 1)))
                        (if (i32.gt_s (i32.load8_u (i32.add (local.get $bp) (local.get $bi))) (i32.const 4))
                          (then (local.set $code (i32.sub (local.get $code) (i32.const 1)))))
                        (local.set $val (i32.or (i32.shl (local.get $lb) (i32.const 8)) (local.get $code)))))
                    (i32.store16 (i32.add (local.get $mask) (i32.shl (i32.add (local.get $j) (i32.mul (local.get $i) (local.get $hCnt))) (i32.const 1))) (local.get $val))
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br $mILoop)))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $mJLoop)))
        ;; ---- greedy scan ----
        (local.set $j (i32.const 0))
        (block $gJEnd
          (loop $gJLoop
            (br_if $gJEnd (i32.ge_s (local.get $j) (local.get $hCnt)))
            (local.set $i (i32.const 0))
            (block $gIEnd
              (loop $gILoop
                (br_if $gIEnd (i32.ge_s (local.get $i) (i32.const 16)))
                (local.set $val (i32.load16_u (i32.add (local.get $mask) (i32.shl (i32.add (local.get $j) (i32.mul (local.get $i) (local.get $hCnt))) (i32.const 1)))))
                (if (i32.eqz (local.get $val))
                  (then (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $gILoop)))
                ;; extend w2 along i
                (local.set $w2 (i32.const 1))
                (block $wEnd
                  (loop $wLoop
                    (if (i32.ge_s (i32.add (local.get $i) (local.get $w2)) (i32.const 16)) (then (br $wEnd)))
                    (if (i32.ne (i32.load16_u (i32.add (local.get $mask) (i32.shl (i32.add (local.get $j) (i32.mul (i32.add (local.get $i) (local.get $w2)) (local.get $hCnt))) (i32.const 1)))) (local.get $val)) (then (br $wEnd)))
                    (local.set $w2 (i32.add (local.get $w2) (i32.const 1)))
                    (br $wLoop)))
                ;; extend h2 along j (all cells equal)
                (local.set $h2 (i32.const 1))
                (block $hEnd
                  (loop $hLoop
                    (if (i32.ge_s (i32.add (local.get $j) (local.get $h2)) (local.get $hCnt)) (then (br $hEnd)))
                    (local.set $k (i32.const 0)) (local.set $mt (i32.const 0))
                    (block $kEnd
                      (loop $kLoop
                        (br_if $kEnd (i32.ge_s (local.get $k) (local.get $w2)))
                        (if (i32.ne (i32.load16_u (i32.add (local.get $mask) (i32.shl (i32.add (i32.add (local.get $j) (local.get $h2)) (i32.mul (i32.add (local.get $i) (local.get $k)) (local.get $hCnt))) (i32.const 1)))) (local.get $val)) (then (local.set $mt (i32.const 1)) (br $kEnd)))
                        (local.set $k (i32.add (local.get $k) (i32.const 1)))
                        (br $kLoop)))
                    (if (i32.ne (local.get $mt) (i32.const 0)) (then (br $hEnd)))
                    (local.set $h2 (i32.add (local.get $h2) (i32.const 1)))
                    (br $hLoop)))
                ;; quad corners: (i,j), (i1,j1), (i2,j2), (i+w2,j+h2) in mask
                ;; space. corner1/2 are swapped for +X, +Y, -Z so every face keeps
                ;; the pre-greedy mesher's winding (verified against its output).
                (local.set $iw (i32.add (local.get $i) (local.get $w2)))
                (local.set $jh (i32.add (local.get $j) (local.get $h2)))
                (local.set $flip (i32.or
                  (i32.and (i32.eq (local.get $axis) (i32.const 0)) (i32.eq (local.get $sg) (i32.const 1)))
                  (i32.or (i32.and (i32.eq (local.get $axis) (i32.const 1)) (i32.eq (local.get $sg) (i32.const 1)))
                          (i32.and (i32.eq (local.get $axis) (i32.const 2)) (i32.eqz (local.get $sg))))))
                (local.set $i1 (if (result i32) (local.get $flip) (then (local.get $i)) (else (local.get $iw))))
                (local.set $j1 (if (result i32) (local.get $flip) (then (local.get $jh)) (else (local.get $j))))
                (local.set $i2 (if (result i32) (local.get $flip) (then (local.get $iw)) (else (local.get $i))))
                (local.set $j2 (if (result i32) (local.get $flip) (then (local.get $j)) (else (local.get $jh))))
                ;; corner 0 = (i,j): AO samples -sA,-sB. The 12-byte scratch lives at $SCR
                (call $cornerGrid (local.get $axis) (local.get $sg) (local.get $s) (local.get $i) (local.get $j) (global.get $SCR))
                (local.set $cz0 (i32.load (i32.add (global.get $SCR) (i32.const 8))))
                (local.set $cy0 (i32.load (i32.add (global.get $SCR) (i32.const 4))))
                (local.set $cx0 (i32.load (global.get $SCR)))
                (local.set $a0 (call $cornerAO (local.get $bp)
                  (call $cellBi (local.get $bp) (local.get $axis) (local.get $s) (local.get $i) (local.get $j) (local.get $law) (local.get $lasl))
                  (local.get $dir) (local.get $sA) (local.get $sB) (i32.const -1) (i32.const -1)))
                ;; corner 1 = (i1,j1)
                (call $cornerGrid (local.get $axis) (local.get $sg) (local.get $s) (local.get $i1) (local.get $j1) (global.get $SCR))
                (local.set $cz1 (i32.load (i32.add (global.get $SCR) (i32.const 8))))
                (local.set $cy1 (i32.load (i32.add (global.get $SCR) (i32.const 4))))
                (local.set $cx1 (i32.load (global.get $SCR)))
                (local.set $a1 (call $cornerAO (local.get $bp)
                  (call $cellBi (local.get $bp) (local.get $axis) (local.get $s) (local.get $i1) (local.get $j1) (local.get $law) (local.get $lasl))
                  (local.get $dir) (local.get $sA) (local.get $sB)
                  (if (result i32) (local.get $flip) (then (i32.const -1)) (else (i32.const 1)))
                  (if (result i32) (local.get $flip) (then (i32.const 1)) (else (i32.const -1)))))
                ;; corner 2 = (i2,j2)
                (call $cornerGrid (local.get $axis) (local.get $sg) (local.get $s) (local.get $i2) (local.get $j2) (global.get $SCR))
                (local.set $cz2 (i32.load (i32.add (global.get $SCR) (i32.const 8))))
                (local.set $cy2 (i32.load (i32.add (global.get $SCR) (i32.const 4))))
                (local.set $cx2 (i32.load (global.get $SCR)))
                (local.set $a2 (call $cornerAO (local.get $bp)
                  (call $cellBi (local.get $bp) (local.get $axis) (local.get $s) (local.get $i2) (local.get $j2) (local.get $law) (local.get $lasl))
                  (local.get $dir) (local.get $sA) (local.get $sB)
                  (if (result i32) (local.get $flip) (then (i32.const 1)) (else (i32.const -1)))
                  (if (result i32) (local.get $flip) (then (i32.const -1)) (else (i32.const 1)))))
                ;; corner 3 = (i+w2,j+h2): AO samples +sA,+sB
                (call $cornerGrid (local.get $axis) (local.get $sg) (local.get $s) (local.get $iw) (local.get $jh) (global.get $SCR))
                (local.set $cz3 (i32.load (i32.add (global.get $SCR) (i32.const 8))))
                (local.set $cy3 (i32.load (i32.add (global.get $SCR) (i32.const 4))))
                (local.set $cx3 (i32.load (global.get $SCR)))
                (local.set $a3 (call $cornerAO (local.get $bp)
                  (call $cellBi (local.get $bp) (local.get $axis) (local.get $s) (local.get $iw) (local.get $jh) (local.get $law) (local.get $lasl))
                  (local.get $dir) (local.get $sA) (local.get $sB) (i32.const 1) (i32.const 1)))
                (call $emitQuad (local.get $vox) (local.get $idx) (local.get $out) (local.get $maxVox) (local.get $maxIdx)
                  (local.get $cx0) (local.get $cy0) (local.get $cz0)
                  (local.get $cx1) (local.get $cy1) (local.get $cz1)
                  (local.get $cx2) (local.get $cy2) (local.get $cz2)
                  (local.get $cx3) (local.get $cy3) (local.get $cz3)
                  (i32.and (local.get $val) (i32.const 255)) (local.get $norm) (i32.shr_u (local.get $val) (i32.const 8))
                  (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3))
                (if (i32.lt_s (i32.load (local.get $out)) (i32.const 0)) (then (return)))
                ;; zero the consumed mask cells
                (local.set $k (i32.const 0))
                (block $zEnd
                  (loop $zLoop
                    (br_if $zEnd (i32.ge_s (local.get $k) (local.get $w2)))
                    (local.set $k2 (i32.const 0))
                    (block $zJEnd
                      (loop $zJLoop
                        (br_if $zJEnd (i32.ge_s (local.get $k2) (local.get $h2)))
                        (i32.store16 (i32.add (local.get $mask) (i32.shl (i32.add (i32.add (local.get $j) (local.get $k2)) (i32.mul (i32.add (local.get $i) (local.get $k)) (local.get $hCnt))) (i32.const 1))) (i32.const 0))
                        (local.set $k2 (i32.add (local.get $k2) (i32.const 1)))
                        (br $zJLoop)))
                    (local.set $k (i32.add (local.get $k) (i32.const 1)))
                    (br $zLoop)))
                (local.set $i (i32.add (local.get $i) (local.get $w2)))
                (br $gILoop)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $gJLoop)))
        (local.set $s (i32.add (local.get $s) (i32.const 1)))
        (br $sLoop))))
  (func $meshChunk (export "meshChunk")
    (param $block i32) (param $height i32) (param $mask i32) (param $vox i32) (param $idx i32) (param $out i32) (param $maxVox i32) (param $maxIdx i32)
    (local $axis i32) (local $sg i32)
    (local $aw i32) (local $asl i32) (local $wh i32)
    (local.set $aw (global.get $AW)) (local.set $asl (global.get $ASL)) (local.set $wh (global.get $WH))
    (i32.store (local.get $out) (i32.const 0))
    (i32.store (i32.add (local.get $out) (i32.const 4)) (i32.const 0))
    (local.set $axis (i32.const 0))
    (block $aEnd
      (loop $aLoop
        (br_if $aEnd (i32.gt_s (local.get $axis) (i32.const 2)))
        (local.set $sg (i32.const 0))
        (block $sgEnd
          (loop $sgLoop
            (br_if $sgEnd (i32.gt_s (local.get $sg) (i32.const 1)))
            (call $greedyPass (local.get $block) (local.get $height) (local.get $mask)
              (local.get $axis) (local.get $sg)
              (local.get $vox) (local.get $idx) (local.get $out) (local.get $maxVox) (local.get $maxIdx)
              (local.get $aw) (local.get $asl) (local.get $wh))
            (if (i32.lt_s (i32.load (local.get $out)) (i32.const 0)) (then (return)))
            (local.set $sg (i32.add (local.get $sg) (i32.const 1)))
            (br $sgLoop)))
        (local.set $axis (i32.add (local.get $axis) (i32.const 1)))
        (br $aLoop))))
;; ============================================================================
;; water simulation kernel — virtual-pipe shallow-water solver (momentum).
;;
;; History: the original kernel was a first-order *diffusive* relaxation (it
;; moved a fraction of every surface gap toward the lower side, with no velocity
;; state). A depth-averaged flow with no momentum is a parabolic (heat/diffusion)
;; equation, so a disturbance smeared out instead of travelling: the water could
;; not slosh. This kernel keeps a persistent FLUX per cell edge and integrates it
;; as a damped spring driven by the surface (piezometric) head — the virtual-pipe
;; discretisation of Mei, Decaudin & Hu, "Fast Hydraulic Erosion Simulation and
;; Visualization on GPU", Pacific Graphics 2007 (DOI 10.1109/PG.2007.15) — which
;; is mass-conservative to machine precision and stable across wet/dry fronts.
;; The staggered (Arakawa C-grid) leapfrog that results propagates gravity waves
;; at c = sqrt(g*h) (D. Breslavskyi's analysis == linearised SWE), which is the
;; physics that was missing.
;;
;;   flux (owned edge, lower-coordinate cell owns it):
;;     fx[i] = discharge from cell i to cell i+1  (+x), fz[i] = i to i+18 (+z)
;;     f += dt * g * A_e * (surf_i - surf_j);  f *= damp
;;     A_e = min(0.5*(h_i + h_j), AMAX)   (AMAX bounds the wave speed for CFL)
;;     |f| <= Aq*sqrt(g*Aq), Aq = min(PIPE_DEPTH, 0.5*(h_i + h_j))  (the Froude-1
;;       discharge cap: a pipe may never carry more than its own gravity-wave
;;       (critical) flow. PIPE_DEPTH = 1.5 m is the deepest column this pass is
;;       asked to integrate, since the hybrid band-pass pins anything deeper than
;;       CLEAN_DEPTH = 2 m to the tide. See the long note at $edgeUpd.)
;;   per-cell outflow clamp (the wet/dry safety): scale every out-going pipe of a
;;     cell by s = min(1, (h + dt*inflow) / (dt*outflow)).
;;   height: h += dt * (inflow - outflow) + spring_tide
;;
;; DATA LAYOUT. Prefix is unchanged; the flux fields are appended, so the stride
;; grew 4552 -> 7144 B (0x11C8 -> 0x1BE8) and every existing field offset is
;; still valid (only the layout consts + the aux addresses moved):
;;   WATER_BASE 0x00520000 — SIM_SLOTS(1024) x 7144 B slots
;;     h f32[324] @+0, terr f32[324] @+1296, live i32[324] @+2592,
;;     marked u8[324] @+3888, inBand u8[324] @+4212,
;;     bandAt f64 @+4536, liveN i32 @+4544,
;;     fx f32[324] @+4552 (east flux), fz f32[324] @+5848 (south flux)
 ;;   (no PING buffer: the pass is in-place, it needs no ping-pong, and its old
 ;;   0x540000 home is now in the middle of WATER_BASE's slots)
;;   WATER_EDGE 0x00C20000 — [count i32 @0][slot i32,idx i32,d f64]*16B, cap 4096
;;   WATER_MAT  0x00C40000 — [count i32 @0][slot i32]*4B, cap 8192
;;   STRIP      0x00C50000 — f32[324] strip-net scratch for $waterStripPass
;; THE VIEW-DISTANCE PASS (§92) is the reason the three aux addresses above moved
;; and the module's initial memory grew 126 -> 200 pages (0x7E0000 -> 0xC80000):
;; 1024 slots end at 0xC1A000, so the aux blocks had to shift up behind them. The
;; kernel LOGIC is untouched — only the slot count, the three literals and the
;; memory minimum changed, so the gate still compares byte-for-byte against the
;; rebuilt binary (the addresses are literals, not relocations; wabt resolves
;; them at compile time and `kernel-gate.mjs` pins the result).
;; All flow math is f64; values round to f32 only where they are stored.
;; ============================================================================

(func $wBase (param $slot i32) (result i32)
  (i32.add (i32.const 0x00520000) (i32.mul (local.get $slot) (i32.const 0x1BE8))))

;; der(i) = max(0, lb - terr[i]) — the derived/tide-following water depth
(func $der (param $b i32) (param $i i32) (param $lb f64) (result f64)
  (f64.max (f64.const 0.0) (f64.sub (local.get $lb)
    (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 1296)) (i32.mul (local.get $i) (i32.const 4))))))))

;; stage a "materialize" event: the JS host flips rest=false + dirty=true
(func $pushMat (param $slot i32)
  (local $c i32)
  (local.set $c (i32.load (i32.const 0x00C40000)))
  (if (i32.lt_u (local.get $c) (i32.const 8192))
    (then
      (i32.store
        (i32.add (i32.const 0x00C40000) (i32.add (i32.const 4) (i32.mul (local.get $c) (i32.const 4))))
        (local.get $slot))
      (i32.store
        (i32.const 0x00C40000)
        (i32.add (local.get $c) (i32.const 1))))))

;; stage a cross-chunk edge (slot, idx, d) for the JS edge-apply loop
(func $pushEdge (param $slot i32) (param $idx i32) (param $d f64)
  (local $c i32) (local $base i32)
  (local.set $c (i32.load (i32.const 0x00C20000)))
  (if (i32.lt_u (local.get $c) (i32.const 4096))
    (then
      (local.set $base
        (i32.add (i32.const 0x00C20000) (i32.add (i32.const 4) (i32.mul (local.get $c) (i32.const 16)))))
      (i32.store (local.get $base) (local.get $slot))
      (i32.store (i32.add (local.get $base) (i32.const 4)) (local.get $idx))
      (f64.store (i32.add (local.get $base) (i32.const 8)) (local.get $d))
      (i32.store
        (i32.const 0x00C20000)
        (i32.add (local.get $c) (i32.const 1))))))

;; ---- flux field accessors (element index i; fx @+4552, fz @+5848) ----
(func $ldFx (param $b i32) (param $i i32) (result f64)
  (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 4552)) (i32.mul (local.get $i) (i32.const 4))))))
(func $stFx (param $b i32) (param $i i32) (param $v f64)
  (f32.store (i32.add (i32.add (local.get $b) (i32.const 4552)) (i32.mul (local.get $i) (i32.const 4))) (f32.demote_f64 (local.get $v))))
(func $ldFz (param $b i32) (param $i i32) (result f64)
  (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 5848)) (i32.mul (local.get $i) (i32.const 4))))))
(func $stFz (param $b i32) (param $i i32) (param $v f64)
  (f32.store (i32.add (i32.add (local.get $b) (i32.const 5848)) (i32.mul (local.get $i) (i32.const 4))) (f32.demote_f64 (local.get $v))))
(func $isLive (param $b i32) (param $i i32) (result i32)
  (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 3888)) (local.get $i))))

;; _materialize: h = max(0, lb - terr) for all cells, unmark the live set, liveN
;; = 0, zero the flux field (a materialized chunk is at derived rest), push event.
(func $materialize (export "waterMaterialize") (param $slot i32) (param $lb f64)
  (local $b i32) (local $i i32) (local $n i32)
  (local.set $b (call $wBase (local.get $slot)))
  (local.set $i (i32.const 0))
  (block $mEnd (loop $mLoop
    (br_if $mEnd (i32.ge_s (local.get $i) (i32.const 324)))
    (f32.store (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))
      (f32.demote_f64 (call $der (local.get $b) (local.get $i) (local.get $lb))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $mLoop)))
  (local.set $n (i32.load (i32.add (local.get $b) (i32.const 4544))))
  (local.set $i (i32.const 0))
  (block $cEnd (loop $cLoop
    (br_if $cEnd (i32.ge_s (local.get $i) (local.get $n)))
    (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 3888))
      (i32.load (i32.add (i32.add (local.get $b) (i32.const 2592)) (i32.mul (local.get $i) (i32.const 4))))) (i32.const 0))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $cLoop)))
  (i32.store (i32.add (local.get $b) (i32.const 4544)) (i32.const 0))
  (memory.fill (i32.add (local.get $b) (i32.const 4552)) (i32.const 0) (i32.const 1296))
  (memory.fill (i32.add (local.get $b) (i32.const 5848)) (i32.const 0) (i32.const 1296))
  (call $pushMat (local.get $slot)))

;; _markLive: if !marked[i] { snap h[i]=der when snap; marked[i]=1; live[liveN++]=i }
(func $markLive (param $b i32) (param $i i32) (param $snap i32) (param $lb f64)
  (if (i32.eqz (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 3888)) (local.get $i)))) (then
    (if (local.get $snap) (then
      (f32.store (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))
        (f32.demote_f64 (call $der (local.get $b) (local.get $i) (local.get $lb))))))
    (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 3888)) (local.get $i)) (i32.const 1))
    (i32.store (i32.add (i32.add (local.get $b) (i32.const 2592))
      (i32.mul (i32.load (i32.add (local.get $b) (i32.const 4544))) (i32.const 4))) (local.get $i))
    (i32.store (i32.add (local.get $b) (i32.const 4544))
      (i32.add (i32.load (i32.add (local.get $b) (i32.const 4544))) (i32.const 1))))))

;; one owned edge: f_off[i] += dt*g*A_e*(surf_i - surf_nb), then damping.
;; $off is 4552 (east/fx) or 5848 (south/fz). Neighbour may live in another slot
;; ($nb/$nid), which is how cross-chunk edges read the true neighbour depth.
(func $edgeUpd (param $b i32) (param $i i32) (param $nb i32) (param $nid i32) (param $off i32)
                (param $lb f64) (param $dt f64)
  (local $si f64) (local $sn f64) (local $hi f64) (local $hn f64) (local $ae f64) (local $f f64)
  (local $ho f64) (local $hs f64) (local $qa f64) (local $qmax f64)
  (local.set $hi (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4))))))
  (local.set $si (f64.add (local.get $hi) (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 1296)) (i32.mul (local.get $i) (i32.const 4)))))))
  (local.set $hn (if (result f64) (call $isLive (local.get $nb) (local.get $nid))
    (then (f64.promote_f32 (f32.load (i32.add (local.get $nb) (i32.mul (local.get $nid) (i32.const 4))))))
    (else (call $der (local.get $nb) (local.get $nid) (local.get $lb)))))
  (local.set $sn (f64.add (local.get $hn) (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $nb) (i32.const 1296)) (i32.mul (local.get $nid) (i32.const 4)))))))
  ;; Pipe cross-section A = mean wetted depth (a 1 m wide pipe), capped at 3.3 m
  ;; so the gravity-wave speed sqrt(g*A) tops out at 10.33 m/s and the symplectic
  ;; pair below (flux from the OLD surfaces, then depth from the NEW flux) stays
  ;; inside its CFL bound dt <= 1/sqrt(g*A_max) = 96.8 ms, against a simDt <= 60 ms.
  ;; The lower clamp at zero is not cosmetic, and it is the whole reason this
  ;; line is written the long way: a cell whose depth has been driven slightly
  ;; NEGATIVE by a boundary transfer (the cross-chunk and strip paths write the
  ;; neighbour's depth unpacked, since the packing lives in JS) hands the edge a
  ;; NEGATIVE stiffness. The neutral (unit-modulus) stability of the pair then
  ;; becomes anti-damping — the root modulus grows like dt*sqrt(g*|A|) per
  ;; substep — so the field doubles roughly every tick, reaches float overflow in
  ;; a few seconds, and the critters standing on it are flung until the swept
  ;; AABB body sweep burns a frame per step. A depth is a depth: below the bed
  ;; there is no pipe. (Mei, Decaudin & Hu, PG 2007, sec. 4.1 — the outflow clamp
  ;; keeps LIVE cells' depth non-negative, but it is per-cell, so it cannot see a
  ;; depth that a cross-chunk write made negative.)
  (local.set $ae (f64.min (f64.const 10.89)
    (f64.max (f64.const 0.0) (f64.mul (f64.const 0.5) (f64.add (local.get $hi) (local.get $hn))))))
  (local.set $f (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (local.get $off)) (i32.mul (local.get $i) (i32.const 4))))))
  (local.set $f (f64.mul (f64.add (local.get $f)
    (f64.mul (f64.mul (f64.mul (f64.const 9.8) (local.get $dt)) (local.get $ae))
             (f64.sub (local.get $si) (local.get $sn)))) (f64.const 0.999)))
  ;; EVERY edge is a pipe, and a pipe cannot move water that is not there. The
  ;; surface difference across a wet/dry interface is the standard shallow-water
  ;; bed-as-surface treatment — it is how water climbs a beach — but it must never
  ;; drive a flux OUT of a column that holds no water. The column just outside the
  ;; band has der = 0 and h = 0, and its "surface" is its terrain: a wall, not a
  ;; lake. Mei's outflow clamp (phase 2) bounds a LIVE cell's total donation, but it
  ;; iterates the live list, so a pinned (derived) donor is invisible to it — the
  ;; receiving cell collected dt*f and the donor's credit max(0, h - dt*f) silently
  ;; absorbed the shortfall at zero, i.e. out of nothing. This loop closes that hole
  ;; at the pipe itself, which needs no list bookkeeping and is therefore exact for
  ;; every caller: the flux may not exceed the donor's active depth over one
  ;; substep. The active depth is h when the donor is LIVE and der = max(0, lb -
  ;; terr) when it is derived; we take the smaller of that and its stored h, because
  ;; a derived column's stored h is a bookkeeping leftover and is never more water
  ;; than the tide model gave it. Legitimate flow is orders of magnitude below the
  ;; limit (a 1 m head across a 10 m deep ocean needs f = 0.59 against a budget of
  ;; 167), so this only ever bites where the pipe model would otherwise have had to
  ;; invent the water. (Mei, Decaudin & Hu, PG 2007, sec. 4.1 — this is that clamp,
  ;; derived per pipe instead of per cell; cf. Bates et al., "A simple raster-based
  ;; model for flood inundation simulation", J. Hydrology 236 (2000), which bounds
  ;; the wet/dry interface flux the same way.)
  (local.set $ho (if (result f64) (call $isLive (local.get $b) (local.get $i))
    (then (local.get $hi)) (else (call $der (local.get $b) (local.get $i) (local.get $lb)))))
  (local.set $ho (f64.min (local.get $ho) (local.get $hi)))
  (local.set $hs (f64.min (local.get $hn)
    (f64.promote_f32 (f32.load (i32.add (local.get $nb) (i32.mul (local.get $nid) (i32.const 4)))))))
  (local.set $f (if (result f64) (f64.gt (local.get $f) (f64.const 0.0))
    (then (f64.min (local.get $f) (f64.div (local.get $ho) (local.get $dt))))
    (else (f64.neg (f64.min (f64.neg (local.get $f)) (f64.div (local.get $hs) (local.get $dt)))))))
  ;; ---- celerity (Froude) cap on the discharge ------------------------------
  ;; Everything above bounds how much VOLUME a pipe may move per substep, and
  ;; that bound does not care how fast the water thinks it is going. So the
  ;; integrated discharge is still free to run away: at a wet/dry face the
  ;; "surface" of the dry side is its BED (the standard bed-as-surface treatment
  ;; invoked above), which turns a one-block terrain step into a metre of head
  ;; that no water is holding, and the symplectic pair then integrates that fake
  ;; head as real momentum for as long as the 0.999 damping lets it - a thousand
  ;; substeps. Measured: after ~300 ticks a chunk-boundary face carried |q| = 75
  ;; m^2/s into a 3 m column, i.e. 7.5 m^3/s/m through one cell face, and drained
  ;; that column to exactly zero, which the mesher dutifully drew as a 3 m
  ;; vertical wall of water standing in the sea. None of that flux is physical: a
  ;; pipe of cross-section A carries at most the gravity-wave (critical, Froude =
  ;; 1) discharge A*sqrt(g*A) - 15 m^2/s for the pipe that misbehaved, five times
  ;; smaller than what the integrator had reached. So it was not a marginal
  ;; overshoot; it was a factor-five violation of the signal speed the scheme
  ;; itself propagates at, which is the one thing a difference scheme may never
  ;; do (Courant, Friedrichs & Lewy 1928: information travels no faster than the
  ;; fastest characteristic - here sqrt(g*A)). The cap also makes the CFL margin
  ;; structural instead of incidental: with A capped at PIPE_DEPTH = 1.5 m the
  ;; celerity tops out at sqrt(9.8*1.5) = 3.83 m/s, i.e. dt <= 0.26 s against a
  ;; simDt <= 60 ms, and no pipe may move more than dt*A*sqrt(g*A) = 0.35 blocks
  ;; in one substep - under a fifth of the shallowest live column - so an
  ;; oscillating wet/dry front cannot swap its whole contents and ring. 1.5 m is
  ;; the depth scale this pass is actually asked to integrate: the hybrid
  ;; band-pass pins any column deeper than CLEAN_DEPTH = 2 m to its tide-derived
  ;; depth (the tide model holds that water, not this pass), so a pipe below that
  ;; is asking the integrator to carry water it deliberately does not simulate.
  ;; (Bates, Horritt & Fewtrell 2010, "A simple inertial formulation of the
  ;; shallow water equations for efficient two-dimensional flood inundation
  ;; modelling", J. Hydrology 387:33-45 - the local-inertial scheme caps its face
  ;; flux by the celerity for exactly this reason. Verified in the offline replay:
  ;; the seam artefact's |e| falls 4.82 -> 0.22 blocks and its wall pairs 8 -> 0
  ;; over 1500 ticks, while a closed 18x18 tank carrying a standing wave still
  ;; reproduces its analytic period bit-identically with the cap in place - 135.5
  ;; vs 134.9 ticks for the 1-D fundamental, 95.5 vs 95.4 for the 2-D (1,1) mode.)
  (local.set $qa (f64.max (f64.const 0.0) (f64.min (f64.const 1.5)
    (f64.mul (f64.const 0.5) (f64.add (local.get $hi) (local.get $hn))))))
  (local.set $qmax (f64.mul (local.get $qa) (f64.sqrt (f64.mul (f64.const 9.8) (local.get $qa)))))
  (local.set $f (f64.max (f64.neg (local.get $qmax)) (f64.min (local.get $qmax) (local.get $f))))
  (f32.store (i32.add (i32.add (local.get $b) (local.get $off)) (i32.mul (local.get $i) (i32.const 4))) (f32.demote_f64 (local.get $f))))

;; per-cell outflow clamp (Mei et al. 2007): scale the out-going pipes so the
;; cell cannot donate more than (h + dt*inflow). Cross-cell out-flows (the west
;; edge owned by the west neighbour, the north edge by the north neighbour) are
;; scaled in place too; clamping only ever *reduces* flux, so the Jacobi-style
;; order dependence is harmless.
(func $clampCell (param $b i32) (param $i i32) (param $col i32) (param $row i32) (param $dt f64)
  (local $h f64) (local $in f64) (local $out f64) (local $av f64) (local $s f64)
  (local $fxl f64) (local $fxr f64) (local $fzn f64) (local $fzs f64)
  (local.set $fxl (if (result f64) (i32.gt_s (local.get $col) (i32.const 1)) (then (call $ldFx (local.get $b) (i32.sub (local.get $i) (i32.const 1)))) (else (f64.const 0.0))))
  (local.set $fxr (call $ldFx (local.get $b) (local.get $i)))
  (local.set $fzn (if (result f64) (i32.gt_s (local.get $row) (i32.const 1)) (then (call $ldFz (local.get $b) (i32.sub (local.get $i) (i32.const 18)))) (else (f64.const 0.0))))
  (local.set $fzs (if (result f64) (i32.lt_s (local.get $col) (i32.const 17)) (then (call $ldFz (local.get $b) (local.get $i))) (else (f64.const 0.0))))
  (local.set $in (f64.add (f64.add (f64.max (local.get $fxl) (f64.const 0.0)) (f64.max (f64.neg (local.get $fxr)) (f64.const 0.0)))
                         (f64.add (f64.max (local.get $fzn) (f64.const 0.0)) (f64.max (f64.neg (local.get $fzs)) (f64.const 0.0)))))
  (local.set $out (f64.add (f64.add (f64.max (f64.neg (local.get $fxl)) (f64.const 0.0)) (f64.max (local.get $fxr) (f64.const 0.0)))
                          (f64.add (f64.max (f64.neg (local.get $fzn)) (f64.const 0.0)) (f64.max (local.get $fzs) (f64.const 0.0)))))
  (local.set $h (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4))))))
  (local.set $av (f64.add (local.get $h) (f64.mul (local.get $dt) (local.get $in))))
  (if (f64.gt (f64.mul (local.get $dt) (local.get $out)) (local.get $av)) (then
    (local.set $s (if (result f64) (f64.gt (local.get $av) (f64.const 0.0))
      (then (f64.div (local.get $av) (f64.mul (local.get $dt) (local.get $out)))) (else (f64.const 0.0))))
    (if (f64.gt (local.get $fxr) (f64.const 0.0)) (then (call $stFx (local.get $b) (local.get $i) (f64.mul (local.get $fxr) (local.get $s)))))
    (if (f64.lt (local.get $fxl) (f64.const 0.0)) (then (call $stFx (local.get $b) (i32.sub (local.get $i) (i32.const 1)) (f64.mul (local.get $fxl) (local.get $s)))))
    (if (f64.gt (local.get $fzs) (f64.const 0.0)) (then (call $stFz (local.get $b) (local.get $i) (f64.mul (local.get $fzs) (local.get $s)))))
    (if (f64.lt (local.get $fzn) (f64.const 0.0)) (then (call $stFz (local.get $b) (i32.sub (local.get $i) (i32.const 18)) (f64.mul (local.get $fzn) (local.get $s))))))))

;; stage one cross-chunk edge (volume d) to the neighbour slot; materialize the
;; neighbour when it was REST and the flow is real, mirroring the old pass. The
;; updated REST flag is returned (staged in a mutable local by the caller).
(func $stageCross (param $nbSlot i32) (param $nIdx i32) (param $restIn i32) (param $d f64) (param $lb f64) (result i32)
  (if (local.get $restIn) (then
    (if (f64.le (f64.abs (local.get $d)) (f64.const 0.0001))
      (then (return (local.get $restIn)))
      (else (call $materialize (local.get $nbSlot) (local.get $lb))
            (local.set $restIn (i32.const 0))))))
  (call $pushEdge (local.get $nbSlot) (local.get $nIdx) (local.get $d))
  (local.get $restIn))

;; one momentum substep over a DIRTY chunk (JS _caPass).
(func $waterCaPass (export "waterCaPass")
  (param $slot i32) (param $east i32) (param $south i32)
  (param $eastRest i32) (param $southRest i32)
  (param $lb f64) (param $base f64) (param $spring f64) (param $dt f64)
  (local $b i32) (local $i i32) (local $li i32) (local $nStart i32) (local $liven i32) (local $w i32)
  (local $col i32) (local $row i32) (local $er i32) (local $sr i32)
  (local $lz i32) (local $lx i32) (local $nw f64) (local $inb i32)
  (local $hSrc f64) (local $fxl f64) (local $fxr f64) (local $fzn f64) (local $fzs f64)
  (local $net f64) (local $target f64) (local $diff f64) (local $hNew f64)
  (local $nb i32) (local $ni i32) (local $d f64)
  (local.set $er (local.get $eastRest))
  (local.set $sr (local.get $southRest))
  (local.set $b (call $wBase (local.get $slot)))
  ;; _bandScan: interior cells within BAND of lb become live (snapped to derived)
  (if (f64.ge (f64.abs (f64.sub (local.get $lb) (f64.load (i32.add (local.get $b) (i32.const 4536))))) (f64.const 0.375)) (then
    (local.set $lz (i32.const 1))
    (block $bsEnd (loop $bsLoop
      (br_if $bsEnd (i32.ge_s (local.get $lz) (i32.const 17)))
      (local.set $lx (i32.const 1))
      (block $bs2End (loop $bs2Loop
        (br_if $bs2End (i32.ge_s (local.get $lx) (i32.const 17)))
        (local.set $i (i32.add (local.get $lx) (i32.mul (local.get $lz) (i32.const 18))))
        (local.set $nw (f64.sub (local.get $lb) (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 1296)) (i32.mul (local.get $i) (i32.const 4)))))))
        (local.set $inb (i32.const 0))
        (if (f64.gt (local.get $nw) (f64.const -1.5)) (then
          (if (f64.lt (local.get $nw) (f64.const 1.5)) (then (local.set $inb (i32.const 1))))))
        (if (i32.and (local.get $inb) (i32.eqz (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4212)) (local.get $i))))) (then
          (call $markLive (local.get $b) (local.get $i) (i32.const 1) (local.get $lb))))
        (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 4212)) (local.get $i)) (local.get $inb))
        (local.set $lx (i32.add (local.get $lx) (i32.const 1)))
        (br $bs2Loop)))
      (local.set $lz (i32.add (local.get $lz) (i32.const 1)))
      (br $bsLoop)))
    (f64.store (i32.add (local.get $b) (i32.const 4536)) (local.get $lb))))
  (local.set $nStart (i32.load (i32.add (local.get $b) (i32.const 4544))))
  ;; ---- phase 1: owned-edge flux updates (+ edges owned by pinned neighbours) ----
  (local.set $li (i32.const 0))
  (block $fEnd (loop $fLoop
    (br_if $fEnd (i32.ge_s (local.get $li) (local.get $nStart)))
    (local.set $i (i32.load (i32.add (i32.add (local.get $b) (i32.const 2592)) (i32.mul (local.get $li) (i32.const 4)))))
    (local.set $col (i32.rem_s (local.get $i) (i32.const 18)))
    (local.set $row (i32.div_s (local.get $i) (i32.const 18)))
    ;; east / fx
    (if (i32.lt_s (local.get $col) (i32.const 16)) (then
      (call $edgeUpd (local.get $b) (local.get $i) (local.get $b) (i32.add (local.get $i) (i32.const 1)) (i32.const 4552) (local.get $lb) (local.get $dt)))
      (else
      (if (i32.ge_s (local.get $east) (i32.const 0)) (then
        (call $edgeUpd (local.get $b) (local.get $i) (call $wBase (local.get $east)) (i32.add (i32.const 1) (i32.mul (local.get $row) (i32.const 18))) (i32.const 4552) (local.get $lb) (local.get $dt)))
        (else (call $stFx (local.get $b) (local.get $i) (f64.const 0.0))))))
    ;; south / fz
    (if (i32.lt_s (local.get $row) (i32.const 16)) (then
      (call $edgeUpd (local.get $b) (local.get $i) (local.get $b) (i32.add (local.get $i) (i32.const 18)) (i32.const 5848) (local.get $lb) (local.get $dt)))
      (else
      (if (i32.ge_s (local.get $south) (i32.const 0)) (then
        (call $edgeUpd (local.get $b) (local.get $i) (call $wBase (local.get $south)) (i32.add (local.get $col) (i32.const 18)) (i32.const 5848) (local.get $lb) (local.get $dt)))
        (else (call $stFz (local.get $b) (local.get $i) (f64.const 0.0))))))
    ;; west edge owned by a pinned west neighbour
    (if (i32.and (i32.gt_s (local.get $col) (i32.const 1)) (i32.eqz (call $isLive (local.get $b) (i32.sub (local.get $i) (i32.const 1))))) (then
      (call $edgeUpd (local.get $b) (i32.sub (local.get $i) (i32.const 1)) (local.get $b) (local.get $i) (i32.const 4552) (local.get $lb) (local.get $dt))))
    ;; north edge owned by a pinned north neighbour
    (if (i32.and (i32.gt_s (local.get $row) (i32.const 1)) (i32.eqz (call $isLive (local.get $b) (i32.sub (local.get $i) (i32.const 18))))) (then
      (call $edgeUpd (local.get $b) (i32.sub (local.get $i) (i32.const 18)) (local.get $b) (local.get $i) (i32.const 5848) (local.get $lb) (local.get $dt))))
    (local.set $li (i32.add (local.get $li) (i32.const 1)))
    (br $fLoop)))
  ;; ---- phase 2: outflow clamp ----
  (local.set $li (i32.const 0))
  (block $cEnd (loop $cLoop
    (br_if $cEnd (i32.ge_s (local.get $li) (local.get $nStart)))
    (local.set $i (i32.load (i32.add (i32.add (local.get $b) (i32.const 2592)) (i32.mul (local.get $li) (i32.const 4)))))
    (call $clampCell (local.get $b) (local.get $i) (i32.rem_s (local.get $i) (i32.const 18)) (i32.div_s (local.get $i) (i32.const 18)) (local.get $dt))
    (local.set $li (i32.add (local.get $li) (i32.const 1)))
    (br $cLoop)))
  ;; ---- phase 3: height update; credit pinned neighbours; stage cross-chunk ----
  (local.set $li (i32.const 0))
  (block $hEnd (loop $hLoop
    (br_if $hEnd (i32.ge_s (local.get $li) (local.get $nStart)))
    (local.set $i (i32.load (i32.add (i32.add (local.get $b) (i32.const 2592)) (i32.mul (local.get $li) (i32.const 4)))))
    (local.set $col (i32.rem_s (local.get $i) (i32.const 18)))
    (local.set $row (i32.div_s (local.get $i) (i32.const 18)))
    (local.set $fxl (if (result f64) (i32.gt_s (local.get $col) (i32.const 1)) (then (call $ldFx (local.get $b) (i32.sub (local.get $i) (i32.const 1)))) (else (f64.const 0.0))))
    (local.set $fxr (call $ldFx (local.get $b) (local.get $i)))
    (local.set $fzn (if (result f64) (i32.gt_s (local.get $row) (i32.const 1)) (then (call $ldFz (local.get $b) (i32.sub (local.get $i) (i32.const 18)))) (else (f64.const 0.0))))
    (local.set $fzs (call $ldFz (local.get $b) (local.get $i)))
    (local.set $hSrc (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4))))))
    (local.set $net (f64.add (f64.sub (local.get $fxl) (local.get $fxr)) (f64.sub (local.get $fzn) (local.get $fzs))))
    (local.set $target (f64.sub (local.get $base) (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 1296)) (i32.mul (local.get $i) (i32.const 4)))))))
    (local.set $hNew (f64.add (local.get $hSrc) (f64.mul (local.get $dt) (local.get $net))))
    (if (f64.gt (local.get $target) (f64.const 0.0)) (then
      (if (f64.gt (local.get $hSrc) (f64.const 0.0))
        (then (local.set $hNew (f64.add (local.get $hNew) (f64.mul (f64.sub (local.get $target) (local.get $hSrc)) (local.get $spring)))))
        (else (local.set $hNew (f64.add (local.get $hNew) (f64.mul (f64.neg (local.get $hSrc)) (local.get $spring))))))))
    (if (f64.lt (local.get $hNew) (f64.const 0.0)) (then (local.set $hNew (f64.const 0.0))))
    (f32.store (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4))) (f32.demote_f64 (local.get $hNew)))
    ;; credit/debit pinned in-chunk neighbours (live ones self-account)
    (if (i32.and (i32.lt_s (local.get $col) (i32.const 16)) (i32.eqz (call $isLive (local.get $b) (i32.add (local.get $i) (i32.const 1))))) (then
      (f32.store (i32.add (local.get $b) (i32.mul (i32.add (local.get $i) (i32.const 1)) (i32.const 4)))
        (f32.demote_f64 (f64.max (f64.const 0.0) (f64.add (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (i32.add (local.get $i) (i32.const 1)) (i32.const 4))))) (f64.mul (local.get $fxr) (local.get $dt))))))))
    (if (i32.and (i32.lt_s (local.get $row) (i32.const 16)) (i32.eqz (call $isLive (local.get $b) (i32.add (local.get $i) (i32.const 18))))) (then
      (f32.store (i32.add (local.get $b) (i32.mul (i32.add (local.get $i) (i32.const 18)) (i32.const 4)))
        (f32.demote_f64 (f64.max (f64.const 0.0) (f64.add (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (i32.add (local.get $i) (i32.const 18)) (i32.const 4))))) (f64.mul (local.get $fzs) (local.get $dt))))))))
    (if (i32.and (i32.gt_s (local.get $col) (i32.const 1)) (i32.eqz (call $isLive (local.get $b) (i32.sub (local.get $i) (i32.const 1))))) (then
      (f32.store (i32.add (local.get $b) (i32.mul (i32.sub (local.get $i) (i32.const 1)) (i32.const 4)))
        (f32.demote_f64 (f64.max (f64.const 0.0) (f64.add (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (i32.sub (local.get $i) (i32.const 1)) (i32.const 4))))) (f64.mul (f64.neg (local.get $fxl)) (local.get $dt))))))))
    (if (i32.and (i32.gt_s (local.get $row) (i32.const 1)) (i32.eqz (call $isLive (local.get $b) (i32.sub (local.get $i) (i32.const 18))))) (then
      (f32.store (i32.add (local.get $b) (i32.mul (i32.sub (local.get $i) (i32.const 18)) (i32.const 4)))
        (f32.demote_f64 (f64.max (f64.const 0.0) (f64.add (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (i32.sub (local.get $i) (i32.const 18)) (i32.const 4))))) (f64.mul (f64.neg (local.get $fzn)) (local.get $dt))))))))
    ;; cross-chunk staging (post-clamp volumes)
    (if (i32.and (i32.eq (local.get $col) (i32.const 16)) (i32.ge_s (local.get $east) (i32.const 0))) (then
      (local.set $er (call $stageCross (local.get $east) (i32.add (i32.const 1) (i32.mul (local.get $row) (i32.const 18))) (local.get $er) (f64.mul (local.get $fxr) (local.get $dt)) (local.get $lb)))))
    (if (i32.and (i32.eq (local.get $row) (i32.const 16)) (i32.ge_s (local.get $south) (i32.const 0))) (then
      (local.set $sr (call $stageCross (local.get $south) (i32.add (local.get $col) (i32.const 18)) (local.get $sr) (f64.mul (local.get $fzs) (local.get $dt)) (local.get $lb)))))
    (local.set $li (i32.add (local.get $li) (i32.const 1)))
    (br $hLoop)))
  ;; ---- phase 4: wake pinned neighbours that received real flow ----
  (local.set $li (i32.const 0))
  (block $wEnd (loop $wLoop
    (br_if $wEnd (i32.ge_s (local.get $li) (local.get $nStart)))
    (local.set $i (i32.load (i32.add (i32.add (local.get $b) (i32.const 2592)) (i32.mul (local.get $li) (i32.const 4)))))
    (local.set $col (i32.rem_s (local.get $i) (i32.const 18)))
    (local.set $row (i32.div_s (local.get $i) (i32.const 18)))
    (if (i32.and (i32.lt_s (local.get $col) (i32.const 16)) (i32.eqz (call $isLive (local.get $b) (i32.add (local.get $i) (i32.const 1))))) (then
      (if (f64.gt (f64.abs (f64.mul (call $ldFx (local.get $b) (local.get $i)) (local.get $dt))) (f64.const 0.001))
        (then (call $markLive (local.get $b) (i32.add (local.get $i) (i32.const 1)) (i32.const 0) (local.get $lb))))))
    (if (i32.and (i32.lt_s (local.get $row) (i32.const 16)) (i32.eqz (call $isLive (local.get $b) (i32.add (local.get $i) (i32.const 18))))) (then
      (if (f64.gt (f64.abs (f64.mul (call $ldFz (local.get $b) (local.get $i)) (local.get $dt))) (f64.const 0.001))
        (then (call $markLive (local.get $b) (i32.add (local.get $i) (i32.const 18)) (i32.const 0) (local.get $lb))))))
    (if (i32.and (i32.gt_s (local.get $col) (i32.const 1)) (i32.eqz (call $isLive (local.get $b) (i32.sub (local.get $i) (i32.const 1))))) (then
      (if (f64.gt (f64.abs (f64.mul (call $ldFx (local.get $b) (i32.sub (local.get $i) (i32.const 1))) (local.get $dt))) (f64.const 0.001))
        (then (call $markLive (local.get $b) (i32.sub (local.get $i) (i32.const 1)) (i32.const 0) (local.get $lb))))))
    (if (i32.and (i32.gt_s (local.get $row) (i32.const 1)) (i32.eqz (call $isLive (local.get $b) (i32.sub (local.get $i) (i32.const 18))))) (then
      (if (f64.gt (f64.abs (f64.mul (call $ldFz (local.get $b) (i32.sub (local.get $i) (i32.const 18))) (local.get $dt))) (f64.const 0.001))
        (then (call $markLive (local.get $b) (i32.sub (local.get $i) (i32.const 18)) (i32.const 0) (local.get $lb))))))
    (local.set $li (i32.add (local.get $li) (i32.const 1)))
    (br $wLoop)))
  ;; ---- settle-shrink: non-band live cells within WAKE of derived snap back to
  ;; pinned (their owned flux is zeroed), and the live list is compacted in place ----
  (local.set $liven (i32.load (i32.add (local.get $b) (i32.const 4544))))
  (local.set $w (i32.const 0))
  (local.set $li (i32.const 0))
  (block $ssEnd (loop $ssLoop
    (br_if $ssEnd (i32.ge_s (local.get $li) (local.get $liven)))
    (local.set $i (i32.load (i32.add (i32.add (local.get $b) (i32.const 2592)) (i32.mul (local.get $li) (i32.const 4)))))
    (if (i32.eqz (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4212)) (local.get $i)))) (then
      (local.set $diff (f64.sub (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))))
        (call $der (local.get $b) (local.get $i) (local.get $lb))))
      (if (i32.and (f64.le (f64.abs (local.get $diff)) (f64.const 0.001)) (i32.and (f64.le (f64.abs (call $ldFx (local.get $b) (local.get $i))) (f64.const 0.02)) (f64.le (f64.abs (call $ldFz (local.get $b) (local.get $i))) (f64.const 0.02)))) (then
        (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 3888)) (local.get $i)) (i32.const 0))
        (f32.store (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))
          (f32.demote_f64 (call $der (local.get $b) (local.get $i) (local.get $lb))))
        (call $stFx (local.get $b) (local.get $i) (f64.const 0.0))
        (call $stFz (local.get $b) (local.get $i) (f64.const 0.0)))
        (else
        (if (i32.ne (local.get $w) (local.get $li)) (then
          (i32.store (i32.add (i32.add (local.get $b) (i32.const 2592)) (i32.mul (local.get $w) (i32.const 4))) (local.get $i))))
        (local.set $w (i32.add (local.get $w) (i32.const 1))))))
      (else
      (if (i32.ne (local.get $w) (local.get $li)) (then
        (i32.store (i32.add (i32.add (local.get $b) (i32.const 2592)) (i32.mul (local.get $w) (i32.const 4))) (local.get $i))))
      (local.set $w (i32.add (local.get $w) (i32.const 1)))))
    (local.set $li (i32.add (local.get $li) (i32.const 1)))
    (br $ssLoop)))
  (i32.store (i32.add (local.get $b) (i32.const 4544)) (local.get $w)))

;; cross-chunk flow for PINNED (non-live) owned boundary cells of a dirty chunk
;; (JS _pinnedStrips). Never materializes — the edge-apply loop handles REST
;; neighbors later. Unchanged from the pre-momentum kernel except the aux base.
(func $waterPinnedStrips (export "waterPinnedStrips")
  (param $slot i32) (param $east i32) (param $south i32)
  (param $eastRest i32) (param $southRest i32)
  (param $lb f64)
  (local $b i32) (local $i i32) (local $ni i32) (local $lz i32) (local $lx i32)
  (local $surf f64) (local $chnb f64) (local $dht f64) (local $fl f64) (local $dd f64)
  (local $nb i32) (local $derSelf f64)
  (local.set $b (call $wBase (local.get $slot)))
  (if (i32.ge_s (local.get $east) (i32.const 0)) (then
    (local.set $nb (call $wBase (local.get $east)))
    (local.set $lz (i32.const 1))
    (block $peEnd (loop $peLoop
      (br_if $peEnd (i32.ge_s (local.get $lz) (i32.const 17)))
      (local.set $i (i32.add (i32.const 16) (i32.mul (local.get $lz) (i32.const 18))))
      (if (i32.eqz (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 3888)) (local.get $i)))) (then
        (local.set $ni (i32.add (i32.const 1) (i32.mul (local.get $lz) (i32.const 18))))
        (local.set $derSelf (call $der (local.get $b) (local.get $i) (local.get $lb)))
        (local.set $surf (f64.add (local.get $derSelf)
          (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 1296)) (i32.mul (local.get $i) (i32.const 4)))))))
        (local.set $chnb (if (result f64) (i32.or (local.get $eastRest) (i32.eqz (i32.load8_u (i32.add (i32.add (local.get $nb) (i32.const 3888)) (local.get $ni)))))
          (then (call $der (local.get $nb) (local.get $ni) (local.get $lb)))
          (else (f64.promote_f32 (f32.load (i32.add (local.get $nb) (i32.mul (local.get $ni) (i32.const 4))))))))
        (local.set $dht (f64.sub (f64.add (local.get $chnb)
          (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $nb) (i32.const 1296)) (i32.mul (local.get $ni) (i32.const 4)))))) (local.get $surf)))
        (if (f64.gt (local.get $dht) (f64.const 0.0)) (then
          (local.set $fl (f64.min (f64.mul (local.get $dht) (f64.const 0.12)) (f64.mul (local.get $chnb) (f64.const 0.25))))
          (local.set $dd (f64.neg (local.get $fl))))
          (else
          (local.set $fl (f64.min (f64.mul (f64.neg (local.get $dht)) (f64.const 0.12)) (f64.mul (local.get $derSelf) (f64.const 0.25))))
          (local.set $dd (local.get $fl))))
        (if (f64.gt (f64.abs (local.get $dd)) (f64.const 0.001)) (then
          (call $markLive (local.get $b) (local.get $i) (i32.const 1) (local.get $lb))
          (f32.store (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))
            (f32.demote_f64 (f64.sub (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4))))) (local.get $dd))))
          (call $pushEdge (local.get $east) (local.get $ni) (local.get $dd))))))
      (local.set $lz (i32.add (local.get $lz) (i32.const 1)))
      (br $peLoop)))))
  (if (i32.ge_s (local.get $south) (i32.const 0)) (then
    (local.set $nb (call $wBase (local.get $south)))
    (local.set $lx (i32.const 1))
    (block $psEnd (loop $psLoop
      (br_if $psEnd (i32.ge_s (local.get $lx) (i32.const 17)))
      (local.set $i (i32.add (local.get $lx) (i32.mul (i32.const 16) (i32.const 18))))
      (if (i32.eqz (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 3888)) (local.get $i)))) (then
        (local.set $ni (i32.add (local.get $lx) (i32.const 18)))
        (local.set $derSelf (call $der (local.get $b) (local.get $i) (local.get $lb)))
        (local.set $surf (f64.add (local.get $derSelf)
          (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 1296)) (i32.mul (local.get $i) (i32.const 4)))))))
        (local.set $chnb (if (result f64) (i32.or (local.get $southRest) (i32.eqz (i32.load8_u (i32.add (i32.add (local.get $nb) (i32.const 3888)) (local.get $ni)))))
          (then (call $der (local.get $nb) (local.get $ni) (local.get $lb)))
          (else (f64.promote_f32 (f32.load (i32.add (local.get $nb) (i32.mul (local.get $ni) (i32.const 4))))))))
        (local.set $dht (f64.sub (f64.add (local.get $chnb)
          (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $nb) (i32.const 1296)) (i32.mul (local.get $ni) (i32.const 4)))))) (local.get $surf)))
        (if (f64.gt (local.get $dht) (f64.const 0.0)) (then
          (local.set $fl (f64.min (f64.mul (local.get $dht) (f64.const 0.12)) (f64.mul (local.get $chnb) (f64.const 0.25))))
          (local.set $dd (f64.neg (local.get $fl))))
          (else
          (local.set $fl (f64.min (f64.mul (f64.neg (local.get $dht)) (f64.const 0.12)) (f64.mul (local.get $derSelf) (f64.const 0.25))))
          (local.set $dd (local.get $fl))))
        (if (f64.gt (f64.abs (local.get $dd)) (f64.const 0.001)) (then
          (call $markLive (local.get $b) (local.get $i) (i32.const 1) (local.get $lb))
          (f32.store (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))
            (f32.demote_f64 (f64.sub (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4))))) (local.get $dd))))
          (call $pushEdge (local.get $south) (local.get $ni) (local.get $dd))))))
      (local.set $lx (i32.add (local.get $lx) (i32.const 1)))
      (br $psLoop))))))

;; wavefront strips for a REST chunk whose east/south neighbor is DIRTY (JS
;; _stripPass): stage the cross-chunk flow so the perturbation crosses the REST
;; chunk exactly. Unchanged except the STRIP scratch base.
(func $waterStripPass (export "waterStripPass")
  (param $slot i32) (param $east i32) (param $south i32)
  (param $eastRest i32) (param $southRest i32)
  (param $lb f64)
  (local $b i32) (local $i i32) (local $ni i32) (local $lz i32) (local $lx i32)
  (local $surf f64) (local $net f64) (local $dh f64) (local $fl f64) (local $d f64)
  (local $selfMax f64) (local $hEffN f64) (local $nb i32) (local $er i32) (local $sr i32)
  (local.set $b (call $wBase (local.get $slot)))
  (local.set $er (local.get $eastRest))
  (local.set $sr (local.get $southRest))
  (memory.fill (i32.const 0x00C50000) (i32.const 0) (i32.const 1296))
  (local.set $selfMax (f64.const 0.0))
  (if (i32.ge_s (local.get $east) (i32.const 0)) (then
    (local.set $nb (call $wBase (local.get $east)))
    (local.set $lz (i32.const 1))
    (block $eEnd (loop $eLoop
      (br_if $eEnd (i32.ge_s (local.get $lz) (i32.const 17)))
      (local.set $i (i32.add (i32.const 16) (i32.mul (local.get $lz) (i32.const 18))))
      (local.set $ni (i32.add (i32.const 1) (i32.mul (local.get $lz) (i32.const 18))))
      (local.set $surf (f64.add (call $der (local.get $b) (local.get $i) (local.get $lb))
        (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 1296)) (i32.mul (local.get $i) (i32.const 4)))))))
      (local.set $hEffN (if (result f64) (i32.or (local.get $er) (i32.eqz (i32.load8_u (i32.add (i32.add (local.get $nb) (i32.const 3888)) (local.get $ni)))))
        (then (call $der (local.get $nb) (local.get $ni) (local.get $lb)))
        (else (f64.promote_f32 (f32.load (i32.add (local.get $nb) (i32.mul (local.get $ni) (i32.const 4))))))))
      (local.set $dh (f64.sub (f64.add (local.get $hEffN)
        (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $nb) (i32.const 1296)) (i32.mul (local.get $ni) (i32.const 4)))))) (local.get $surf)))
      (local.set $net (f64.const 0.0))
      (if (f64.gt (local.get $dh) (f64.const 0.0)) (then
        (local.set $fl (f64.min (f64.mul (local.get $dh) (f64.const 0.12)) (f64.mul (local.get $hEffN) (f64.const 0.25))))
        (local.set $net (local.get $fl))
        (local.set $d (f64.neg (local.get $fl))))
        (else
        (local.set $fl (f64.min (f64.mul (f64.neg (local.get $dh)) (f64.const 0.12))
          (f64.mul (call $der (local.get $b) (local.get $i) (local.get $lb)) (f64.const 0.25))))
        (local.set $net (f64.neg (local.get $fl)))
        (local.set $d (local.get $fl))))
      (if (local.get $er) (then
        (if (f64.gt (f64.abs (local.get $d)) (f64.const 0.0001)) (then
          (call $materialize (local.get $east) (local.get $lb))
          (local.set $er (i32.const 0))
          (call $pushEdge (local.get $east) (local.get $ni) (local.get $d)))))
        (else
        (call $pushEdge (local.get $east) (local.get $ni) (local.get $d))))
      (f32.store (i32.add (i32.const 0x00C50000) (i32.mul (local.get $i) (i32.const 4)))
        (f32.demote_f64 (f64.add (f64.promote_f32 (f32.load (i32.add (i32.const 0x00C50000) (i32.mul (local.get $i) (i32.const 4))))) (local.get $net))))
      (local.set $selfMax (f64.max (local.get $selfMax)
        (f64.abs (f64.promote_f32 (f32.load (i32.add (i32.const 0x00C50000) (i32.mul (local.get $i) (i32.const 4))))))))
      (local.set $lz (i32.add (local.get $lz) (i32.const 1)))
      (br $eLoop)))))
  (if (i32.ge_s (local.get $south) (i32.const 0)) (then
    (local.set $nb (call $wBase (local.get $south)))
    (local.set $lx (i32.const 1))
    (block $sEnd (loop $sLoop
      (br_if $sEnd (i32.ge_s (local.get $lx) (i32.const 17)))
      (local.set $i (i32.add (local.get $lx) (i32.mul (i32.const 16) (i32.const 18))))
      (local.set $ni (i32.add (local.get $lx) (i32.const 18)))
      (local.set $surf (f64.add (call $der (local.get $b) (local.get $i) (local.get $lb))
        (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $b) (i32.const 1296)) (i32.mul (local.get $i) (i32.const 4)))))))
      (local.set $hEffN (if (result f64) (i32.or (local.get $sr) (i32.eqz (i32.load8_u (i32.add (i32.add (local.get $nb) (i32.const 3888)) (local.get $ni)))))
        (then (call $der (local.get $nb) (local.get $ni) (local.get $lb)))
        (else (f64.promote_f32 (f32.load (i32.add (local.get $nb) (i32.mul (local.get $ni) (i32.const 4))))))))
      (local.set $dh (f64.sub (f64.add (local.get $hEffN)
        (f64.promote_f32 (f32.load (i32.add (i32.add (local.get $nb) (i32.const 1296)) (i32.mul (local.get $ni) (i32.const 4)))))) (local.get $surf)))
      (local.set $net (f64.const 0.0))
      (if (f64.gt (local.get $dh) (f64.const 0.0)) (then
        (local.set $fl (f64.min (f64.mul (local.get $dh) (f64.const 0.12)) (f64.mul (local.get $hEffN) (f64.const 0.25))))
        (local.set $net (local.get $fl))
        (local.set $d (f64.neg (local.get $fl))))
        (else
        (local.set $fl (f64.min (f64.mul (f64.neg (local.get $dh)) (f64.const 0.12))
          (f64.mul (call $der (local.get $b) (local.get $i) (local.get $lb)) (f64.const 0.25))))
        (local.set $net (f64.neg (local.get $fl)))
        (local.set $d (local.get $fl))))
      (if (local.get $sr) (then
        (if (f64.gt (f64.abs (local.get $d)) (f64.const 0.0001)) (then
          (call $materialize (local.get $south) (local.get $lb))
          (local.set $sr (i32.const 0))
          (call $pushEdge (local.get $south) (local.get $ni) (local.get $d)))))
        (else
        (call $pushEdge (local.get $south) (local.get $ni) (local.get $d))))
      (f32.store (i32.add (i32.const 0x00C50000) (i32.mul (local.get $i) (i32.const 4)))
        (f32.demote_f64 (f64.add (f64.promote_f32 (f32.load (i32.add (i32.const 0x00C50000) (i32.mul (local.get $i) (i32.const 4))))) (local.get $net))))
      (local.set $selfMax (f64.max (local.get $selfMax)
        (f64.abs (f64.promote_f32 (f32.load (i32.add (i32.const 0x00C50000) (i32.mul (local.get $i) (i32.const 4))))))))
      (local.set $lx (i32.add (local.get $lx) (i32.const 1)))
      (br $sLoop)))))
  (if (f64.gt (local.get $selfMax) (f64.const 0.0001)) (then
    (call $materialize (local.get $slot) (local.get $lb))
    (local.set $lz (i32.const 1))
    (block $apE (loop $apEL
      (br_if $apE (i32.ge_s (local.get $lz) (i32.const 17)))
      (local.set $i (i32.add (i32.const 16) (i32.mul (local.get $lz) (i32.const 18))))
      ;; from the bed up: a boundary strip accumulates up to 16 one-sided transfers
      ;; and can therefore cross zero, and a negative depth here is the seed of the
      ;; negative-stiffness blow-up described at $edgeUpd. Clamp at the datum.
      (f32.store (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))
        (f32.demote_f64 (f64.max (f64.const 0.0) (f64.add (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))))
          (f64.promote_f32 (f32.load (i32.add (i32.const 0x00C50000) (i32.mul (local.get $i) (i32.const 4)))))))))
      (local.set $lz (i32.add (local.get $lz) (i32.const 1)))
      (br $apEL)))
    (local.set $lx (i32.const 1))
    (block $apS (loop $apSL
      (br_if $apS (i32.ge_s (local.get $lx) (i32.const 17)))
      (local.set $i (i32.add (local.get $lx) (i32.mul (i32.const 16) (i32.const 18))))
      ;; from the bed up: a boundary strip accumulates up to 16 one-sided transfers
      ;; and can therefore cross zero, and a negative depth here is the seed of the
      ;; negative-stiffness blow-up described at $edgeUpd. Clamp at the datum.
      (f32.store (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))
        (f32.demote_f64 (f64.max (f64.const 0.0) (f64.add (f64.promote_f32 (f32.load (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4)))))
          (f64.promote_f32 (f32.load (i32.add (i32.const 0x00C50000) (i32.mul (local.get $i) (i32.const 4)))))))))
      (local.set $lx (i32.add (local.get $lx) (i32.const 1)))
      (br $apSL))))))
)
