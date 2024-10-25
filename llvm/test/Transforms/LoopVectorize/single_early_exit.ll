; NOTE: Assertions have been autogenerated by utils/update_test_checks.py UTC_ARGS: --version 4
; RUN: opt -S < %s -p loop-vectorize | FileCheck %s

declare void @init_mem(ptr, i64);


define i64 @same_exit_block_phi_of_consts() {
; CHECK-LABEL: define i64 @same_exit_block_phi_of_consts() {
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[P1:%.*]] = alloca [1024 x i8], align 1
; CHECK-NEXT:    [[P2:%.*]] = alloca [1024 x i8], align 1
; CHECK-NEXT:    call void @init_mem(ptr [[P1]], i64 1024)
; CHECK-NEXT:    call void @init_mem(ptr [[P2]], i64 1024)
; CHECK-NEXT:    br label [[LOOP:%.*]]
; CHECK:       loop:
; CHECK-NEXT:    [[INDEX:%.*]] = phi i64 [ [[INDEX_NEXT:%.*]], [[LOOP_INC:%.*]] ], [ 3, [[ENTRY:%.*]] ]
; CHECK-NEXT:    [[ARRAYIDX:%.*]] = getelementptr inbounds i8, ptr [[P1]], i64 [[INDEX]]
; CHECK-NEXT:    [[LD1:%.*]] = load i8, ptr [[ARRAYIDX]], align 1
; CHECK-NEXT:    [[ARRAYIDX1:%.*]] = getelementptr inbounds i8, ptr [[P2]], i64 [[INDEX]]
; CHECK-NEXT:    [[LD2:%.*]] = load i8, ptr [[ARRAYIDX1]], align 1
; CHECK-NEXT:    [[CMP3:%.*]] = icmp eq i8 [[LD1]], [[LD2]]
; CHECK-NEXT:    br i1 [[CMP3]], label [[LOOP_INC]], label [[LOOP_END:%.*]]
; CHECK:       loop.inc:
; CHECK-NEXT:    [[INDEX_NEXT]] = add i64 [[INDEX]], 1
; CHECK-NEXT:    [[EXITCOND:%.*]] = icmp ne i64 [[INDEX_NEXT]], 67
; CHECK-NEXT:    br i1 [[EXITCOND]], label [[LOOP]], label [[LOOP_END]]
; CHECK:       loop.end:
; CHECK-NEXT:    [[RETVAL:%.*]] = phi i64 [ 0, [[LOOP]] ], [ 1, [[LOOP_INC]] ]
; CHECK-NEXT:    ret i64 [[RETVAL]]
;
entry:
  %p1 = alloca [1024 x i8]
  %p2 = alloca [1024 x i8]
  call void @init_mem(ptr %p1, i64 1024)
  call void @init_mem(ptr %p2, i64 1024)
  br label %loop

loop:
  %index = phi i64 [ %index.next, %loop.inc ], [ 3, %entry ]
  %arrayidx = getelementptr inbounds i8, ptr %p1, i64 %index
  %ld1 = load i8, ptr %arrayidx, align 1
  %arrayidx1 = getelementptr inbounds i8, ptr %p2, i64 %index
  %ld2 = load i8, ptr %arrayidx1, align 1
  %cmp3 = icmp eq i8 %ld1, %ld2
  br i1 %cmp3, label %loop.inc, label %loop.end

loop.inc:
  %index.next = add i64 %index, 1
  %exitcond = icmp ne i64 %index.next, 67
  br i1 %exitcond, label %loop, label %loop.end

loop.end:
  %retval = phi i64 [ 0, %loop ], [ 1, %loop.inc ]
  ret i64 %retval
}


define i64 @diff_exit_block_phi_of_consts() {
; CHECK-LABEL: define i64 @diff_exit_block_phi_of_consts() {
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[P1:%.*]] = alloca [1024 x i8], align 1
; CHECK-NEXT:    [[P2:%.*]] = alloca [1024 x i8], align 1
; CHECK-NEXT:    call void @init_mem(ptr [[P1]], i64 1024)
; CHECK-NEXT:    call void @init_mem(ptr [[P2]], i64 1024)
; CHECK-NEXT:    br label [[LOOP:%.*]]
; CHECK:       loop:
; CHECK-NEXT:    [[INDEX:%.*]] = phi i64 [ [[INDEX_NEXT:%.*]], [[LOOP_INC:%.*]] ], [ 3, [[ENTRY:%.*]] ]
; CHECK-NEXT:    [[ARRAYIDX:%.*]] = getelementptr inbounds i8, ptr [[P1]], i64 [[INDEX]]
; CHECK-NEXT:    [[LD1:%.*]] = load i8, ptr [[ARRAYIDX]], align 1
; CHECK-NEXT:    [[ARRAYIDX1:%.*]] = getelementptr inbounds i8, ptr [[P2]], i64 [[INDEX]]
; CHECK-NEXT:    [[LD2:%.*]] = load i8, ptr [[ARRAYIDX1]], align 1
; CHECK-NEXT:    [[CMP3:%.*]] = icmp eq i8 [[LD1]], [[LD2]]
; CHECK-NEXT:    br i1 [[CMP3]], label [[LOOP_INC]], label [[LOOP_EARLY_EXIT:%.*]]
; CHECK:       loop.inc:
; CHECK-NEXT:    [[INDEX_NEXT]] = add i64 [[INDEX]], 1
; CHECK-NEXT:    [[EXITCOND:%.*]] = icmp ne i64 [[INDEX_NEXT]], 67
; CHECK-NEXT:    br i1 [[EXITCOND]], label [[LOOP]], label [[LOOP_END:%.*]]
; CHECK:       loop.early.exit:
; CHECK-NEXT:    ret i64 0
; CHECK:       loop.end:
; CHECK-NEXT:    ret i64 1
;
entry:
  %p1 = alloca [1024 x i8]
  %p2 = alloca [1024 x i8]
  call void @init_mem(ptr %p1, i64 1024)
  call void @init_mem(ptr %p2, i64 1024)
  br label %loop

loop:
  %index = phi i64 [ %index.next, %loop.inc ], [ 3, %entry ]
  %arrayidx = getelementptr inbounds i8, ptr %p1, i64 %index
  %ld1 = load i8, ptr %arrayidx, align 1
  %arrayidx1 = getelementptr inbounds i8, ptr %p2, i64 %index
  %ld2 = load i8, ptr %arrayidx1, align 1
  %cmp3 = icmp eq i8 %ld1, %ld2
  br i1 %cmp3, label %loop.inc, label %loop.early.exit

loop.inc:
  %index.next = add i64 %index, 1
  %exitcond = icmp ne i64 %index.next, 67
  br i1 %exitcond, label %loop, label %loop.end

loop.early.exit:
  ret i64 0

loop.end:
  ret i64 1
}


; The form of the induction variables requires SCEV predicates.
define i32 @diff_exit_block_needs_scev_check(i32 %end) {
; CHECK-LABEL: define i32 @diff_exit_block_needs_scev_check(
; CHECK-SAME: i32 [[END:%.*]]) {
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[P1:%.*]] = alloca [1024 x i32], align 4
; CHECK-NEXT:    [[P2:%.*]] = alloca [1024 x i32], align 4
; CHECK-NEXT:    call void @init_mem(ptr [[P1]], i64 1024)
; CHECK-NEXT:    call void @init_mem(ptr [[P2]], i64 1024)
; CHECK-NEXT:    [[END_CLAMPED:%.*]] = and i32 [[END]], 1023
; CHECK-NEXT:    br label [[FOR_BODY:%.*]]
; CHECK:       for.body:
; CHECK-NEXT:    [[IND:%.*]] = phi i8 [ [[IND_NEXT:%.*]], [[FOR_INC:%.*]] ], [ 0, [[ENTRY:%.*]] ]
; CHECK-NEXT:    [[GEP_IND:%.*]] = phi i64 [ [[GEP_IND_NEXT:%.*]], [[FOR_INC]] ], [ 0, [[ENTRY]] ]
; CHECK-NEXT:    [[ARRAYIDX1:%.*]] = getelementptr inbounds i32, ptr [[P1]], i64 [[GEP_IND]]
; CHECK-NEXT:    [[TMP0:%.*]] = load i32, ptr [[ARRAYIDX1]], align 4
; CHECK-NEXT:    [[ARRAYIDX2:%.*]] = getelementptr inbounds i32, ptr [[P2]], i64 [[GEP_IND]]
; CHECK-NEXT:    [[TMP1:%.*]] = load i32, ptr [[ARRAYIDX2]], align 4
; CHECK-NEXT:    [[CMP_EARLY:%.*]] = icmp eq i32 [[TMP0]], [[TMP1]]
; CHECK-NEXT:    br i1 [[CMP_EARLY]], label [[FOUND:%.*]], label [[FOR_INC]]
; CHECK:       for.inc:
; CHECK-NEXT:    [[IND_NEXT]] = add i8 [[IND]], 1
; CHECK-NEXT:    [[CONV:%.*]] = zext i8 [[IND_NEXT]] to i32
; CHECK-NEXT:    [[GEP_IND_NEXT]] = add i64 [[GEP_IND]], 1
; CHECK-NEXT:    [[CMP:%.*]] = icmp ult i32 [[CONV]], [[END_CLAMPED]]
; CHECK-NEXT:    br i1 [[CMP]], label [[FOR_BODY]], label [[EXIT:%.*]]
; CHECK:       found:
; CHECK-NEXT:    ret i32 1
; CHECK:       exit:
; CHECK-NEXT:    ret i32 0
;
entry:
  %p1 = alloca [1024 x i32]
  %p2 = alloca [1024 x i32]
  call void @init_mem(ptr %p1, i64 1024)
  call void @init_mem(ptr %p2, i64 1024)
  %end.clamped = and i32 %end, 1023
  br label %for.body

for.body:
  %ind = phi i8 [ %ind.next, %for.inc ], [ 0, %entry ]
  %gep.ind = phi i64 [ %gep.ind.next, %for.inc ], [ 0, %entry ]
  %arrayidx1 = getelementptr inbounds i32, ptr %p1, i64 %gep.ind
  %0 = load i32, ptr %arrayidx1, align 4
  %arrayidx2 = getelementptr inbounds i32, ptr %p2, i64 %gep.ind
  %1 = load i32, ptr %arrayidx2, align 4
  %cmp.early = icmp eq i32 %0, %1
  br i1 %cmp.early, label %found, label %for.inc

for.inc:
  %ind.next = add i8 %ind, 1
  %conv = zext i8 %ind.next to i32
  %gep.ind.next = add i64 %gep.ind, 1
  %cmp = icmp ult i32 %conv, %end.clamped
  br i1 %cmp, label %for.body, label %exit

found:
  ret i32 1

exit:
  ret i32 0
}


declare void @abort()

; This is a variant of an early exit loop where the condition for leaving
; early is loop invariant.
define i32 @diff_blocks_invariant_early_exit_cond(ptr %s) {
; CHECK-LABEL: define i32 @diff_blocks_invariant_early_exit_cond(
; CHECK-SAME: ptr [[S:%.*]]) {
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[SVAL:%.*]] = load i32, ptr [[S]], align 4
; CHECK-NEXT:    [[COND:%.*]] = icmp eq i32 [[SVAL]], 0
; CHECK-NEXT:    br label [[FOR_BODY:%.*]]
; CHECK:       for.body:
; CHECK-NEXT:    [[IND:%.*]] = phi i32 [ -10, [[ENTRY:%.*]] ], [ [[IND_NEXT:%.*]], [[FOR_INC:%.*]] ]
; CHECK-NEXT:    br i1 [[COND]], label [[FOR_INC]], label [[EARLY_EXIT:%.*]]
; CHECK:       for.inc:
; CHECK-NEXT:    [[IND_NEXT]] = add nsw i32 [[IND]], 1
; CHECK-NEXT:    [[EXITCOND_NOT:%.*]] = icmp eq i32 [[IND_NEXT]], 266
; CHECK-NEXT:    br i1 [[EXITCOND_NOT]], label [[FOR_END:%.*]], label [[FOR_BODY]]
; CHECK:       early.exit:
; CHECK-NEXT:    tail call void @abort()
; CHECK-NEXT:    unreachable
; CHECK:       for.end:
; CHECK-NEXT:    ret i32 0
;
entry:
  %sval = load i32, ptr %s, align 4
  %cond = icmp eq i32 %sval, 0
  br label %for.body

for.body:
  %ind = phi i32 [ -10, %entry ], [ %ind.next, %for.inc ]
  br i1 %cond, label %for.inc, label %early.exit

for.inc:
  %ind.next = add nsw i32 %ind, 1
  %exitcond.not = icmp eq i32 %ind.next, 266
  br i1 %exitcond.not, label %for.end, label %for.body

early.exit:
  tail call void @abort()
  unreachable

for.end:
  ret i32 0
}
