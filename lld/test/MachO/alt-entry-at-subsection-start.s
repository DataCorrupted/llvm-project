# REQUIRES: aarch64

# RUN: rm -rf %t; split-file %s %t
# RUN: llvm-mc -filetype=obj -triple=arm64-apple-darwin %t/main.s -o %t/main.o
# RUN: %no-arg-lld -arch arm64 -platform_version macos 12.0 12.0 -dylib \
# RUN:     -undefined dynamic_lookup -order_file %t/order.txt -o %t/main.dylib %t/main.o
# RUN: llvm-objdump --syms -d --no-show-raw-insn %t/main.dylib | FileCheck %s

#--- order.txt
_prev_fn
_other
_target
_caller

#--- main.s
.subsections_via_symbols
.section  __TEXT,__text,regular,pure_instructions

.globl _prev_fn
.p2align 2
_prev_fn:
  add w0, w0, #7
  ret

.globl _target
.p2align 2
_target:
.alt_entry alt_at_start
alt_at_start:
  add w0, w0, #1
  ret

## Ordered where _prev_fn's subsection ends, so a misbound alt entry lands here.
.globl _other
.p2align 2
_other:
  add w0, w0, #9
  ret

.globl _caller
.p2align 2
_caller:
  b alt_at_start

# CHECK-DAG: [[#%x,TARGET:]] {{.*}} _target
# CHECK-DAG: [[#%x,OTHER:]] {{.*}} _other

# CHECK-LABEL: <_caller>:
# CHECK:         b 0x[[#%x,TARGET]]
# CHECK-NOT:     b 0x[[#%x,OTHER]]
