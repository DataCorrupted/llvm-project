// Test variadic direct methods - should get exposed symbols but not use thunks
// RUN: %clang_cc1 -emit-llvm -fobjc-arc -triple arm64-apple-darwin10 \
// RUN:   -fobjc-expose-direct-methods %s -o - | FileCheck %s

@interface MyClass
- (int)varMethod:(int)first, ... __attribute__((objc_direct));
@end

@implementation MyClass

// Variadic methods get exposed symbols WITHOUT nil checks in implementation
// The caller will emit inline nil checks instead of using thunks
// CHECK-LABEL: define {{.*}} @"-[MyClass varMethod:]"(
// CHECK-NOT: @"\01-[MyClass varMethod:]"
- (int)varMethod:(int)first, ... {
  // Should NOT have nil check (moved to caller)
  // CHECK-NOT: icmp eq ptr {{.*}}, null
  // CHECK-NOT: objc_direct_method.self_is_nil
  return first;
}

@end
