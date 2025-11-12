// RUN: %clang_cc1 -emit-llvm -fobjc-arc -fobjc-nil-check-thunk -triple x86_64-apple-darwin10 %s -o - | FileCheck %s

// Tests that variadic direct methods are excluded from the nil-check thunk optimization.
// Per RFC, variadic functions should maintain the old behavior (hidden linkage with nil checks).

__attribute__((objc_root_class))
@interface Root
- (int)directVarArgs:(int)first, ... __attribute__((objc_direct));
@end

@implementation Root

// Variadic methods should keep hidden linkage with \01 prefix and nil checks
// CHECK-LABEL: define hidden i32 @"\01-[Root directVarArgs:]"(
// CHECK: icmp eq ptr {{.*}}, null
// CHECK: objc_direct_method.self_is_nil
// CHECK: ret i32
- (int)directVarArgs:(int)first, ... __attribute__((objc_direct)) {
  return first;
}

@end

// Test that caller still calls the hidden symbol for variadic methods
// CHECK-LABEL: define{{.*}} i32 @testVarArgsCall(
int testVarArgsCall(Root *obj) {
  // CHECK: call i32 (ptr, i32, ...) @"\01-[Root directVarArgs:]"(
  return [obj directVarArgs:42];
}
