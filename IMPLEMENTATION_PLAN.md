# Implementation Plan: ObjC Direct Method Nil-Check Thunk Optimization

## Table of Contents

1. [Background and Motivation](#background-and-motivation)
2. [Design Overview](#design-overview)
3. [Implementation Phases](#implementation-phases)
4. [Files to Modify](#files-to-modify)
5. [Testing Strategy](#testing-strategy)
6. [Build and Validation](#build-and-validation)

---

## Background and Motivation

### What is `objc_direct`?

The `__attribute__((objc_direct))` attribute in Objective-C allows methods to bypass the Objective-C message dispatch system and use direct function calls instead. This improves performance but was originally designed with an emphasis on ABI stability that led to several drawbacks.

### Current Problems

The existing implementation of `objc_direct` has three main issues:

**1. Code Bloat and Poor Optimization**
- Every direct method implementation contains nil-checking logic
- This nil check is duplicated even at call sites where the receiver is provably non-null (like `self`)
- For instance methods: `if (self == nil) return <zero-value>;`
- For class methods: includes both class realization and nil checks for weak-linked classes
- This redundant checking significantly increases binary size

**2. Poor Linkage**
- Direct methods use hidden symbols (internal linkage)
- This prevents calling direct methods from other translation units (link units)
- Developers must manually write wrapper thunks to expose methods, further increasing code size
- Example: A method `-[MyClass method]` is emitted as `@"\01-[MyClass method]"` with hidden visibility

**3. Swift Interop Complexity**
- Swift functions cannot be easily exposed as `@objcDirect`
- The Swift frontend (SILGen) faces significant implementation challenges
- When a direct method needs nil checking, Swift must handle `Optional<MyClass>` unwrapping before calling
- This complexity makes bridging Swift to Objective-C direct methods difficult

### Proposed Solution Benefits

By moving nil checks from implementations to caller-side thunks:
- **Reduced code size**: Eliminate redundant nil checks in implementations
- **Better linkage**: Expose public symbols for cross-TU calls
- **Simpler Swift interop**: Swift can emit implementations without complex nil-check handling

---

## Design Overview

### Core Concept: Split Responsibilities

The optimization splits responsibilities between the **callee** (method implementation) and the **caller** (call site):

```
┌─────────────────────────────────────────────────────────────┐
│                   BEFORE (Current Design)                    │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Implementation: @"\01-[Class method]" (hidden)              │
│  ┌──────────────────────────────────────────────┐           │
│  │ if (self == nil) return 0;  ← Nil check      │           │
│  │ // actual implementation                     │           │
│  └──────────────────────────────────────────────┘           │
│                                                               │
│  Call Sites: ALL call the hidden symbol directly            │
│  - Even non-null receivers pay nil-check cost                │
│                                                               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   AFTER (New Design)                         │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  True Implementation: @"-[Class method]" (public)            │
│  ┌──────────────────────────────────────────────┐           │
│  │ // actual implementation (NO nil check)      │           │
│  └──────────────────────────────────────────────┘           │
│                                                               │
│  Thunk: @"-[Class method]_thunk" (linkonce_odr)             │
│  ┌──────────────────────────────────────────────┐           │
│  │ if (self == nil) return 0;                   │           │
│  │ musttail call @"-[Class method]"(self, ...); │           │
│  └──────────────────────────────────────────────┘           │
│                                                               │
│  Call Sites:                                                 │
│  - Non-null receivers → direct call to implementation       │
│  - Nullable receivers → call thunk                          │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### Key Design Elements

#### 1. Compiler Flag
- Feature gated by: **`-fobjc-expose-direct-methods`**
- Only applies to NeXT runtime family
- Backward compatible: without flag, old behavior is preserved

#### 2. Instance Methods

**True Implementation (Callee):**
- **Symbol**: Public, no `\01` prefix (e.g., `@"-[MyClass myMethod]"`)
- **Linkage**: `external` (visible across TUs within the same linkage unit)
- **Visibility**: `hidden` (NOT exported from dylib - preserves ABI encapsulation)
- **Logic**: Contains ONLY the method implementation, NO nil check

**Rationale for hidden visibility:**
- `objc_direct` is often used to keep methods internal to avoid ABI pollution
- `ExternalLinkage` allows cross-TU calls within the same build product
- `HiddenVisibility` prevents symbols from being exported in the dylib export trie
- This preserves the original intent of `objc_direct` while enabling cross-TU usage

**Call Site (Caller):**
- **Case 1 - Non-null receiver**: Direct call to public symbol
  - Examples: `self`, `_Nonnull` annotated, class objects
- **Case 2 - Nullable receiver**: Call to caller-side thunk

**Thunk (Generated by Caller):**
- **Symbol**: Implementation symbol + `_thunk` suffix
- **Linkage**: `linkonce_odr` (linker deduplicates identical thunks)
- **Logic**:
  1. Check `if (self == nil)` → return zero-initialized value
  2. Otherwise → `musttail call` to true implementation
- **Critical**: `musttail` is required for ARC correctness (makes thunk "invisible" to ARC)

#### 3. Class Methods

**DESIGN (Full Thunk-Based Approach)**: Class methods follow the same pattern as instance methods - the true implementation contains NO nil check and NO class realization. This is the chosen design for consistency and maximum optimization.

**True Implementation (Callee):**
- **Symbol**: Public, no `\01` prefix (e.g., `@"+[MyClass myMethod]"`)
- **Linkage**: `external` (visible across TUs)
- **Visibility**: `hidden` (NOT exported from dylib)
- **Logic**: Contains ONLY the method implementation, **NO nil check**, **NO class realization**

**Call Site (Caller):**
- **Case 1 - Class is realized and non-null**: Direct call to public symbol
  - Examples: After instance method call on same class dominates the call site
  - After explicit class realization in same control flow
- **Case 2 - Class may be unrealized or null**: Call to caller-side thunk

**Thunk (Generated by Caller):**
- **Symbol**: Implementation symbol + `_thunk` suffix
- **Linkage**: `linkonce_odr`
- **Logic** (order is critical):
  1. **First**: Perform class realization: `(void)[self self];`
  2. **Second**: Check `if (self == nil)` → return zero-initialized value (only for weak-linked classes)
  3. **Third**: `musttail call` to true implementation

**Rationale for removing class realization from implementation:**
- **Consistency**: Same pattern as instance methods (clean separation of concerns)
- **Optimization**: Caller can optimize away class realization when provably unnecessary
- **Simplicity**: No special-casing for class vs instance methods in implementation
- **Thunk responsibility**: Thunk handles both class realization AND nil-check concerns

**Static Analysis for Class Methods:**
The caller needs to determine if:
1. **Is the class already realized?**
   - Has an instance method on the same class been called in a dominating path?
   - **Important**: `[Parent foo]` does NOT realize `Child` (inheritance care needed)
   - **Conservative**: Assume unrealized unless proven otherwise

2. **Can the class be nil?**
   - Is the class weak-linked? (`isWeakLinkedClass(OID)`)
   - Only weak-linked classes can be nil at runtime
   - Non-weak-linked classes are non-null after initialization

**Dispatch Decision:**
- If class is **both** realized AND non-null → direct call to implementation
- Otherwise → call thunk (which does realization + optional nil check)

**Note**: Initial implementation can conservatively always use thunks for class methods, then optimize later with better static analysis.

**Alternative Simpler Approach (Mentioned in Design Document):**
An alternative, simpler design would be to keep class realization IN the implementation with conditional nil checks. This solves the linkage problem without the complexity of thunks for class methods, at the cost of not optimizing away class realization. However, **we have chosen the full thunk-based approach** for consistency and maximum optimization potential.

#### 4. Special Case: Variadic Methods

**Problem**: Variadic methods cannot use thunks because:
- Thunk design requires `musttail` call (for ARC)
- `musttail` forbids stack management (incompatible with `va_start`/`va_end`)

**Solution**: Variadic methods get exposed symbols WITHOUT nil checks in implementation. The caller emits an inline nil check:
- **Symbol**: Public, no `\01` prefix (e.g., `@"-[MyClass varMethod:]"`)
- **Linkage**: `external` (visible across TUs)
- **Visibility**: `hidden` (NOT exported from dylib)
- **Nil checks**: **NOT in implementation** (moved to caller)
- **Caller behavior**: Emits inline nil check, then calls exposed implementation

**Rationale**: Variadic methods benefit from the same optimization (nil check removal from implementation), but since thunks can't be used due to `musttail` restrictions, the caller must emit the nil check inline before the call. This still achieves the goal of allowing non-null call sites to skip the nil check overhead.

#### 5. Nullability Analysis

To determine whether to call implementation directly or via thunk, we need static analysis of receivers:

**Provably Non-null Cases:**
1. `_Nonnull` attribute on receiver type
2. `self` parameter in instance methods
3. Class objects (type is `Class` or `id<Protocol> class`)
4. Results of `alloc`, `new` (future enhancement)
5. ObjC literals: `@"string"`, `@42`, etc. (future enhancement)

**Conservative Approach**: Default to using thunk unless definitively non-null.

---

## Implementation Phases

### Status Key
- ✅ **COMPLETED**: Implemented and tested
- 🚧 **IN PROGRESS**: Currently being worked on
- ⏸️ **PENDING**: Not yet started, waiting on dependencies
- ❌ **BLOCKED**: Cannot proceed due to issues

---

### Phase 0: Infrastructure and Compiler Flag ✅ **COMPLETED**

**Objective**: Add compiler flag and CodeGen option infrastructure.

#### Files Modified:
- `/home/peterrong/llvm-project/clang/include/clang/Basic/CodeGenOptions.def`
- `/home/peterrong/llvm-project/clang/include/clang/Driver/Options.td`

#### Changes:

1. **Add CodeGen option** (`CodeGenOptions.def`):
```cpp
CODEGENOPT(ObjCExposeDirectMethods, 1, 0, Benign)
///< Expose objc_direct method symbols publicly and optimize nil checks.
```

2. **Add compiler flag** (`Options.td`):
```cpp
defm objc_expose_direct_methods : BoolFOption<"objc-expose-direct-methods",
  CodeGenOpts<"ObjCExposeDirectMethods">, DefaultFalse,
  PosFlag<SetTrue, [], [ClangOption, CC1Option],
          "Expose direct method symbols and move nil checks to caller-side thunks">,
  NegFlag<SetFalse>>;
```

**Note**: Using the flag name `-fobjc-expose-direct-methods` with internal CodeGenOption `ObjCExposeDirectMethods`.

#### Tests Created:
- `clang/test/CodeGenObjC/expose-direct-method-flag.m` (flag recognition test - verifies flag is recognized by compiler)

**Note**: Multiple redundant test files were consolidated in Phase 1 to reduce duplication:
- ~~`expose-direct-method-stub-dispatch.m`~~ (deleted - functionality merged into main test)
- ~~`expose-direct-method-thunks.m`~~ (deleted - functionality merged into main test)
- `expose-direct-method.m` (consolidated test covering all basic functionality, stub dispatch, and thunk generation)

#### Validation:
```bash
# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang
```

---

### Phase 1: Modify Method Implementation Generation ✅ **COMPLETED**

**Objective**: Change how direct method implementations are emitted when optimization is enabled.

#### Key Design Decision: Function Separation

To improve code organization and facilitate thunk generation in Phase 3, the precondition check logic has been refactored into a separate function:

- **`GenerateDirectMethodsPreconditionCheck()`**: Handles `[self self]` for class methods and nil checks
- **`GenerateDirectMethodPrologue()`**: Handles actual prologue work (like `_cmd` synthesis)

**Design Pattern:**
- **With flag enabled (`shouldExposeSymbol == true`)**:
  - True implementation calls only `GenerateDirectMethodPrologue()` (no preconditions)
  - Thunk will call `GenerateDirectMethodsPreconditionCheck()` (in Phase 3)
- **Without flag (`shouldExposeSymbol == false`)**:
  - `GenerateDirectMethodPrologue()` dispatches to `GenerateDirectMethodsPreconditionCheck()`
  - Then performs its own prologue work
  - This maintains backward compatibility

**Rationale**: This separation of concerns makes the code cleaner, more maintainable, and enables thunks to easily reuse the precondition check logic without code duplication.

#### Files Modified:
- `/home/peterrong/llvm-project/clang/include/clang/AST/DeclObjC.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCRuntime.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCRuntime.cpp`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCMac.cpp`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjC.cpp`

#### Changes:

**1. Add eligibility check** (`DeclObjC.h`):
```cpp
/// Check if this method can have nil-check thunk optimization.
bool canHaveNilCheckThunk() const {
  // Variadic functions cannot use thunks (musttail incompatible with va_arg)
  // musttail is primarily supported on arm64 (Apple platforms)
  return isDirectMethod() && !isVariadic();
}
```

**Note**: Platform-specific musttail support should also be checked in CodeGenModule, though this is primarily relevant for arm64/Apple platforms where objc_direct is most commonly used.

**2. Add optimization checks** (`CodeGenModule.h`):
```cpp
/// Check if a direct method should have its symbol exposed (no \01 prefix).
/// This applies to ALL direct methods (including variadic).
/// Returns false if OMD is null or not a direct method.
bool shouldExposeSymbol(const ObjCMethodDecl *OMD) const {
  return OMD &&
         OMD->isDirectMethod() &&
         getLangOpts().ObjCRuntime.isNeXTFamily() &&
         getCodeGenOpts().ObjCExposeDirectMethods;
}

/// Check if a direct method should use nil-check thunks at call sites.
/// This applies only to non-variadic direct methods.
/// Variadic methods cannot use thunks (musttail incompatible with va_arg).
/// Returns false if OMD is null or not eligible for thunks.
bool shouldHaveNilCheckThunk(const ObjCMethodDecl *OMD) const {
  return OMD &&
         shouldExposeSymbol(OMD) &&
         OMD->canHaveNilCheckThunk();
}

/// Check if a direct method should have inline nil checks at call sites.
/// This applies to direct methods that cannot use thunks (e.g., variadic methods).
/// These methods get exposed symbols but need inline nil checks instead of thunks.
/// Returns false if OMD is null or not eligible for inline nil checks.
bool shouldHaveNilCheckInline(const ObjCMethodDecl *OMD) const {
  return OMD &&
         shouldExposeSymbol(OMD) &&
         !OMD->canHaveNilCheckThunk();
}
```

**Note**: By including null checks and `isDirectMethod()` checks in these helper methods, we eliminate redundant checks at call sites. Call sites can simply use `if (CGM.shouldExposeSymbol(Method))` instead of `if (Method && Method->isDirectMethod() && CGM.shouldExposeSymbol(Method))`.

**3. Refactor symbol name generation** (`CGObjCRuntime.h/cpp`):
```cpp
// Merge overloads with default parameter
std::string getSymbolNameForMethod(const ObjCMethodDecl *method,
                                   bool includeCategoryName = true,
                                   bool includePrefixByte = true);
```
- Allows removing `\01` prefix when optimization is enabled

**4. Modify `GenerateDirectMethod()`** (`CGObjCMac.cpp`):
```cpp
bool ExposeSymbol = CGM.shouldExposeSymbol(OMD);

// Generate symbol without \01 prefix when optimization enabled
auto Name = getSymbolNameForMethod(OMD, /*includeCategoryName*/ false,
                                   /*includePrefixByte*/ !ExposeSymbol);

// ALWAYS use ExternalLinkage for true implementation
Fn = llvm::Function::Create(MethodTy, llvm::GlobalValue::ExternalLinkage,
                            Name, &CGM.getModule());
```

**5. Refactor `GenerateDirectMethodPrologue()` and Extract `GenerateDirectMethodsPreconditionCheck()`** (`CGObjCMac.cpp`):

To improve code organization and facilitate thunk generation in Phase 3, the precondition check logic has been separated into a new function:

**New Function: `GenerateDirectMethodsPreconditionCheck()`**
```cpp
void CGObjCCommonMac::GenerateDirectMethodsPreconditionCheck(
    CodeGenFunction &CGF, llvm::Function *Fn, const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD) {

  // For class methods: perform [self self] for class realization
  if (OMD->isClassMethod()) {
    const ObjCInterfaceDecl *OID = cast<ObjCInterfaceDecl>(CD);
    // ... perform [self self] for class realization ...
    ReceiverCanBeNull = isWeakLinkedClass(OID);
  }

  // Generate nil check for potentially nullable receivers
  if (ReceiverCanBeNull) {
    // ... generate nil check code ...
  }
}
```

**Refactored: `GenerateDirectMethodPrologue()`**
```cpp
void CGObjCCommonMac::GenerateDirectMethodPrologue(
    CodeGenFunction &CGF, llvm::Function *Fn, const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD) {

  bool shouldExposeSymbol = CGM.shouldExposeSymbol(OMD);

  // Generate precondition checks (class realization + nil check) if needed
  // Without flag: precondition checks are in the implementation
  // With flag: precondition checks will be in the thunk (not here)
  if (!shouldExposeSymbol) {
    GenerateDirectMethodsPreconditionCheck(CGF, Fn, OMD, CD);
  }

  // Only synthesize _cmd if it's referenced
  // This is the actual "prologue" work that always happens
  if (OMD->getCmdDecl()->isUsed()) {
    // ... synthesize _cmd ...
  }
}
```

**Design Pattern:**
- **With flag enabled (`shouldExposeSymbol == true`)**:
  - True implementation calls only `GenerateDirectMethodPrologue()` (no preconditions)
  - Thunk will call `GenerateDirectMethodsPreconditionCheck()` (in Phase 3)
- **Without flag (`shouldExposeSymbol == false`)**:
  - `GenerateDirectMethodPrologue()` dispatches to `GenerateDirectMethodsPreconditionCheck()`
  - Then performs its own prologue work
  - This maintains backward compatibility

**IMPORTANT**: With this change, when optimization is enabled:
- **Instance methods**: NO nil check in implementation
- **Class methods**: NO class realization AND NO nil check in implementation
- Both will be handled by thunks at call sites (to be implemented in Phase 3)

This follows the **full thunk-based approach** as described in the design section above, ensuring consistency between instance and class methods and enabling maximum optimization.

**Rationale for Separation**: Extracting precondition checks into a separate function makes the code cleaner, more maintainable, and enables thunks to easily reuse the precondition check logic without code duplication.

**6. Update visibility to respect source attributes** (`CGObjC.cpp`):
```cpp
if (OMD->isDirectMethod()) {
    // IMPORTANT: Respect explicit visibility attributes from source
    // Default behavior: Use hidden visibility for objc_direct methods
    // - ExternalLinkage allows cross-TU calls within the same build product
    // - HiddenVisibility prevents dylib export (preserves ABI encapsulation)
    //
    // OVERRIDE: If method has explicit visibility("default") attribute,
    // use default visibility to allow dylib export
    //
    // Check for explicit visibility attribute
    if (OMD->hasAttr<VisibilityAttr>()) {
      auto *VA = OMD->getAttr<VisibilityAttr>();
      if (VA->getVisibility() == VisibilityAttr::Default) {
        Fn->setVisibility(llvm::Function::DefaultVisibility);
      } else {
        Fn->setVisibility(llvm::Function::HiddenVisibility);
      }
    } else {
      // No explicit attribute: default to hidden
      Fn->setVisibility(llvm::Function::HiddenVisibility);
    }
    // ... rest of code
}
```

**Thunk Visibility Inheritance**:
Thunks must inherit the same visibility as their corresponding implementations. This ensures:
- Hidden methods get hidden thunks (not exported from dylib)
- Exported methods with `visibility("default")` get exported thunks
- Consistent visibility across implementation and thunk prevents linker issues

Implementation in `GenerateThunkForDirectMethod()`:
```cpp
// Thunk inherits visibility from implementation
Thunk->setVisibility(Implementation->getVisibility());
```

#### Key Design Decisions:
- **External linkage + Hidden visibility**: Cross-TU calls without dylib export pollution
- **Remove class realization from class methods**: When optimization enabled, class method implementations have NO `[self self]` call - it will be done in the thunk
- **Variadic exclusion**: Explicitly check `!isVariadic()`
- **musttail platform guard**: Check platform support (primarily arm64/Apple platforms)

#### Tests Created:
- `clang/test/CodeGenObjC/expose-direct-method-disabled.m` (backward compatibility)
- `clang/test/CodeGenObjC/expose-direct-method-varargs.m` (variadic exclusion)
- `clang/test/CodeGenObjC/expose-direct-method.m` (main test, currently XFAIL'd)

#### Validation:
```bash
# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang
```

---

### Phase 2: Stub Dispatch Helper Functions ✅ **COMPLETED**

**Objective**: Create stub implementations of dispatch helper functions to enable end-to-end feature completion. These will be optimized in Phase 6.

**Rationale**:
- These functions are **optimizations, not required for correctness**
- By conservatively returning `false`, we always use thunks (safest approach)
- This allows us to complete Phases 3-6 and get the feature working end-to-end
- Actual optimization logic can be implemented and tested separately in Phase 6

#### Files Modified:
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-stub-dispatch.m`

#### Changes:

**Design Decision: Reuse Existing `canMessageReceiverBeNull` Infrastructure**

Instead of creating new functions, we'll enhance the existing `canMessageReceiverBeNull` in `CGObjCRuntime`:
- The base class already has good nullability analysis logic
- `CGObjCCommonMac` can override to add NeXT-runtime-specific heuristics
- This follows OOP principles and avoids code duplication

**1. Make `canMessageReceiverBeNull` virtual** (`CGObjCRuntime.h`):

```cpp
/// Check if the receiver of an ObjC message send can be null.
/// Returns true if the receiver may be null, false if provably non-null.
///
/// This can be overridden by subclasses to add runtime-specific heuristics.
/// Base implementation checks:
/// - Super dispatch (always non-null)
/// - Self in const-qualified methods (ARC)
/// - Weak-linked classes
///
/// Future enhancements in CGObjCCommonMac override:
/// - _Nonnull attributes
/// - Results of alloc, new, ObjC literals
virtual bool canMessageReceiverBeNull(CodeGenFunction &CGF,
                              const ObjCMethodDecl *method, bool isSuper,
                              const ObjCInterfaceDecl *classReceiver,
                              llvm::Value *receiver);
```

**2. Add class realization check** (`CGObjCRuntime.h`):

```cpp
/// Check if a class object can be unrealized (not yet initialized).
/// Returns true if the class may be unrealized, false if provably realized.
///
/// STUB IMPLEMENTATION: Base class always returns true (conservative).
/// Subclasses can override to add runtime-specific dominating-call analysis.
///
/// Future: Returns false if:
/// - An instance method on the same class was called in a dominating path
/// - The class was explicitly realized earlier in control flow
/// - Note: [Parent foo] does NOT realize Child (inheritance care needed)
virtual bool canClassObjectBeUnrealized(const ObjCInterfaceDecl *ClassDecl,
                                        CodeGenFunction &CGF) const;
```

**3. Add stub implementation in base class** (`CGObjCRuntime.cpp`):

```cpp
bool CGObjCRuntime::canClassObjectBeUnrealized(
    const ObjCInterfaceDecl *ClassDecl, CodeGenFunction &CGF) const {
  // STUB: Base implementation always returns true (conservative).
  // Subclasses can override to add runtime-specific analysis.
  // This means class method thunks will always perform class realization,
  // which is safe (realizing an already-realized class is a no-op).
  return true;
}
```

**4. Usage in CodeGen** (`CGObjC.cpp` and other call sites):

Call sites will directly use the runtime methods:

```cpp
// Check if receiver can be null (returns true if nullable)
bool receiverCanBeNull = CGM.getObjCRuntime().canMessageReceiverBeNull(
    CGF, Method, IsSuper, ClassReceiver, Receiver);

if (!receiverCanBeNull) {
  // Receiver is provably non-null: call implementation directly
  // ...
} else {
  // Receiver may be null: use thunk
  // ...
}

// Check if class can be unrealized (returns true if may be unrealized)
bool classCanBeUnrealized = CGM.getObjCRuntime().canClassObjectBeUnrealized(
    ClassDecl, CGF);

if (!classCanBeUnrealized) {
  // Class is provably realized: skip realization in thunk
  // ...
} else {
  // Class may be unrealized: perform realization
  // ...
}
```

No wrapper functions needed in `CodeGenModule` - just directly call the runtime.

#### Why This Approach Works:

**For `canMessageReceiverBeNull`:**
- Returning `true` → all instance method calls use thunks
- Thunks perform nil check (safe, just not optimized)
- No correctness issues, just missed optimization opportunities

**For `canClassObjectBeUnrealized`:**
- Returning `true` → all class method thunks perform `[self self]` realization
- Safe because realizing an already-realized class is a no-op
- No correctness issues, just potentially redundant class realization

#### Test Created:
- No new tests needed (stubs don't change behavior)
- Tests in Phases 3-6 will work with conservative approach

#### Validation:
```bash
# Should compile successfully
ninja -C build-debug clang
```

---

### Phase 3: Implement Thunk Generation ✅ **COMPLETED**

**Objective**: Generate nil-check thunks for nullable receivers, both for methods defined in the current TU and for cross-TU calls.

#### Summary of Accomplishments:

Phase 3 successfully implemented the complete thunk generation infrastructure, enabling caller-side nil-check thunks for direct methods. This phase introduced several architectural improvements:

**Key Achievements:**
1. **DirectMethodInfo Structure**: Created a unified cache structure storing both Implementation and Thunk together, enabling atomic updates when type covariance causes implementation replacement
2. **Thunk Generation**: Implemented `GenerateObjCDirectThunk()` which creates linkonce_odr thunks with proper nil-checking logic and musttail calls
3. **Dispatch Logic**: Added `GetDirectMethodCallee()` to centralize decision-making for whether to call implementation directly or via thunk
4. **Lifecycle Management**: Introduced `StartObjCDirectThunk()`/`FinishObjCDirectThunk()` borrowed from C++ vtable thunks for proper function generation
5. **Integration**: Partially integrated thunk dispatch into `EmitMessageSend()` in `CGObjCMac.cpp`
6. **Comprehensive Testing**: Added extensive tests covering:
   - Basic instance and class methods
   - Property accessors (direct properties)
   - Methods in extensions and categories
   - Complex return types (structs, aggregates, sret)
   - Cross-TU calls (methods declared but not defined in current TU)
   - Type covariance scenarios

**Technical Details:**
- Thunks use `linkonce_odr` linkage for linker deduplication across TUs
- `musttail` calls ensure ARC transparency
- Thunks reuse `GenerateDirectMethodsPreconditionCheck()` from Phase 1 for class realization and nil checks
- Proper attribute copying ensures calling convention and parameter attributes match between thunk and implementation

**What Works:**
- Non-variadic direct methods generate both implementation and thunk
- Call sites can choose between implementation and thunk based on nullability flags
- Cross-TU calls generate thunks on-demand
- Type covariance correctly regenerates thunks when implementation types change

#### Files Modified:
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCMac.cpp`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenFunction.h`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/direct-method-ret-mismatch.m`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-stub-dispatch.m` (deleted - merged into main test)
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-varargs.m`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method.m`

#### Design Overview:

**Key Insight**: `GenerateDirectMethod()` has two different usage patterns that need different return values:
1. **Body Generation** (`GenerateMethod`): Needs TRUE IMPLEMENTATION (where method body is emitted)
2. **Call Sites** (`EmitMessageSend`): Needs IMPLEMENTATION or THUNK (based on nullability)

**Solution**: Change `GenerateDirectMethod()` to return `DirectMethodInfo&` (containing both), add new `GetDirectMethodCallee()` for call sites.

#### Changes:

**1. Update DirectMethodDefinitions cache structure** (`CGObjCMac.cpp`):

```cpp
// BEFORE (old structure):
llvm::DenseMap<const ObjCMethodDecl *, llvm::Function *> DirectMethodDefinitions;

// AFTER (new structure):
/// Information about a direct method definition
struct DirectMethodInfo {
  llvm::Function *Implementation;  // The true implementation (where body is emitted)
  llvm::Function *Thunk;            // The nil-check thunk (nullptr if not generated)

  DirectMethodInfo(llvm::Function *Impl)
    : Implementation(Impl), Thunk(nullptr) {}
};

llvm::DenseMap<const ObjCMethodDecl *, DirectMethodInfo> DirectMethodDefinitions;
```

**Rationale**: When Objective-C type covariance causes implementation replacement, we must also replace the thunk to maintain musttail compatibility. Storing both together enables atomic updates.

**2. Update GenerateMethod() to extract Implementation** (`CGObjCMac.cpp`):

```cpp
llvm::Function *CGObjCCommonMac::GenerateMethod(const ObjCMethodDecl *OMD,
                                                const ObjCContainerDecl *CD) {
  llvm::Function *Method;

  if (OMD->isDirectMethod()) {
    // Returns DirectMethodInfo& containing both Implementation and Thunk
    DirectMethodInfo& Info = GenerateDirectMethod(OMD, CD);
    Method = Info.Implementation;  // Extract implementation for body generation
  } else {
    auto Name = getSymbolNameForMethod(OMD);

    CodeGenTypes &Types = CGM.getTypes();
    llvm::FunctionType *MethodTy =
        Types.GetFunctionType(Types.arrangeObjCMethodDeclaration(OMD));
    Method = llvm::Function::Create(
        MethodTy, llvm::GlobalValue::InternalLinkage, Name, &CGM.getModule());
  }

  MethodDefinitions.insert(std::make_pair(OMD, Method));

  return Method;
}
```

**3. Modify GenerateDirectMethod() to return DirectMethodInfo&** (`CGObjCMac.cpp`):

**Key Change**: Returns reference to `DirectMethodInfo` (both Implementation and Thunk), not just the implementation function.

```cpp
DirectMethodInfo&
CGObjCCommonMac::GenerateDirectMethod(const ObjCMethodDecl *OMD,
                                      const ObjCContainerDecl *CD) {
  auto *COMD = OMD->getCanonicalDecl();
  auto I = DirectMethodDefinitions.find(COMD);
  llvm::Function *OldFn = nullptr, *Fn = nullptr;

  // ... existing code to check cache and create implementation function ...

  if (I != DirectMethodDefinitions.end()) {
    // Method already defined, get existing implementation
    OldFn = I->second.Implementation;
    // ... handle type mismatch if needed ...
  }

  // Create the implementation function
  // ... existing code to create Fn ...

  // Store in cache
  if (I == DirectMethodDefinitions.end()) {
    // First time seeing this method
    DirectMethodInfo Info(Fn);
    DirectMethodDefinitions.insert(std::make_pair(COMD, Info));
    I = DirectMethodDefinitions.find(COMD);
  } else {
    // Update existing entry
    I->second.Implementation = Fn;
    llvm::Function *OldThunk = I->second.Thunk;

    // CRITICAL: If implementation was replaced, and old thunk exists, invalidate the old thunk
    if (OldFn && OldThunk) {

      // Type mismatch occurred - regenerate thunk with correct type
      llvm::Function *NewThunk = GenerateThunkForDirectMethod(OMD, CD, Fn);

      // Replace all uses before erasing
      NewThunk->takeName(OldThunk);
      OldThunk->replaceAllUsesWith(NewThunk);
      OldThunk->eraseFromParent();

      I->second.Thunk = NewThunk;
    }
  }

  // Generate thunk if optimization is enabled (only if not already created above)
  if (CGM.shouldHaveNilCheckThunk(OMD) && !I->second.Thunk) {
    llvm::Function *Thunk = GenerateThunkForDirectMethod(OMD, CD, Fn);
    I->second.Thunk = Thunk;
  }

  // Return reference to DirectMethodInfo (contains both Implementation and Thunk)
  return I->second;
}
```

**4. Add new helper: GenerateObjCDirectThunk()** (`CGObjCMac.cpp`):

```cpp
llvm::Function *
CGObjCCommonMac::GenerateThunkForDirectMethod(
    const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD,
    llvm::Function *Implementation) {

  assert(CGM.shouldHaveNilCheckThunk(OMD) && "Should only generate thunk when optimization enabled");
  assert(Implementation && "Implementation must exist");

  // Get function type (same as implementation)
  llvm::FunctionType *ThunkTy = Implementation->getFunctionType();

  // Generate thunk name: implementation symbol + "_thunk"
  std::string ThunkName = Implementation->getName().str() + "_thunk";

  // Create thunk with linkonce_odr linkage (allows deduplication)
  llvm::Function *Thunk = llvm::Function::Create(
      ThunkTy,
      llvm::GlobalValue::LinkOnceODRLinkage,
      ThunkName,
      &CGM.getModule());

  // Set attributes
  Thunk->setVisibility(llvm::GlobalValue::HiddenVisibility);
  Thunk->setUnnamedAddr(llvm::GlobalValue::UnnamedAddr::Global);

  // CRITICAL: Copy function-level attributes from implementation
  llvm::AttributeList ImplAttrs = Implementation->getAttributes();
  Thunk->setAttributes(ImplAttrs);

  // Build argument list for StartFunction
  // CRITICAL: For musttail thunks, we MUST NOT pass regular method parameters
  // to StartFunction because that causes them to be stored in local variables
  // with storeStrong, which adds ARC retains/releases. This breaks the thunk's
  // ARC transparency!
  //
  // We only pass 'self' so we can perform the nil check on it.
  // All other parameters will be forwarded directly from Thunk->args().
  FunctionArgList FunctionArgs;
  FunctionArgs.push_back(OMD->getSelfDecl());
  // DO NOT append other parameters here - they would trigger storeStrong!

  // Get CGFunctionInfo for this method
  const CGFunctionInfo &FI = CGM.getTypes().arrangeObjCMethodDeclaration(OMD);

  // Create a CodeGenFunction to generate the thunk body
  // This gives us access to helper functions like GenerateDirectMethodsPreconditionCheck
  CodeGenFunction CGF(CGM);
  CGF.CurFuncDecl = OMD;
  CGF.CurCodeDecl = OMD;

  // Start the function with CORRECT return type (not VoidTy!)
  // This sets up the function prologue, entry block, allocas, etc.
  CGF.StartFunction(GlobalDecl(OMD), OMD->getReturnType(), Thunk, FI, FunctionArgs,
                    OMD->getLocation(), OMD->getLocation());

  // REUSE Phase 1's precondition check logic!
  // This generates: [self self] for class methods + nil check
  GenerateDirectMethodsPreconditionCheck(CGF, Thunk, OMD, CD);

  // After precondition check, make musttail call to implementation
  // Get all arguments
  SmallVector<llvm::Value*, 8> Args;
  for (auto &Arg : Thunk->args())
    Args.push_back(&Arg);

  // Create musttail call
  llvm::CallInst *Call = CGF.Builder.CreateCall(Implementation, Args);
  Call->setTailCallKind(llvm::CallInst::TCK_MustTail);
  Call->setCallingConv(Implementation->getCallingConv());

  // Return the result (or void)
  if (FI.getReturnInfo().isIndirect()) {
    // SRet case: return void
    CGF.Builder.CreateRetVoid();
  } else {
    llvm::Type *RetTy = ThunkTy->getReturnType();
    if (RetTy->isVoidTy())
      CGF.Builder.CreateRetVoid();
    else
      CGF.Builder.CreateRet(Call);
  }

  // Finish the function - emits epilogue, cleanup, etc.
  // This is REQUIRED to properly finalize the function
  CGF.FinishFunction();

  // Return the thunk (caller will cache it)
  return Thunk;
}
```

**5. Add new dispatch function: GetDirectMethodCallee()** (`CGObjCMac.cpp`):

This function centralizes the decision logic for choosing between implementation and thunk at call sites.

```cpp
llvm::Function *
CGObjCCommonMac::GetDirectMethodCallee(const ObjCMethodDecl *OMD,
                                       const ObjCContainerDecl *CD,
                                       bool ReceiverCanBeNull,
                                       bool ClassObjectCanBeUnrealized) {
  DirectMethodInfo& Info = GenerateDirectMethod(OMD, CD);

  // If optimization not enabled, always use implementation (which includes the nil check)
  if (!CGM.shouldExposeSymbol(OMD)) {
    return Info.Implementation;
  }

  // Variadic methods don't have thunk, the caller needs to inline the nil check
  if (CGM.shouldHaveNilCheckInline(OMD)) {
    return Info.Implementation;
  }

  assert(CGM.shouldHaveNilCheckThunk(OMD));

  if (OMD->isInstanceMethod()) {
    // If we can prove instance method's receiver is not null, return the true implementation
    return ReceiverCanBeNull ? Info.Thunk : Info.Implementation;
  } else if (OMD->isClassMethod()) {
    // For class methods, it needs to be non-null and realized before we dispatch to true implementation
    return (ReceiverCanBeNull || ClassObjectCanBeUnrealized)
               ? Info.Thunk
               : Info.Implementation;
  } else {
    assert(false && "OMD should either be a class method or instance method");
  }
}
```

**Key Simplifications from Original Plan:**
- ✅ **Single source of truth**: All dispatch logic in one place
- ✅ **Simpler interface**: Callers just pass nullability flags, not complex expressions
- ✅ **Clearer logic**: Easy to understand the decision tree
- ✅ **Better separation**: Nullability analysis is done by the caller, dispatch is done here

**6. Add thunk lifecycle helpers** (`CodeGenFunction.h` and `CGObjCMac.cpp`):

Borrowed from C++ vtable thunks in `CGVTables.cpp`, these helpers properly manage thunk function generation:

```cpp
/// Start an Objective-C direct method thunk.
void CodeGenFunction::StartObjCDirectThunk(const ObjCMethodDecl *OMD,
                                           llvm::Function *Fn,
                                           const CGFunctionInfo &FnInfo,
                                           const FunctionArgList &Args) {
  // Similar to StartThunk() for C++ virtual methods
  // Sets up function state without requiring an AST body
  StartFunction(GlobalDecl(), OMD->getReturnType(), Fn, FnInfo, Args,
                OMD->getLocation(), OMD->getLocation());

  // Manually set the decl so other utilities can access the AST
  CurCodeDecl = OMD;
  CurFuncDecl = OMD;
}

/// Finish an Objective-C direct method thunk.
void CodeGenFunction::FinishObjCDirectThunk() {
  // Create dummy unreachable block (removed by optimizer)
  EmitBlock(createBasicBlock());

  // Disable final ARC autorelease (thunk uses musttail)
  AutoreleaseResult = false;

  // Restore invariants
  CurCodeDecl = nullptr;
  CurFuncDecl = nullptr;

  FinishFunction();
}
```

**Architectural Improvements over Original Plan:**
- ✅ **`DirectMethodInfo` struct**: Stores Implementation + Thunk together for atomic updates
- ✅ **Better type covariance handling**: When implementation is replaced, thunk is also regenerated
- ✅ **Cleaner separation**: `GenerateDirectMethod()` for generation, `GetDirectMethodCallee()` for dispatch
- ✅ **Reuses Phase 1 code**: Thunks call `GenerateDirectMethodsPreconditionCheck()`
- ✅ **Proper lifecycle management**: `StartObjCDirectThunk()` / `FinishObjCDirectThunk()` borrowed from C++ thunks

#### Critical Implementation Details:

**1. LinkOnceODR Linkage**
- Multiple translation units may generate identical thunks
- Linker will deduplicate them (keeping one definition)
- `UnnamedAddr::Global` allows more aggressive optimization

**2. MustTail Call**
- **Critical for ARC**: Makes thunk transparent to ARC optimizer
- Ensures no ARC operations between thunk and implementation
- Requirements:
  - Return type must match
  - Calling convention must match
  - All arguments must be forwarded

**3. Class Realization (Class Methods) - NEW DESIGN**

According to the updated design, class method thunks should:
1. **First**: Perform class realization via `[self self]`
2. **Second**: Check if self == nil (only for weak-linked classes)
3. **Third**: musttail call to implementation

**Order is important**: Class realization happens BEFORE nil check.

**IMPORTANT NOTE**: The current implementation (Phases 0-1) follows the **simpler alternative** where class methods:
- Keep class realization IN the implementation
- Skip nil checks when optimization enabled (unless weak-linked)
- Do NOT use thunks

If/when implementing full thunk support for class methods (future work), follow this pattern:
```cpp
// Thunk for class method:
// Step 1: Realize the class
(void)[self self];

// Step 2: Check if class is nil (only for weak-linked classes)
if (self == nil && isWeakLinkedClass(OID))
  return zero_value;

// Step 3: musttail call to true implementation (which has NO realization, NO nil check)
musttail call @"+[Class method]"(self, ...);
```

**4. Return Value Handling**
- Void methods: `ret void`
- Primitive types: return zero (`0`, `0.0`, etc.)
- Pointer types: return null (`nullptr`)
- Struct types: return zero-initialized struct

#### Edge Cases to Handle:

1. **Methods with struct return types**
   - May use sret (struct return) parameter
   - Must correctly forward sret parameter in musttail call

2. **Methods with complex attributes**
   - Copy relevant attributes from implementation to thunk
   - Examples: `nounwind`, `readonly`, `willreturn`

3. **Variadic methods**
   - Should NOT reach thunk generation (filtered in Phase 1)
   - Add assertion: `assert(!OMD->isVariadic())`

#### Testing:
```cpp
// Test struct return
struct Point { int x, y; };
- (struct Point)getPoint __attribute__((objc_direct));

// Test void return
- (void)doSomething __attribute__((objc_direct));

// Test pointer return
- (id)getObject __attribute__((objc_direct));
```

---

### Phase 4: Integrate Call Site Logic and Variadic Methods ✅ **COMPLETED**

**Objective**: Update call sites to use `GetDirectMethodCallee()` which decides whether to call implementation or thunk based on nullability. Additionally, implement inline nil checks for variadic methods which cannot use thunks.

#### Summary of Accomplishments:

Phase 4 successfully completed the integration of variadic method handling with inline nil checks, addressing all the requirements:

**Key Achievements:**
1. **Variadic Method Inline Nil Checks**: Implemented inline nil check emission for variadic direct methods using the existing `NullReturnState` infrastructure
2. **Class Realization for Variadic Class Methods**: Added class realization via `GenerateClassRealization()` helper for variadic class methods before nil checks
3. **Code Refactoring**: Extracted `GenerateClassRealization()` helper function to eliminate code duplication between `EmitMessageSend` and `GenerateDirectMethodsPreconditionCheck`
4. **Fixed Edge Case**: Ensured nil checks are emitted for variadic methods even when return value is unused (e.g., void methods)
5. **Clean Code Flow**: Separated class realization (happens early) from nil check decision (happens after `Return.isUnused()` logic)

#### What Works:
- ✅ Variadic instance methods with nullable receivers get inline nil checks
- ✅ Variadic class methods perform class realization before nil checks
- ✅ Non-variadic direct methods use thunk dispatch via `GetDirectMethodCallee()`
- ✅ Variadic methods with void return correctly emit nil checks
- ✅ Variadic methods with non-null receivers (self) skip nil checks
- ✅ Class realization code is shared via helper function (no duplication)

#### Files Modified/To Modify:
- ✅ `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCMac.cpp` (GetDirectMethodCallee implemented, EmitMessageSend partially updated)
- ⏸️ `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjC.cpp` (may need updates for call site emission)
- ⏸️ `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-varargs.m` (expand tests for variadic inline nil checks)

#### Changes:

**Note**: The implemented version of `GetDirectMethodCallee()` has a simpler signature than originally planned:

```cpp
// Implemented signature (simpler):
llvm::Function *GetDirectMethodCallee(
    const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD,
    bool ReceiverCanBeNull,
    bool ClassObjectCanBeUnrealized);

// vs. Original plan (more complex):
llvm::Function *GetDirectMethodCallee(
    const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD,
    llvm::Value *Receiver,
    bool IsSuper,
    const ObjCInterfaceDecl *ClassReceiver,
    CodeGenFunction &CGF);
```

**Why the change is better:**
- Simpler interface: caller performs nullability analysis, GetDirectMethodCallee just dispatches
- Better separation of concerns: analysis vs. dispatch
- Easier to test and reason about

**2. Implementation in EmitMessageSend** (`CGObjCMac.cpp`):

The implementation integrates directly into `EmitMessageSend()` in `CGObjCMac.cpp`:

```cpp
// In EmitMessageSend (around line 2100)

if (Method && Method->isDirectMethod()) {
    bool ClassObjectCanBeUnrealized =
        Method->isClassMethod() &&
        canClassObjectBeUnrealized(ClassReceiver, CGF);

    // Use GetDirectMethodCallee to decide whether to use implementation or thunk
    // This handles:
    // - Cache lookup in DirectMethodDefinitions
    // - Creating function declarations for cross-TU calls
    // - Deciding implementation vs thunk based on nullability
    Fn = GetDirectMethodCallee(Method, Method->getClassInterface(),
                               ReceiverCanBeNull, ClassObjectCanBeUnrealized);

    // Direct methods synthesize _cmd internally, don't need to pass it
    RequiresSelValue = false;

    // ... rest of call emission ...
}
```

**Why This Implementation is Clean:**
- ✅ `GetDirectMethodCallee()` handles all complexity internally:
  - Cache lookups in `DirectMethodDefinitions` map
  - Creating function declarations for cross-TU calls (methods defined elsewhere)
  - Deciding whether to return Implementation or Thunk based on nullability
- ✅ Integrates naturally into existing message send infrastructure
- ✅ Reuses existing `ReceiverCanBeNull` calculation from earlier in `EmitMessageSend`
- ✅ Works seamlessly with existing `NullReturnState` for variadic methods
- ✅ No code duplication - single source of truth in `GetDirectMethodCallee()`

**Cross-TU Handling:**
When a direct method is declared but not defined in the current translation unit, `GenerateDirectMethod()` (called by `GetDirectMethodCallee()`) automatically creates a function declaration with the correct external linkage and hidden visibility. The linker will resolve this to the actual implementation in another object file.

#### Implementation Details:

**Handle Variadic Methods (Special Case)**

Variadic methods are excluded from the thunk optimization (`!canHaveNilCheckThunk()`), but still get exposed symbols. The caller must emit an inline nil check:

**Simple Implementation - Reuse Existing Infrastructure:**

The existing `NullReturnState` infrastructure in `EmitMessageSend()` already handles inline nil checks perfectly. We just need to set `RequiresNullCheck = true` for variadic direct methods with nullable receivers.

```cpp
// In EmitMessageSend, after all the RequiresNullCheck logic:

if (CGM.shouldHaveNilCheckInline(Method)) {
  // For variadic class methods, perform class realization FIRST
  if (ClassReceiver && ClassObjectCanBeUnrealized) {
    Arg0 = GenerateClassRealization(CGF, Arg0, ClassReceiver);
    ActualArgs[0] = CallArg(RValue::get(Arg0), ActualArgs[0].Ty);
  }

  // Set RequiresNullCheck to trigger existing nil check infrastructure
  // This works even if Return.isUnused() previously reset it
  RequiresNullCheck |= ReceiverCanBeNull;
}

// Later in EmitMessageSend, the existing code handles everything:
NullReturnState nullReturn;
if (RequiresNullCheck) {
  nullReturn.init(CGF, Arg0);  // Creates nil check blocks
}
// ... emit call ...
return nullReturn.complete(...);  // Handles PHI nodes for all return types
```

**Why This Works:**

The `NullReturnState` infrastructure automatically:
- Creates basic blocks for nil and non-nil cases
- Emits the nil check: `if (receiver == nil)`
- Returns zero-initialized values for nil case
- Creates PHI nodes to merge results
- Handles all return types (void, scalar, aggregate, complex)

**No new code needed** - we just reuse the existing, well-tested infrastructure!

**Rationale**: Variadic methods get exposed symbols (no `\01` prefix) and have NO nil checks in their implementation. Since thunks can't be used (musttail restrictions with va_arg), setting `RequiresNullCheck` triggers the inline nil check. This still achieves the optimization goal: non-null call sites (like `self`) skip the nil check entirely.

#### Testing Scenarios:

**Test 1: Non-null receiver calls implementation directly**
```objc
- (int)caller {
  return [self directMethod];  // self is non-null
}
// Expected: direct call to @"-[Class directMethod]"
```

**Test 2: Nullable receiver calls thunk**
```objc
int caller(MyClass *obj) {
  return [obj directMethod];  // obj may be nil
}
// Expected: call to @"-[Class directMethod]_thunk"
```

**Test 3: _Nonnull receiver calls implementation**
```objc
int caller(MyClass *_Nonnull obj) {
  return [obj directMethod];  // obj is non-null
}
// Expected: direct call to @"-[Class directMethod]"
```

**Test 4: Class method**
```objc
int caller() {
  return [MyClass classMethod];  // class is non-null
}
// Expected (CURRENT IMPLEMENTATION - Simpler Approach):
//   direct call to @"+[Class classMethod]"
//   (implementation has [self self] but no nil check)
//
// Expected (FUTURE with full thunk approach):
//   If class is already realized: direct call to @"+[Class classMethod]"
//   If class needs realization: call to @"+[Class classMethod]_thunk"
//   (thunk does [self self], then musttail call to implementation)
//   (implementation has NO [self self] and NO nil check)
```

**IMPORTANT NOTE ON CLASS METHODS**: The current implementation (Phases 0-1) uses the simpler approach where class methods keep `[self self]` in the implementation. If/when implementing the full thunk-based approach for class methods, the caller will need to perform static analysis to determine:

1. **Is the class already realized?**
   - Has an instance method on the same class been called in a dominating path?
   - Extra care for inheritance: `[Parent foo]` does NOT realize `Child`

2. **Can the class be nil?**
   - Is the class weak-linked? (`isWeakLinkedClass(OID)`)
   - Only weak-linked classes can be nil at runtime

3. **Dispatch logic:**
   - If class is realized AND non-null → direct call to implementation
   - Otherwise → call thunk (which does realization + nil check)

The simpler approach avoids this complexity by always including `[self self]` in class method implementations.

---

### Phase 5: Corner Cases, Validation, and Darwin-Specific Testing ✅ **COMPLETED**

**Objective**: Address all corner cases, validate ARC correctness, and conduct executable tests on Darwin platforms to ensure the generated code works correctly in production.

**Status**: All critical functionality validated with executable tests. See `PHASE5_COMPLETION_SUMMARY.md` for detailed coverage analysis.

**Important Note**: At this phase, development should ideally move to a Darwin (macOS/iOS) platform to validate that the generated machine code executes correctly. LLVM IR correctness is not sufficient - we need to verify runtime behavior on actual Apple platforms.

#### Phase 5 Implementation Summary

**Tests Added/Changed:**

1. **Lazy Thunk Generation Tests** (`expose-direct-method.m`):
   - Restructured test file to verify thunks are generated lazily (only when used at call sites), not eagerly when methods are defined
   - Added `useRoot()`, `useFoo()`, `useSRet()` functions that invoke methods to trigger thunk generation
   - Thunk definition checks now appear after the user functions (matching lazy generation order)

2. **SRet (Struct Return) Tests**:
   - Added `useSRet()` test function covering struct return thunks:
     - `@"-[Root getComplex]_thunk"` - small complex struct return (register-passed)
     - `@"+[Root classGetComplex]_thunk"` - class method complex struct return
     - `@"-[Root getAggregate]_thunk"` - large aggregate return (sret parameter)
     - `@"+[Root classGetAggregate]_thunk"` - class method sret return
   - Verified thunks have proper sret attributes: `dead_on_unwind noalias writable sret(%struct.my_aggregate_struct)`

3. **Thunk Attribute Verification**:
   - Added checks that musttail calls in thunks have matching sret attributes
   - Verified `noundef` attribute propagation on thunk parameters

**Bugs Fixed:**

1. **Lazy Thunk Generation**:
   - Changed from eager thunk generation in `GenerateDirectMethod()` to lazy generation via `getOrCreateThunk()` lambda in `GetDirectMethodCallee()`
   - Thunks are now only created when actually needed (nullable receiver at call site)

2. **SRet Attribute Propagation**:
   - Fixed critical bug where sret attributes weren't being copied to musttail calls
   - Now using `CGM.ConstructAttributeList()` with `AttrOnCallSite=true` to properly apply call-site attributes including sret
   - This mirrors C++ thunk behavior in `EmitMustTailThunk`

3. **Thunk Visibility**:
   - Thunks now always have hidden visibility regardless of implementation visibility
   - Rationale: Each link unit generates its own identical thunk; making thunks visible is meaningless since cross-link-unit calls either use their own thunk or dispatch directly to implementation

4. **Type Covariance Thunk Regeneration**:
   - Fixed condition from `if (OldFn && OldThunk)` to `if (OldThunk)`
   - Ensures thunk is regenerated whenever implementation is replaced, not just on type mismatch

5. **Source Visibility Attribute Respect**:
   - Added logic to check for explicit visibility attributes on methods and their associated properties
   - Direct methods now respect `visibility("default")` attribute to allow dylib export when explicitly requested

**Files Modified:**
- `clang/lib/CodeGen/CGObjC.cpp` - Added visibility attribute checking for direct methods
- `clang/lib/CodeGen/CGObjCMac.cpp` - Lazy thunk generation, sret attribute fixes, thunk visibility
- `clang/test/CodeGenObjC/expose-direct-method.m` - Comprehensive test restructuring and additions

**Darwin Executable Tests Created:**

1. **`expose-direct-method-linkedlist.m`** - Comprehensive ARC and runtime validation:
   - `REQUIRES: system-darwin` - Darwin-only executable test
   - LinkedList implementation with recursive operations (clone, reverse, print)
   - Tests strong property ownership (`@property(direct, strong, nonatomic)`)
   - Tests weak self capture in blocks (`LinkedList* __weak weakSelf = self`)
   - Verifies all 6 allocated objects are properly deallocated (no leaks)
   - Tests property accessors, recursive thunk calls, and block execution through thunks

2. **`expose-direct-method-consumed.m`** - ARC `ns_consumed` attribute validation:
   - `REQUIRES: system-darwin` - Darwin-only executable test
   - Tests `__attribute__((ns_consumed))` parameter through thunks
   - Verifies ownership transfer works correctly with musttail calls
   - Tests class methods (`+[Shape default]`) and instance cloning
   - Verifies nil receiver returns 0 (`[null distanceFrom:zero]`)
   - Confirms all 6 allocated objects are deallocated correctly

These executable tests validate actual runtime behavior on Darwin, not just IR correctness.

#### 5.1: ARC Correctness Validation ✅

**Goal**: Thunks must be completely transparent to ARC - no effect on retain/release behavior.

**How Current Tests Achieve This**:

| Test File | ARC Feature Tested | Verification Method |
|-----------|-------------------|---------------------|
| `expose-direct-method-linkedlist.m` | Strong property ownership | `@property(direct, strong, nonatomic) LinkedList* next` - verifies strong references work through thunks |
| `expose-direct-method-linkedlist.m` | Weak self capture in blocks | `LinkedList* __weak weakSelf = self` in `_printBlock` - verifies weak references survive thunk calls |
| `expose-direct-method-linkedlist.m` | Object lifecycle tracking | Tracks allocation/deallocation via `Alloc id:` and `Dealloc id:` prints |
| `expose-direct-method-linkedlist.m` | No memory leaks | Verifies exactly 6 objects allocated, exactly 6 deallocated (`EXE-NOT: Dealloc` after 6) |
| `expose-direct-method-consumed.m` | `ns_consumed` attribute | `- (double) distanceFrom: (Shape *) __attribute__((ns_consumed)) s` tests ownership transfer through thunks |
| `expose-direct-method-consumed.m` | Dealloc verification | All 6 Shape objects properly deallocated |

**Key Implementation Detail**: `musttail` calls make thunks invisible to ARC optimizer, ensuring no spurious retains/releases.

#### 5.2: Darwin Executable Tests ✅

**Goal**: Validate runtime behavior on actual Darwin platforms (not just IR correctness).

**How Current Tests Achieve This**:

| Test File | Darwin Requirement | What It Validates |
|-----------|-------------------|-------------------|
| `expose-direct-method-linkedlist.m` | `REQUIRES: system-darwin` | Compiles and executes on Darwin only |
| `expose-direct-method-linkedlist.m` | Runtime execution | `%t/thunk-linkedlist 8 7 6` runs with args, `// EXE:` checks verify output |
| `expose-direct-method-linkedlist.m` | Foundation framework | Uses `#import <Foundation/Foundation.h>` |
| `expose-direct-method-consumed.m` | `REQUIRES: system-darwin` | Darwin-only executable |
| `expose-direct-method-consumed.m` | Runtime execution | `%t/shape 1 2 3 4` runs with args |
| `expose-direct-method-consumed.m` | Nil receiver behavior | `[null distanceFrom:zero]` returns 0.00 |

**Covered Scenarios**:
- ✅ Basic direct method calls (instance and class methods)
- ✅ Nil receiver returns zero (verified via `// EXE:` checks)
- ✅ Recursive method calls through thunks (clone, reverse, print)
- ✅ Block execution through thunks (`cloned.printBlock()`)
- ✅ Class method dispatch (`+[Shape default]`)

#### 5.3: Property Accessor Validation ✅

**Goal**: Verify direct property getters/setters work correctly through thunks.

**How Current Tests Achieve This**:

| Test File | Property Type | Coverage |
|-----------|--------------|----------|
| `expose-direct-method.m` | `@property(direct, readonly) int intProperty` | Getter thunk generation and dispatch |
| `expose-direct-method.m` | `@property(direct, readonly) id objectProperty` | Object-returning property accessor |
| `expose-direct-method.m` | `@property(direct) int getDirect_setDynamic` | Mixed direct/dynamic accessors |
| `expose-direct-method.m` | `@property(direct) int getDynamic_setDirect` | Setter thunk with void return |
| `expose-direct-method-linkedlist.m` | `@property(direct, readonly) int v` | Direct readonly property |
| `expose-direct-method-linkedlist.m` | `@property(direct, strong) LinkedList* next` | Direct strong property |
| `expose-direct-method-linkedlist.m` | `@property(direct) void (^printBlock)(void)` | Direct block property |

#### 5.4: Weak-Linked Class Tests ⏸️ DEFERRED

**Goal**: Test direct methods on weak-linked classes that may be nil at runtime.

**Status**: Not implemented. This is an edge case for frameworks that may not be available at runtime. The core thunk nil-check infrastructure handles this case correctly, but no dedicated test exists.

**Future Work**: Add test with `__attribute__((weak_import))` class.

#### 5.5: Performance and Code Size Validation ⏸️ DEFERRED

**Goal**: Measure binary size reduction and performance impact.

**Status**: No formal benchmarks collected. The optimization is expected to reduce code size by eliminating redundant nil checks from implementations, but this hasn't been measured.

**Future Work**: Compare binary sizes with/without `-fobjc-expose-direct-methods` on a large codebase.

#### 5.6: Integration Tests ✅

**Goal**: Test combinations of features working together.

**How Current Tests Achieve This**:

| Test File | Integration Scenario |
|-----------|---------------------|
| `expose-direct-method-linkedlist.m` | ARC + properties + recursive calls + blocks + dealloc tracking |
| `expose-direct-method-consumed.m` | ARC ns_consumed + class methods + nil receiver + cloning |
| `expose-direct-method.m` | Thunks + sret + properties + extensions + categories + cross-TU declarations |

**Key Integration Points Validated**:
- ✅ Methods defined in class extensions generate correct thunks
- ✅ Methods defined in categories generate correct thunks
- ✅ Cross-TU method declarations (no definition in current TU) get thunks on-demand
- ✅ Struct return types (sret) work correctly with musttail
- ✅ Class methods perform class realization before dispatch

---

### Phase 6: Optimize Dispatch Helper Functions ⏸️ **PENDING**

**Objective**: Implement full optimization logic for dispatch helper functions to reduce unnecessary thunk calls and class realizations.

**Rationale**:
- Phase 2 created stub implementations that always return `false` (conservative)
- This phase adds the actual optimization logic based on static analysis
- Performance improvement: eliminate redundant nil checks and class realizations
- Correctness is already guaranteed by Phase 2-6; this phase only improves performance

#### Files Modified:
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`

#### Changes:

**Implement `isObjCReceiverNonNull()` with heuristics** (`CodeGenModule.cpp`):

```cpp
bool CodeGenModule::isObjCReceiverNonNull(const Expr *receiverExpr,
                                          CodeGenFunction &CGF) const {
  if (!receiverExpr)
    return false;

  receiverExpr = receiverExpr->IgnoreParenCasts();
  QualType type = receiverExpr->getType();

  // Heuristic 1: _Nonnull attribute
  if (auto Nullability = type->getNullability()) {
    if (*Nullability == NullabilityKind::NonNull)
      return true;
  }

  // Heuristic 2: 'self' in instance methods
  if (auto declRef = dyn_cast<DeclRefExpr>(receiverExpr)) {
    if (auto PD = dyn_cast<ImplicitParamDecl>(declRef->getDecl())) {
      if (auto OMD = dyn_cast_or_null<ObjCMethodDecl>(CGF.CurCodeDecl)) {
        if (OMD->getSelfDecl() == PD && OMD->isInstanceMethod())
          return true;
      }
    }
  }

  // Heuristic 3: 'super' in instance methods
  // super is effectively self (cast to superclass type), so it's non-null
  if (auto Super = dyn_cast<ObjCSuperExpr>(receiverExpr)) {
    return true;
  }

  // Heuristic 4: Class objects (but NOT weak-linked classes)
  // Weakly-linked classes can be nil at runtime if their framework is unavailable
  if (type->isObjCClassType() || type->isObjCQualifiedClassType()) {
    // Check if this is a weakly-linked class
    if (auto *IFace = type->getAsObjCInterfaceType()) {
      if (auto *Decl = IFace->getDecl()) {
        // If the class is weakly linked, it may be nil at runtime
        if (Decl->isWeakImported())
          return false;  // Conservative: must use thunk for nil check
      }
    }
    // Non-weak-linked class objects are always non-null after initialization
    return true;
  }

  // Heuristic 5: Results of alloc/new (future enhancement)
  // TODO: Recognize [[Class alloc] init] patterns
  // Pattern: ObjCMessageExpr with selector "alloc" or "new"

  // Heuristic 6: ObjC literals (future enhancement)
  // TODO: Recognize @"string", @[], @{}, @42, etc.
  // Check if expression is ObjCStringLiteral, ObjCArrayLiteral, etc.

  // Heuristic 7: Methods known to return non-null (future enhancement)
  // TODO: Track methods with _Nonnull return types
  // Would require data flow analysis to track return values

  return false;
}
```

**Implement `canClassObjectBeUnrealized()` with heuristics** (`CodeGenModule.cpp`):

```cpp
bool CodeGenModule::canClassObjectBeUnrealized(const ObjCInterfaceDecl *ClassDecl,
                                               CodeGenFunction &CGF) const {
  if (!ClassDecl)
    return false;

  // Heuristic 1: Check if an instance method on the same class was called
  // in a dominating path
  //
  // Implementation approach:
  // - Walk backwards through the current BasicBlock
  // - Check if any call instruction is a direct method call to an instance method
  //   on the same class (or a superclass)
  // - If found in a dominating block, the class must be realized
  //
  // IMPORTANT: Inheritance care is needed:
  // - [Parent foo] realizes Parent, but does NOT realize Child
  // - Only calls to instance methods on ClassDecl or its superclasses help
  // - Calls to instance methods on subclasses do NOT help

  llvm::BasicBlock *CurrentBlock = CGF.Builder.GetInsertBlock();
  if (!CurrentBlock)
    return false;

  // Simple heuristic: Check the current basic block for dominating calls
  // Walk backwards through instructions in the current block
  for (auto II = CurrentBlock->rbegin(), IE = CurrentBlock->rend();
       II != IE; ++II) {
    llvm::Instruction *Inst = &*II;

    // Check if this is a call instruction
    if (auto *Call = dyn_cast<llvm::CallInst>(Inst)) {
      llvm::Function *CalledFunc = Call->getCalledFunction();
      if (!CalledFunc)
        continue;

      // Check if this is a direct method call
      // Direct methods have names like "-[ClassName methodName]"
      llvm::StringRef FuncName = CalledFunc->getName();

      // Parse the function name to extract class information
      // Format: "-[ClassName methodName]" for instance methods
      if (FuncName.startswith("-[")) {
        // Extract the class name from the symbol
        size_t ClassStart = 2; // After "-["
        size_t ClassEnd = FuncName.find(' ', ClassStart);
        if (ClassEnd == llvm::StringRef::npos)
          continue;

        llvm::StringRef CalledClassName =
            FuncName.slice(ClassStart, ClassEnd);

        // Check if the called class matches or is a superclass of ClassDecl
        // IMPORTANT: [Parent foo] does NOT realize Child
        //            Only [Child foo] or [Parent foo] realizes Parent
        llvm::StringRef TargetClassName = ClassDecl->getName();

        if (CalledClassName == TargetClassName) {
          // Found an instance method call on the same class
          // The class must be realized by this point
          return true;
        }

        // Check if CalledClassName is a superclass of ClassDecl
        // This is conservative: if we called a superclass instance method,
        // the superclass is realized, which means our class should be too
        const ObjCInterfaceDecl *Super = ClassDecl->getSuperClass();
        while (Super) {
          if (CalledClassName == Super->getName())
            return true;
          Super = Super->getSuperClass();
        }
      }
    }
  }

  // Heuristic 2: Check dominating blocks (advanced, future enhancement)
  // TODO: Use LLVM's DominatorTree to check if any dominating block
  //       contains a realizing call
  // This would require access to CGF's function-level analysis

  // Heuristic 3: Explicit class realization (future enhancement)
  // TODO: Detect patterns like:
  //   (void)[MyClass self];  // Explicit realization
  //   [MyClass alloc];        // Also realizes the class

  // Conservative default: assume class is not realized
  return false;
}
```

#### Heuristics Summary:

**For `isObjCReceiverNonNull` (Instance Methods):**

| Heuristic | Description | Implementation Status |
|-----------|-------------|----------------------|
| `_Nonnull` attribute | Receiver type has `_Nonnull` annotation | ✅ Phase 6 |
| `self` parameter | Receiver is `self` in instance method | ✅ Phase 6 |
| `super` keyword | Receiver is `super` (implicitly non-null) | ✅ Phase 6 |
| Class objects | Receiver is a non-weak-linked class | ✅ Phase 6 |
| `alloc`/`new` results | Pattern: `[[Class alloc] init]` | 🔮 Future |
| ObjC literals | `@"string"`, `@[]`, `@{}`, `@42` | 🔮 Future |
| Known non-null methods | Methods with `_Nonnull` return type | 🔮 Future |
| LLVM-level analysis | Use `isKnownNonZero()` at IR level | 🔮 Future |

**For `canClassObjectBeUnrealized` (Class Methods):**

| Heuristic | Description | Implementation Status |
|-----------|-------------|----------------------|
| Instance method dominates | Instance method call on same class in dominating path | ✅ Phase 6 (basic) |
| Dominator tree analysis | Use LLVM's DominatorTree for better precision | 🔮 Future |
| Explicit realization | Pattern: `(void)[MyClass self]` or `[MyClass alloc]` | 🔮 Future |
| Inheritance awareness | Careful: `[Parent foo]` does NOT realize `Child` | ✅ Phase 6 |

#### Key Design Considerations:

**1. Inheritance Care for Class Realization:**
From the RFC:
> "Extra care needs to be applied for class methods, e.g. even if [Parent foo] dominates [Child foo], the call to [Child foo] still needs to go through class realization to make sure Child is realized."

This means:
- `[Parent instanceMethod]` realizes **only** `Parent` (and its superclasses)
- `[Child classMethod]` needs its own realization check
- Cannot assume child classes are realized when parent is realized

**2. Weak-Linked Classes:**
- Only weak-linked classes can be `nil` at runtime
- Check with `Decl->isWeakImported()`
- Non-weak-linked class objects are always non-null after initialization

**3. Conservative Approach:**
- When in doubt, return `false` (use thunk)
- False negatives (missed optimization) are acceptable
- False positives (skipping needed nil check) are **NOT** acceptable

**4. Future Optimization - Intrinsic-Based Realization:**
From the RFC:
> "A future optimization could replace the opaque [self self] call in CodeGen with a new LLVM intrinsic (e.g., @llvm.objc.realize.class). A backend optimizer pass (like CSE or GVN) could then safely deduplicate or remove redundant realization calls."

This would allow LLVM optimization passes to:
- Eliminate redundant `[self self]` calls across multiple direct methods
- Common Subexpression Elimination (CSE) for class realization
- Currently impossible due to opaque function call semantics

#### Testing Strategy:

**Test 1: Non-null receiver optimization**
```objc
// Should NOT use thunk (self is non-null)
// CHECK-LABEL: @"-[Class caller]"
// CHECK: call {{.*}} @"-[Class method]"
// CHECK-NOT: _thunk
- (int)caller {
  return [self directMethod];  // self is non-null
}
```

**Test 2: _Nonnull annotation**
```objc
// Should NOT use thunk (_Nonnull receiver)
// CHECK: call {{.*}} @"-[Class method]"
// CHECK-NOT: _thunk
int caller(MyClass *_Nonnull obj) {
  return [obj directMethod];
}
```

**Test 3: Nullable receiver**
```objc
// Should use thunk (nullable receiver)
// CHECK: call {{.*}} @"-[Class method]_thunk"
int caller(MyClass *obj) {
  return [obj directMethod];
}
```

**Test 4: Class method with dominating instance call**
```objc
// Instance method realizes the class
// Class method should NOT need thunk
// CHECK-LABEL: @testClassRealized
// CHECK: call {{.*}} @"-[Class instanceMethod]"
// CHECK: call {{.*}} @"+[Class classMethod]"
// CHECK-NOT: _thunk
int testClassRealized(MyClass *obj) {
  [obj instanceMethod];  // Realizes MyClass
  return [MyClass classMethod];  // Class is already realized
}
```

**Test 5: Inheritance - parent does not realize child**
```objc
@interface Parent : NSObject
+ (int)parentClassMethod __attribute__((objc_direct));
@end

@interface Child : Parent
+ (int)childClassMethod __attribute__((objc_direct));
@end

// Parent realization does NOT realize Child
// CHECK-LABEL: @testInheritance
// CHECK: call {{.*}} @"+[Parent parentClassMethod]"
// CHECK: call {{.*}} @"+[Child childClassMethod]_thunk"
int testInheritance(Parent *parentObj) {
  [Parent parentClassMethod];  // Realizes Parent only
  return [Child childClassMethod];  // Child needs realization
}
```

#### Validation:
```bash
# Build with optimization enabled
ninja -C build-debug clang

# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang

# Verify optimizations are working:
# - Non-null receivers call implementation directly (no thunk)
# - Nullable receivers call thunk
# - Class methods skip realization when possible
```

#### Performance Metrics:

After implementing Phase 6, measure:
1. **Binary size reduction**: Compare binary size with/without optimizations
2. **Thunk call reduction**: Count how many calls skip thunks
3. **Class realization reduction**: Count eliminated `[self self]` calls

Expected improvements:
- ~10-30% reduction in thunk calls (depends on code patterns)
- Smaller binary size due to reduced thunk overhead
- No performance regression (optimizations only)

---

## Files to Modify

### Summary of All Files

| File | Phases | Purpose |
|------|--------|---------|
| `clang/include/clang/Basic/CodeGenOptions.def` | 0 | Add ObjCNilCheckThunk option |
| `clang/include/clang/Driver/Options.td` | 0 | Add compiler flag |
| `clang/include/clang/AST/DeclObjC.h` | 1 | Add canHaveNilCheckThunk() |
| `clang/lib/CodeGen/CodeGenModule.h` | 1, 2 | Add optimization checks, nullability helpers |
| `clang/lib/CodeGen/CodeGenModule.cpp` | 1, 2, 7 | Implement helper functions |
| `clang/lib/CodeGen/CodeGenFunction.h` | 3 | Add StartObjCDirectThunk/FinishObjCDirectThunk |
| `clang/lib/CodeGen/CGObjCRuntime.h` | 1, 2 | Refactor symbol name generation, add virtual dispatch helpers |
| `clang/lib/CodeGen/CGObjCRuntime.cpp` | 1, 2 | Implement symbol name generation and stub dispatch helpers |
| `clang/lib/CodeGen/CGObjCMac.cpp` | 1, 3 | Modify implementation generation, add thunk generation |
| `clang/lib/CodeGen/CGObjC.cpp` | 1, 4 | Update visibility, integrate call site logic |
| `clang/test/CodeGenObjC/expose-direct-method*.m` | 1, 2, 3, 6 | Add comprehensive tests (all prefixed with expose-direct-method) |

### Detailed File Descriptions

#### `/home/peterrong/llvm-project/clang/include/clang/Basic/CodeGenOptions.def`
- **Phase**: 0
- **Changes**: Add `CODEGENOPT(ObjCNilCheckThunk, 1, 0, Benign)`
- **Purpose**: Enable/disable feature via compiler flag

#### `/home/peterrong/llvm-project/clang/include/clang/Driver/Options.td`
- **Phase**: 0
- **Changes**: Add `-fobjc-direct-caller-thunks` flag definition
- **Purpose**: Command-line interface for the feature

#### `/home/peterrong/llvm-project/clang/include/clang/AST/DeclObjC.h`
- **Phase**: 1
- **Changes**: Add `canHaveNilCheckThunk()` method to `ObjCMethodDecl`
- **Purpose**: Determine if a method is eligible for optimization

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.h`
- **Phase**: 1, 2, 3
- **Changes**:
  - Add `shouldHaveNilCheckThunk()` (Phase 1)
  - Add `isObjCReceiverNonNull()` (Phase 2)
  - Add `ObjCDirectThunks` cache and `getOrCreateObjCDirectThunk()` (Phase 3)
- **Purpose**: Centralize optimization logic

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`
- **Phase**: 1, 2, 3
- **Changes**: Implement functions declared in CodeGenModule.h
- **Purpose**: Implementation of core optimization logic

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCRuntime.h`
- **Phase**: 1
- **Changes**: Add `includePrefixByte` parameter to `getSymbolNameForMethod()`
- **Purpose**: Allow removing `\01` prefix for public symbols

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCRuntime.cpp`
- **Phase**: 1
- **Changes**: Implement modified `getSymbolNameForMethod()`
- **Purpose**: Generate public symbols when optimization enabled

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCMac.cpp`
- **Phase**: 1, 3
- **Changes**:
  - Modify `GenerateDirectMethod()` (Phase 1)
  - Modify `GenerateDirectMethodPrologue()` (Phase 1)
  - Add thunk generation logic (Phase 3)
- **Purpose**: Generate implementations and thunks

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjC.cpp`
- **Phase**: 1, 4
- **Changes**:
  - Update visibility settings (Phase 1)
  - Integrate call site logic (Phase 4)
- **Purpose**: Determine whether to call implementation or thunk

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method.m`
- **Phase**: 1, 6
- **Changes**: Add/update comprehensive tests for main functionality
- **Purpose**: Verify optimization works correctly

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-disabled.m`
- **Phase**: 1
- **Changes**: Test backward compatibility
- **Purpose**: Ensure old behavior without flag

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-varargs.m`
- **Phase**: 1
- **Changes**: Test variadic method exclusion
- **Purpose**: Verify variadic methods keep old behavior

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-nullability.m`
- **Phase**: 2
- **Changes**: Test nullability analysis
- **Purpose**: Verify correct detection of non-null receivers

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-thunks.m`
- **Phase**: 3, 6
- **Changes**: Test thunk generation and structure
- **Purpose**: Verify thunks are generated correctly with musttail calls

---

## Testing Strategy

### Levels of Testing

**1. Unit Tests (Per Phase)**
- Test each phase independently
- Verify no regressions in existing tests
- Use XFAIL for incomplete features

**2. Integration Tests**
- Test complete workflow after all phases
- Test interaction between phases
- Verify end-to-end behavior

**3. Regression Tests**
- Run existing direct method tests
- Verify backward compatibility
- Test with flag disabled

**4. Edge Case Tests**
- Variadic methods
- ARC compatibility
- Struct returns
- Weak-linked classes
- Properties

### Test Execution

```bash
# Build clang
ninja -C build-debug clang
```bash
# Run all tests with expose-direct-method prefix (RECOMMENDED)
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang

# Run all ObjC CodeGen tests
ninja -C build-debug check-clang-codegen-objc

# Run specific test file
./build-debug/bin/llvm-lit -v clang/test/CodeGenObjC/expose-direct-method.m

# Run with verbose output and print IR
./build-debug/bin/llvm-lit -v -a clang/test/CodeGenObjC/expose-direct-method-thunks.m
```

### Manual Testing

```bash
# Compile test file with optimization enabled
./build-debug/bin/clang -cc1 -emit-llvm -fobjc-arc \
  -fobjc-expose-direct-methods -triple x86_64-apple-darwin10 \
  test.m -o - | less

# Check for expected patterns:
# - Public symbols: @"-[Class method]" (no \01)
# - Thunks: @"-[Class method]_thunk"
# - No nil checks in implementations
# - Musttail calls in thunks

# Compile without flag (backward compatibility)
./build-debug/bin/clang -cc1 -emit-llvm -fobjc-arc \
  -triple x86_64-apple-darwin10 test.m -o - | less

# Check for old behavior:
# - Hidden symbols: @"\01-[Class method]"
# - Nil checks in implementations
# - No thunks
```

### Performance Testing

**Code Size Measurement:**
```bash
# Compile large ObjC project with/without optimization
# Compare binary sizes

# With optimization
clang -fobjc-expose-direct-methods project.m -o with_opt

# Without optimization
clang project.m -o without_opt

# Compare sizes
ls -lh with_opt without_opt
```

**Expected Results:**
- Smaller binary size (eliminated redundant nil checks)
- Fewer function calls from non-null sites
- No performance regression

---

## Build and Validation

### Initial Setup

```bash
# Clone or update llvm-project
cd /home/peterrong/llvm-project

# Create build directory
mkdir -p build-debug
cd build-debug

# Configure with CMake
cmake -G Ninja ../llvm \
  -DCMAKE_BUILD_TYPE=Debug \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

# Build clang
ninja clang
```

### Incremental Build After Changes

```bash
# After modifying source files
cd build-debug

# Build clang (incremental)
ninja clang

# Run tests
ninja check-clang-codegen-objc
```

### Validation Checklist

After each phase:

- [ ] Code compiles without errors
- [ ] Code compiles without warnings
- [ ] Existing tests pass
- [ ] New tests pass (or XFAIL'd appropriately)
- [ ] No memory leaks (run with ASAN)
- [ ] Code review ready

### Debugging Tips

**1. Print LLVM IR:**
```bash
./build-debug/bin/clang -cc1 -emit-llvm -fobjc-arc \
  -fobjc-direct-caller-thunks -triple x86_64-apple-darwin10 \
  test.m -o test.ll

# View IR
less test.ll
```

**2. Enable verbose output:**
```bash
./build-debug/bin/clang -cc1 -emit-llvm -fobjc-arc \
  -fobjc-direct-caller-thunks -triple x86_64-apple-darwin10 \
  -debug test.m -o test.ll 2>&1 | less
```

**3. Use lldb to debug compiler:**
```bash
lldb ./build-debug/bin/clang

# Set breakpoint
(lldb) b CodeGenModule::getOrCreateObjCDirectThunk

# Run with arguments
(lldb) run -cc1 -emit-llvm test.m -o -
```

**4. Check for memory issues:**
```bash
# Build with ASAN
cmake -G Ninja ../llvm \
  -DCMAKE_BUILD_TYPE=Debug \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_USE_SANITIZER=Address

ninja clang

# Run tests with ASAN
ninja check-clang-codegen-objc
```

---

## Implementation Timeline

### Estimated Effort

| Phase | Effort | Dependencies |
|-------|--------|--------------|
| Phase 0: Infrastructure | 1-2 hours | None | ✅ Complete |
| Phase 1: Implementation Gen | 1-2 days | Phase 0 | ✅ Complete |
| Phase 2: Stub Dispatch Helpers | 1 day | Phase 1 | ✅ Complete |
| Phase 3: Thunk Generation | 2-3 days | Phases 1, 2 | ✅ Complete |
| Phase 4: Call Site Logic | 1-2 days | Phases 1, 2, 3 | 🚧 In Progress |
| Phase 5: Special Cases and Tests | 1 day | Phase 4 | ⏸️ Pending |
| Phase 6: Optimize Dispatch | 1-2 days | All phases | ⏸️ Pending |
| **Total** | **1.5-2 weeks** | | ~60% Complete |

### Milestones

**Milestone 1: Infrastructure Complete** (Phases 0-1)
- Compiler flag works
- Implementation generation modified
- Backward compatibility maintained

**Milestone 2: Analysis Ready** (Phase 2)
- Nullability analysis implemented
- Ready for thunk generation

**Milestone 3: Thunk Generation** (Phase 3)
- Thunks generated correctly
- Musttail calls working
- Linkonce_odr deduplication verified

**Milestone 4: Integration Complete** (Phase 4)
- Call sites use correct target
- Non-null → implementation
- Nullable → thunk

**Milestone 5: Production Ready** (Phases 5-6)
- All edge cases handled
- Comprehensive tests pass
- Performance validated
- Ready for code review

---

## References

### Design Documents
- RFC: "Optimizing Code Size of objc_direct by Exposing Function Symbols and Moving Nil Checks to Thunks"
- Google Doc: https://docs.google.com/document/d/1uq7-4z_3O2G3g6tQFsVExSWnDY_VXSc8e9izZho6uVM/

### Previous Implementation
- Failed implementation patch: `/home/peterrong/llvm-project/prevImplement.patch`
- Phases 0-2.5 completed, Phases 3-6 pending

### Key Code Locations
- Direct method generation: `clang/lib/CodeGen/CGObjCMac.cpp`
- Message send emission: `clang/lib/CodeGen/CGObjC.cpp`
- Runtime interface: `clang/lib/CodeGen/CGObjCRuntime.{h,cpp}`
- AST declarations: `clang/include/clang/AST/DeclObjC.h`

### LLVM Documentation
- MustTail calls: https://llvm.org/docs/LangRef.html#call-instruction
- Linkonce_odr linkage: https://llvm.org/docs/LangRef.html#linkage-types
- Function attributes: https://llvm.org/docs/LangRef.html#function-attributes

### Related Work
- Previous diff: D126639 (two-symbol approach)
- ObjC direct methods: https://nshipster.com/direct/

---

## Appendix

### Glossary

- **objc_direct**: Attribute that makes ObjC methods use direct calls instead of message dispatch
- **Thunk**: Small wrapper function that performs nil check before calling implementation
- **NeXT runtime**: Modern Objective-C runtime (as opposed to GNU runtime)
- **Musttail call**: LLVM instruction that guarantees tail call (no stack frame)
- **LinkOnceODR**: Linkage type that allows linker to deduplicate identical definitions
- **SRet**: Struct return calling convention for large return types
- **ARC**: Automatic Reference Counting for memory management

### Common Issues and Solutions

**Issue: Musttail call fails verification**
- Cause: Return type mismatch or calling convention mismatch
- Solution: Ensure thunk signature exactly matches implementation

**Issue: Linker error "duplicate symbol"**
- Cause: Multiple implementations with same name
- Solution: Verify external linkage is used, not linkonce_odr for implementations

**Issue: ARC crashes with thunks**
- Cause: Thunk not using musttail, ARC operations between thunk and impl
- Solution: Always use musttail for thunk → implementation call

**Issue: Nil check not eliminated**
- Cause: Nullability analysis not detecting non-null receiver
- Solution: Enhance isObjCReceiverNonNull() with more cases

**Issue: Variadic methods crash**
- Cause: Attempting to use thunk for variadic methods
- Solution: Verify canHaveNilCheckThunk() excludes variadic

---

## Next Steps

1. **Review this plan** with team for feedback
2. **Set up development environment** with debug build
3. **Start with Phase 0** (if not already done)
4. **Proceed sequentially** through phases
5. **Test thoroughly** after each phase
6. **Submit for code review** after Milestone 5
