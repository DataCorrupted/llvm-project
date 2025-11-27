// Test basic functionality of -fobjc-expose-direct-methods flag
// RUN: %clang_cc1 -emit-llvm -fobjc-arc -triple arm64-apple-darwin10 \
// RUN:   -fobjc-expose-direct-methods %s -o - | FileCheck %s

@interface MyClass
- (int)directMethod __attribute__((objc_direct));
+ (int)classDirectMethod __attribute__((objc_direct));
@end

@implementation MyClass

// Instance method should have exposed symbol without \01 prefix
// CHECK-LABEL: define {{.*}} @"-[MyClass directMethod]"(
// CHECK-NOT: @"\01-[MyClass directMethod]"
- (int)directMethod {
  // CHECK-NOT: icmp eq ptr {{.*}}, null
  // CHECK-NOT: objc_direct_method.self_is_nil
  return 42;
}

// Class method should have exposed symbol without \01 prefix
// CHECK-LABEL: define {{.*}} @"+[MyClass classDirectMethod]"(
// CHECK-NOT: @"\01+[MyClass classDirectMethod]"
+ (int)classDirectMethod {
  // Class methods keep [self self] initialization
  // CHECK-NOT: icmp eq ptr {{.*}}, null
  // CHECK-NOT: objc_direct_method.self_is_nil
  return 24;
}

@end
