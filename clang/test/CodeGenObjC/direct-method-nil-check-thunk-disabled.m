// RUN: %clang_cc1 -emit-llvm -fobjc-arc -triple x86_64-apple-darwin10 %s -o - | FileCheck %s

// Tests that without -fobjc-nil-check-thunk, the old behavior is maintained:
// 1. Methods use hidden symbols (internal linkage)
// 2. Nil checks are in the callee (implementation)
// 3. No thunks are generated

__attribute__((objc_root_class))
@interface Root
- (int)directMethod __attribute__((objc_direct));
@end

@implementation Root

// CHECK-LABEL: define hidden i32 @"\01-[Root directMethod]"(
// CHECK: icmp eq ptr {{.*}}, null
// CHECK: objc_direct_method.self_is_nil
// CHECK: ret i32
- (int)directMethod __attribute__((objc_direct)) {
  return 42;
}

@end

// Test that callers still call the hidden symbol directly
// CHECK-LABEL: define{{.*}} i32 @testCaller(
int testCaller(Root *receiver) {
  // CHECK: call i32 @"\01-[Root directMethod]"(
  // CHECK-NOT: _thunk
  return [receiver directMethod];
}

// Ensure no thunk is generated
// CHECK-NOT: define{{.*}}_thunk
