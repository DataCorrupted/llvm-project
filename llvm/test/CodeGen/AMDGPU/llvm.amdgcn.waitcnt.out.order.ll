; NOTE: Assertions have been autogenerated by utils/update_llc_test_checks.py UTC_ARGS: --version 5
; RUN: llc -mtriple=amdgcn -mcpu=gfx1100 -mattr=+real-true16 < %s | FileCheck -check-prefixes=GFX11,GFX11-TRUE16 %s
; RUN: llc -mtriple=amdgcn -mcpu=gfx1100 -mattr=-real-true16 < %s | FileCheck -check-prefixes=GFX11,GFX11-FAKE16 %s
; RUN: llc -mtriple=amdgcn -mcpu=gfx1150 -mattr=+real-true16 < %s | FileCheck -check-prefixes=GFX1150,GFX1150-TRUE16 %s
; RUN: llc -mtriple=amdgcn -mcpu=gfx1150 -mattr=-real-true16 < %s | FileCheck -check-prefixes=GFX1150,GFX1150-FAKE16 %s
; RUN: llc -mtriple=amdgcn -mcpu=gfx1200 -mattr=+real-true16 < %s | FileCheck -check-prefixes=GFX12,GFX12-TRUE16 %s
; RUN: llc -mtriple=amdgcn -mcpu=gfx1200 -mattr=-real-true16 < %s | FileCheck -check-prefixes=GFX12,GFX12-FAKE16 %s

define amdgpu_ps <3 x float> @gather_sample(<8 x i32> inreg %rsrc, <4 x i32> inreg %samp, <8 x i32> inreg %rsrc2, <4 x i32> inreg %samp2, float %s, float %t) {
; GFX11-LABEL: gather_sample:
; GFX11:       ; %bb.0:
; GFX11-NEXT:    v_mov_b32_e32 v4, 0
; GFX11-NEXT:    image_gather4_lz v[0:3], v[0:1], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX11-NEXT:    image_sample_lz v2, [v4, v4], s[12:19], s[20:23] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX11-NEXT:    s_waitcnt vmcnt(0)
; GFX11-NEXT:    ; return to shader part epilog
;
; GFX1150-LABEL: gather_sample:
; GFX1150:       ; %bb.0:
; GFX1150-NEXT:    v_mov_b32_e32 v4, 0
; GFX1150-NEXT:    image_gather4_lz v[0:3], v[0:1], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX1150-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-NEXT:    image_sample_lz v2, [v4, v4], s[12:19], s[20:23] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX1150-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-NEXT:    ; return to shader part epilog
;
; GFX12-LABEL: gather_sample:
; GFX12:       ; %bb.0:
; GFX12-NEXT:    v_mov_b32_e32 v4, 0
; GFX12-NEXT:    image_gather4_lz v[0:3], [v0, v1], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX12-NEXT:    s_wait_samplecnt 0x0
; GFX12-NEXT:    image_sample_lz v2, [v4, v4], s[12:19], s[20:23] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX12-NEXT:    s_wait_samplecnt 0x0
; GFX12-NEXT:    ; return to shader part epilog

  %v = call <4 x float> @llvm.amdgcn.image.gather4.lz.2d.v4f32.f32(i32 1, float %s, float %t, <8 x i32> %rsrc, <4 x i32> %samp, i1 0, i32 0, i32 0)
  %w = call <4 x float> @llvm.amdgcn.image.sample.lz.2d.v4f32.f32(i32 1, float 0.000000e+00, float 0.000000e+00, <8 x i32> %rsrc2, <4 x i32> %samp2, i1 false, i32 0, i32 0)
  %t0 = extractelement <4 x float> %v, i32 0
  %res0 = insertelement <3 x float> poison, float %t0, i32 0
  %t1 = extractelement <4 x float> %v, i32 1
  %res1 = insertelement <3 x float> %res0, float %t1, i32 1
  %t2 = extractelement <4 x float> %w, i32 0
  %res2 = insertelement <3 x float> %res1, float %t2, i32 2
  ret <3 x float> %res2
}

define amdgpu_ps <3 x float> @sample_gather(<8 x i32> inreg %rsrc, <4 x i32> inreg %samp, <8 x i32> inreg %rsrc2, <4 x i32> inreg %samp2, float %s, float %t) {
; GFX11-LABEL: sample_gather:
; GFX11:       ; %bb.0:
; GFX11-NEXT:    v_mov_b32_e32 v4, 0
; GFX11-NEXT:    image_gather4_lz v[0:3], v[0:1], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX11-NEXT:    image_sample_lz v2, [v4, v4], s[12:19], s[20:23] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX11-NEXT:    s_waitcnt vmcnt(0)
; GFX11-NEXT:    ; return to shader part epilog
;
; GFX1150-LABEL: sample_gather:
; GFX1150:       ; %bb.0:
; GFX1150-NEXT:    v_mov_b32_e32 v4, 0
; GFX1150-NEXT:    image_gather4_lz v[0:3], v[0:1], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX1150-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-NEXT:    image_sample_lz v2, [v4, v4], s[12:19], s[20:23] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX1150-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-NEXT:    ; return to shader part epilog
;
; GFX12-LABEL: sample_gather:
; GFX12:       ; %bb.0:
; GFX12-NEXT:    v_mov_b32_e32 v4, 0
; GFX12-NEXT:    image_gather4_lz v[0:3], [v0, v1], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX12-NEXT:    s_wait_samplecnt 0x0
; GFX12-NEXT:    image_sample_lz v2, [v4, v4], s[12:19], s[20:23] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX12-NEXT:    s_wait_samplecnt 0x0
; GFX12-NEXT:    ; return to shader part epilog

  %w = call <4 x float> @llvm.amdgcn.image.sample.lz.2d.v4f32.f32(i32 15, float 0.000000e+00, float 0.000000e+00, <8 x i32> %rsrc2, <4 x i32> %samp2, i1 false, i32 0, i32 0)
  %v = call <4 x float> @llvm.amdgcn.image.gather4.lz.2d.v4f32.f32(i32 1, float %s, float %t, <8 x i32> %rsrc, <4 x i32> %samp, i1 0, i32 0, i32 0)
  %t0 = extractelement <4 x float> %v, i32 0
  %res0 = insertelement <3 x float> poison, float %t0, i32 0
  %t1 = extractelement <4 x float> %v, i32 1
  %res1 = insertelement <3 x float> %res0, float %t1, i32 1
  %t2 = extractelement <4 x float> %w, i32 0
  %res2 = insertelement <3 x float> %res1, float %t2, i32 2
  ret <3 x float> %res2
}

define amdgpu_ps <3 x float> @sample_load(<8 x i32> inreg %rsrc, <4 x i32> inreg %samp, <8 x i32> inreg %rsrc2, i16 %s.16, i16 %t.16, i16 %fragid) {
; GFX11-TRUE16-LABEL: sample_load:
; GFX11-TRUE16:       ; %bb.0:
; GFX11-TRUE16-NEXT:    v_mov_b16_e32 v3.l, v2.l
; GFX11-TRUE16-NEXT:    v_mov_b16_e32 v2.l, v0.l
; GFX11-TRUE16-NEXT:    v_mov_b16_e32 v2.h, v1.l
; GFX11-TRUE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX11-TRUE16-NEXT:    image_msaa_load v[0:3], v[2:3], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX11-TRUE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX11-TRUE16-NEXT:    s_waitcnt vmcnt(0)
; GFX11-TRUE16-NEXT:    ; return to shader part epilog
;
; GFX11-FAKE16-LABEL: sample_load:
; GFX11-FAKE16:       ; %bb.0:
; GFX11-FAKE16-NEXT:    v_perm_b32 v0, v1, v0, 0x5040100
; GFX11-FAKE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX11-FAKE16-NEXT:    image_msaa_load v[0:3], [v0, v2], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX11-FAKE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX11-FAKE16-NEXT:    s_waitcnt vmcnt(0)
; GFX11-FAKE16-NEXT:    ; return to shader part epilog
;
; GFX1150-TRUE16-LABEL: sample_load:
; GFX1150-TRUE16:       ; %bb.0:
; GFX1150-TRUE16-NEXT:    v_mov_b16_e32 v3.l, v2.l
; GFX1150-TRUE16-NEXT:    v_mov_b16_e32 v2.l, v0.l
; GFX1150-TRUE16-NEXT:    v_mov_b16_e32 v2.h, v1.l
; GFX1150-TRUE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX1150-TRUE16-NEXT:    image_msaa_load v[0:3], v[2:3], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX1150-TRUE16-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-TRUE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX1150-TRUE16-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-TRUE16-NEXT:    ; return to shader part epilog
;
; GFX1150-FAKE16-LABEL: sample_load:
; GFX1150-FAKE16:       ; %bb.0:
; GFX1150-FAKE16-NEXT:    v_perm_b32 v0, v1, v0, 0x5040100
; GFX1150-FAKE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX1150-FAKE16-NEXT:    image_msaa_load v[0:3], [v0, v2], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX1150-FAKE16-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-FAKE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX1150-FAKE16-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-FAKE16-NEXT:    ; return to shader part epilog
;
; GFX12-TRUE16-LABEL: sample_load:
; GFX12-TRUE16:       ; %bb.0:
; GFX12-TRUE16-NEXT:    v_mov_b16_e32 v0.h, v1.l
; GFX12-TRUE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX12-TRUE16-NEXT:    image_msaa_load v[0:3], [v0, v2], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX12-TRUE16-NEXT:    s_wait_samplecnt 0x0
; GFX12-TRUE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX12-TRUE16-NEXT:    s_wait_samplecnt 0x0
; GFX12-TRUE16-NEXT:    ; return to shader part epilog
;
; GFX12-FAKE16-LABEL: sample_load:
; GFX12-FAKE16:       ; %bb.0:
; GFX12-FAKE16-NEXT:    v_perm_b32 v0, v1, v0, 0x5040100
; GFX12-FAKE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX12-FAKE16-NEXT:    image_msaa_load v[0:3], [v0, v2], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX12-FAKE16-NEXT:    s_wait_samplecnt 0x0
; GFX12-FAKE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX12-FAKE16-NEXT:    s_wait_samplecnt 0x0
; GFX12-FAKE16-NEXT:    ; return to shader part epilog

  %w = call <4 x float> @llvm.amdgcn.image.sample.lz.2d.v4f32.f32(i32 15, float 0.000000e+00, float 0.000000e+00, <8 x i32> %rsrc, <4 x i32> %samp, i1 false, i32 0, i32 0)
  %v = call <4 x float> @llvm.amdgcn.image.msaa.load.2dmsaa.v4f32.i32(i32 1, i16 %s.16, i16 %t.16, i16 %fragid, <8 x i32> %rsrc2, i32 0, i32 0)
  %t0 = extractelement <4 x float> %v, i32 0
  %res0 = insertelement <3 x float> poison, float %t0, i32 0
  %t1 = extractelement <4 x float> %v, i32 1
  %res1 = insertelement <3 x float> %res0, float %t1, i32 1
  %t2 = extractelement <4 x float> %w, i32 0
  %res2 = insertelement <3 x float> %res1, float %t2, i32 2
  ret <3 x float> %res2
}

define amdgpu_ps <3 x float> @load_sample(<8 x i32> inreg %rsrc, <4 x i32> inreg %samp, <8 x i32> inreg %rsrc2, i16 %s.16, i16 %t.16, i16 %fragid) {
; GFX11-TRUE16-LABEL: load_sample:
; GFX11-TRUE16:       ; %bb.0:
; GFX11-TRUE16-NEXT:    v_mov_b16_e32 v3.l, v2.l
; GFX11-TRUE16-NEXT:    v_mov_b16_e32 v2.l, v0.l
; GFX11-TRUE16-NEXT:    v_mov_b16_e32 v2.h, v1.l
; GFX11-TRUE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX11-TRUE16-NEXT:    image_msaa_load v[0:3], v[2:3], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX11-TRUE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX11-TRUE16-NEXT:    s_waitcnt vmcnt(0)
; GFX11-TRUE16-NEXT:    ; return to shader part epilog
;
; GFX11-FAKE16-LABEL: load_sample:
; GFX11-FAKE16:       ; %bb.0:
; GFX11-FAKE16-NEXT:    v_perm_b32 v0, v1, v0, 0x5040100
; GFX11-FAKE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX11-FAKE16-NEXT:    image_msaa_load v[0:3], [v0, v2], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX11-FAKE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX11-FAKE16-NEXT:    s_waitcnt vmcnt(0)
; GFX11-FAKE16-NEXT:    ; return to shader part epilog
;
; GFX1150-TRUE16-LABEL: load_sample:
; GFX1150-TRUE16:       ; %bb.0:
; GFX1150-TRUE16-NEXT:    v_mov_b16_e32 v3.l, v2.l
; GFX1150-TRUE16-NEXT:    v_mov_b16_e32 v2.l, v0.l
; GFX1150-TRUE16-NEXT:    v_mov_b16_e32 v2.h, v1.l
; GFX1150-TRUE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX1150-TRUE16-NEXT:    image_msaa_load v[0:3], v[2:3], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX1150-TRUE16-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-TRUE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX1150-TRUE16-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-TRUE16-NEXT:    ; return to shader part epilog
;
; GFX1150-FAKE16-LABEL: load_sample:
; GFX1150-FAKE16:       ; %bb.0:
; GFX1150-FAKE16-NEXT:    v_perm_b32 v0, v1, v0, 0x5040100
; GFX1150-FAKE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX1150-FAKE16-NEXT:    image_msaa_load v[0:3], [v0, v2], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX1150-FAKE16-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-FAKE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX1150-FAKE16-NEXT:    s_waitcnt vmcnt(0)
; GFX1150-FAKE16-NEXT:    ; return to shader part epilog
;
; GFX12-TRUE16-LABEL: load_sample:
; GFX12-TRUE16:       ; %bb.0:
; GFX12-TRUE16-NEXT:    v_mov_b16_e32 v0.h, v1.l
; GFX12-TRUE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX12-TRUE16-NEXT:    image_msaa_load v[0:3], [v0, v2], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX12-TRUE16-NEXT:    s_wait_samplecnt 0x0
; GFX12-TRUE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX12-TRUE16-NEXT:    s_wait_samplecnt 0x0
; GFX12-TRUE16-NEXT:    ; return to shader part epilog
;
; GFX12-FAKE16-LABEL: load_sample:
; GFX12-FAKE16:       ; %bb.0:
; GFX12-FAKE16-NEXT:    v_perm_b32 v0, v1, v0, 0x5040100
; GFX12-FAKE16-NEXT:    v_mov_b32_e32 v4, 0
; GFX12-FAKE16-NEXT:    image_msaa_load v[0:3], [v0, v2], s[12:19] dmask:0x1 dim:SQ_RSRC_IMG_2D_MSAA unorm a16
; GFX12-FAKE16-NEXT:    s_wait_samplecnt 0x0
; GFX12-FAKE16-NEXT:    image_sample_lz v2, [v4, v4], s[0:7], s[8:11] dmask:0x1 dim:SQ_RSRC_IMG_2D
; GFX12-FAKE16-NEXT:    s_wait_samplecnt 0x0
; GFX12-FAKE16-NEXT:    ; return to shader part epilog

  %v = call <4 x float> @llvm.amdgcn.image.msaa.load.2dmsaa.v4f32.i32(i32 1, i16 %s.16, i16 %t.16, i16 %fragid, <8 x i32> %rsrc2, i32 0, i32 0)
  %w = call <4 x float> @llvm.amdgcn.image.sample.lz.2d.v4f32.f32(i32 15, float 0.000000e+00, float 0.000000e+00, <8 x i32> %rsrc, <4 x i32> %samp, i1 false, i32 0, i32 0)
  %t0 = extractelement <4 x float> %v, i32 0
  %res0 = insertelement <3 x float> poison, float %t0, i32 0
  %t1 = extractelement <4 x float> %v, i32 1
  %res1 = insertelement <3 x float> %res0, float %t1, i32 1
  %t2 = extractelement <4 x float> %w, i32 0
  %res2 = insertelement <3 x float> %res1, float %t2, i32 2
  ret <3 x float> %res2
}


declare <4 x float> @llvm.amdgcn.image.gather4.lz.2d.v4f32.f32(i32, float, float, <8 x i32>, <4 x i32>, i1, i32, i32)
declare <4 x float> @llvm.amdgcn.image.sample.lz.2d.v4f32.f32(i32, float, float, <8 x i32>, <4 x i32>, i1, i32, i32)
declare <4 x float> @llvm.amdgcn.image.msaa.load.2dmsaa.v4f32.i16(i32, i16, i16, i16, <8 x i32>, i32, i32)
