// Test stub dispatch helper functions in Phase 2
// These stubs conservatively return false, so all calls should prepare for thunks
// This test verifies that the stub functions exist and compile correctly
// Full optimization tests will be added in Phase 7

// RUN: %clang_cc1 -emit-llvm -fobjc-arc -triple arm64-apple-darwin10 \
// RUN:   -fobjc-expose-direct-methods %s -o - | FileCheck %s

@interface MyClass
- (int)directMethod __attribute__((objc_direct));
+ (int)classDirectMethod __attribute__((objc_direct));
@end

@implementation MyClass

// Instance method implementation should NOT have nil check
// CHECK-LABEL: define {{.*}} @"-[MyClass directMethod]"(
- (int)directMethod {
  // CHECK-NOT: icmp eq ptr {{.*}}, null
  // CHECK-NOT: objc_direct_method.self_is_nil
  return 42;
}

// Class method implementation should NOT have class realization
// CHECK-LABEL: define {{.*}} @"+[MyClass classDirectMethod]"(
+ (int)classDirectMethod {
  // CHECK-NOT: call {{.*}} @objc_msgSend
  // CHECK-NOT: icmp eq ptr {{.*}}, null
  return 24;
}

@end

// Test call sites - with stub functions returning false,
// behavior will be determined in Phase 3+ when thunk generation is implemented
// For now, this just verifies compilation succeeds

int testInstanceMethod(MyClass *obj) {
  return [obj directMethod];
}

int testClassMethod(void) {
  return [MyClass classDirectMethod];
}

// Phase 7 will add tests verifying optimization:
// - Non-null receivers call implementation directly
// - Nullable receivers call thunks
// - Realized classes skip realization in thunks
