// RUN: %clang_cc1 -emit-llvm -fobjc-arc -fobjc-nil-check-thunk -triple x86_64-apple-darwin10 %s -o - | FileCheck %s

// Tests for the objc_direct nil-check thunk optimization.
// NOTE: This feature is not yet implemented. The flag is currently ignored.
// With -fobjc-nil-check-thunk enabled (once implemented), objc_direct methods should:
// 1. Emit the true implementation with linkonce_odr linkage and public symbol
// 2. No nil check in the implementation itself
// 3. Caller generates a thunk for nullable receivers
// 4. Non-null receivers (like self) get direct calls to the implementation
//
// Current behavior (before implementation):
// - Methods still use hidden linkage with \01-prefixed symbols
// - Nil checks remain in the implementation
// - No thunks are generated

struct my_struct {
  int a, b;
};

__attribute__((objc_root_class))
@interface Root
- (int)directMethod __attribute__((objc_direct));
- (int)directMethodWithArg:(int)arg __attribute__((objc_direct));
+ (int)classDirectMethod __attribute__((objc_direct));
- (struct my_struct)directMethodReturningStruct __attribute__((objc_direct));
- (id)directMethodReturningObject __attribute__((objc_direct));
@property(direct, readonly) int directProperty;
@end

@implementation Root

// Current behavior: hidden linkage with \01 prefix, nil check in implementation
// CHECK-LABEL: define hidden i32 @"\01-[Root directMethod]"(
// CHECK: icmp eq ptr {{.*}}, null
// CHECK: objc_direct_method.self_is_nil
// CHECK: ret i32
- (int)directMethod __attribute__((objc_direct)) {
  return 42;
}

// CHECK-LABEL: define hidden i32 @"\01-[Root directMethodWithArg:]"(
// CHECK: icmp eq ptr {{.*}}, null
// CHECK: objc_direct_method.self_is_nil
// CHECK: ret i32
- (int)directMethodWithArg:(int)arg __attribute__((objc_direct)) {
  return arg + 10;
}

// CHECK-LABEL: define hidden i32 @"\01+[Root classDirectMethod]"(
// Class methods perform [self self] call, so no nil check in the implementation
// CHECK: ret i32
+ (int)classDirectMethod __attribute__((objc_direct)) {
  return 100;
}

// CHECK-LABEL: define hidden i64 @"\01-[Root directMethodReturningStruct]"(
// CHECK: icmp eq ptr {{.*}}, null
// CHECK: objc_direct_method.self_is_nil
// CHECK: ret i64
- (struct my_struct)directMethodReturningStruct __attribute__((objc_direct)) {
  struct my_struct s = {.a = 1, .b = 2};
  return s;
}

// CHECK-LABEL: define hidden ptr @"\01-[Root directMethodReturningObject]"(
// CHECK: icmp eq ptr {{.*}}, null
// CHECK: objc_direct_method.self_is_nil
// CHECK: ret ptr
- (id)directMethodReturningObject __attribute__((objc_direct)) {
  return self;
}

// CHECK-LABEL: define hidden i32 @"\01-[Root directProperty]"(
// CHECK: icmp eq ptr {{.*}}, null
// CHECK: objc_direct_method.self_is_nil
// CHECK: ret i32
- (int)directProperty {
  return 99;
}

// Instance method calling another direct method on self (non-null)
// CHECK-LABEL: define hidden i32 @"\01-[Root callDirectMethodOnSelf]"(
- (int)callDirectMethodOnSelf __attribute__((objc_direct)) {
  // Current behavior: calls the hidden symbol directly
  // CHECK: call i32 @"\01-[Root directMethod]"(
  return [self directMethod];
}

@end

// Test that callers currently still call the hidden symbol directly
// Current behavior: no thunks are generated yet
// CHECK-LABEL: define{{.*}} i32 @testNullableReceiver(
int testNullableReceiver(Root *nullable_receiver) {
  // Current behavior: calls the hidden symbol directly (no thunk yet)
  // CHECK: call i32 @"\01-[Root directMethod]"(
  return [nullable_receiver directMethod];
}

// CHECK-LABEL: define{{.*}} i32 @testNonNullReceiver(
int testNonNullReceiver(Root *_Nonnull nonnull_receiver) {
  // Current behavior: calls the hidden symbol directly
  // CHECK: call i32 @"\01-[Root directMethod]"(
  return [nonnull_receiver directMethod];
}

// Ensure no thunks are generated in current implementation
// CHECK-NOT: define{{.*}}_thunk
