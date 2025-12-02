// Test variadic direct methods - should get exposed symbols but not use thunks
// RUN: %clang_cc1 -emit-llvm -fobjc-arc -triple arm64-apple-darwin10 \
// RUN:   -fobjc-expose-direct-methods %s -o - | FileCheck %s

__attribute__((objc_root_class))
@interface Root
- (int)varMethod:(int)first, ... __attribute__((objc_direct));
+ (void)printf:(Root *)format, ... __attribute__((objc_direct));
@end

@implementation Root

// Variadic methods get exposed symbols WITHOUT nil checks in implementation
// The caller will emit inline nil checks instead of using thunks
// CHECK-LABEL: define hidden i32 @"-[Root varMethod:]"(
// CHECK-NOT: @"\01-[Root varMethod:]"
// CHECK-NOT: @"-[Root varMethod:]_thunk"
- (int)varMethod:(int)first, ... {
  // Should NOT have nil check (moved to caller)
  // CHECK-NOT: icmp eq ptr {{.*}}, null
  // CHECK-NOT: objc_direct_method.self_is_nil
  return first;
}

// CHECK-LABEL: define hidden void @"+[Root printf:]"(
// CHECK-NOT: @"\01+[Root printf:]"
// CHECK-NOT: @"+[Root printf:]_thunk"
+ (void)printf:(Root *)format, ... {}

@end

// Regardless root's nullable state, the caller will emit inline nil checks
// Check that the nil checks are inlined correctly in phase 4 and 5.
void useRoot(Root *_Nullable root) {
  // CHECK: %call = call i32 (ptr, i32, ...) @"-[Root varMethod:]"
  [root varMethod:1, 2, 3.0];
  // CHECK: call void (ptr, ptr, ...) @"+[Root printf:]"
  [Root printf:root, "hello", root];
}


void useRootNonNull(Root *_Nonnull root) {

  // CHECK: %call = call i32 (ptr, i32, ...) @"-[Root varMethod:]"
  [root varMethod:1, 2, 3.0];
  // CHECK: call void (ptr, ptr, ...) @"+[Root printf:]"
  [Root printf:root, "hello", root];
}
