# Implementation Plan: ObjC Direct Method Nil-Check Thunk Optimization

## Executive Summary

This document provides a stage-by-stage implementation plan for the RFC: "Optimizing Code Size of objc_direct by Exposing Function Symbols and Moving Nil Checks to Thunks". This optimization reduces code bloat and improves linkage for `__attribute__((objc_direct))` methods by moving nil-checking logic from the method implementation to caller-generated thunks.

---

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

Similar to instance methods but includes class realization:

**True Implementation:**
- Starts with class realization: `(void)[self self];`
- NO nil check (unless weakly linked)

**Thunk:**
- Performs class realization before nil check
- Same `musttail` call pattern

**Rationale for keeping class realization in implementation:**
- Non-null receiver ≠ initialized class
- Direct calls from provably non-null sites need initialization
- Class realization is a method semantic, not just a nil-check concern

**Note on class initialization overhead:**
- When calling through a thunk, `[self self]` is called twice: once in the thunk, once in the implementation
- While this creates a small performance overhead, it is acceptable because:
  1. This was explicitly requested in the design review
  2. The double initialization is idempotent (safe to call multiple times)
  3. This case is relatively rare (most class method calls are to non-weak-linked classes)

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
- `clang/test/CodeGenObjC/expose-direct-method-flag.m` (flag recognition test)

#### Validation:
```bash
# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang
```

---

### Phase 1: Modify Method Implementation Generation ⏸️ **PENDING**

**Objective**: Change how direct method implementations are emitted when optimization is enabled.

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

**5. Modify `GenerateDirectMethodPrologue()`** (`CGObjCMac.cpp`):
```cpp
// Skip nil checks when optimization enabled (applies to ALL direct methods)
// But KEEP class initialization for class methods
if (ReceiverCanBeNull && !CGM.shouldExposeSymbol(OMD)) {
  // ... generate nil check code
}
```

**6. Update visibility** (`CGObjC.cpp`):
```cpp
if (OMD->isDirectMethod()) {
  // IMPORTANT: Keep hidden visibility even when optimization enabled
  // - ExternalLinkage allows cross-TU calls within the same build product
  // - HiddenVisibility prevents dylib export (preserves ABI encapsulation)
  // - Only use DefaultVisibility if explicitly marked visibility("default")
  Fn->setVisibility(llvm::Function::HiddenVisibility);
  // ... rest of code
}
```

#### Key Design Decisions:
- **External linkage + Hidden visibility**: Cross-TU calls without dylib export pollution
- **Preserve class init**: Class methods keep `[self self]` call
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

### Phase 2: Implement Call Site Nullability Analysis ⏸️ **PENDING**

**Objective**: Implement static analysis to determine if a receiver is provably non-null.

#### Files Modified:
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`

#### Changes:

**Add nullability analysis function** (`CodeGenModule.h/cpp`):

```cpp
/// Check if the receiver of an ObjC message send is definitely non-null.
/// Used to optimize direct method calls by skipping nil-check thunk.
///
/// Returns true if receiver is:
/// - Marked with _Nonnull attribute
/// - The 'self' parameter in an instance method
/// - A Class object (classes are never nil after initialization)
///
/// Conservative: only returns true when definitively non-null.
bool isObjCReceiverNonNull(const Expr *receiverExpr,
                           CodeGenFunction &CGF) const;
```

**Implementation** (`CodeGenModule.cpp`):

```cpp
bool CodeGenModule::isObjCReceiverNonNull(const Expr *receiverExpr,
                                          CodeGenFunction &CGF) const {
  if (!receiverExpr)
    return false;

  receiverExpr = receiverExpr->IgnoreParenCasts();
  QualType type = receiverExpr->getType();

  // Check 1: _Nonnull attribute
  if (auto Nullability = type->getNullability()) {
    if (*Nullability == NullabilityKind::NonNull)
      return true;
  }

  // Check 2: 'self' in instance methods
  if (auto declRef = dyn_cast<DeclRefExpr>(receiverExpr)) {
    if (auto PD = dyn_cast<ImplicitParamDecl>(declRef->getDecl())) {
      if (auto OMD = dyn_cast_or_null<ObjCMethodDecl>(CGF.CurCodeDecl)) {
        if (OMD->getSelfDecl() == PD && OMD->isInstanceMethod())
          return true;
      }
    }
  }

  // Check 3: 'super' in instance methods
  // super is effectively self (cast to superclass type), so it's non-null
  if (auto Super = dyn_cast<ObjCSuperExpr>(receiverExpr)) {
    return true;
  }

  // Check 4: Class objects (but NOT weak-linked classes)
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

  // TODO: Future enhancements
  // - Results of alloc, new, etc.
  // - ObjC literals (@"string", @42, etc.)
  // - Results of methods known to return non-null

  return false;
}
```

#### Future Enhancements:
1. **Alloc/new detection**: Recognize `[[Class alloc] init]` patterns
2. **Literal detection**: Recognize `@"string"`, `@[]`, `@{}`, etc.
3. **Method return analysis**: Track methods known to return non-null
4. **Data flow analysis**: Use LLVM's `isKnownNonZero()` at IR level

#### Test Created:
- `clang/test/CodeGenObjC/expose-direct-method-nullability-analysis.m`

#### Validation:
```bash
# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang
```

---

### Phase 3: Implement Thunk Generation ⏸️ **PENDING**

**Objective**: Generate nil-check thunks at call sites for nullable receivers.

#### Files to Modify:
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCMac.cpp`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`

#### Changes:

**1. Add thunk cache** (`CodeGenModule.h`):
```cpp
private:
  /// Cache of generated nil-check thunks to avoid duplicates within a module
  llvm::DenseMap<const ObjCMethodDecl*, llvm::Function*> ObjCDirectThunks;

public:
  /// Get or create a nil-check thunk for a direct method
  llvm::Function* getOrCreateObjCDirectThunk(const ObjCMethodDecl *OMD);
```

**2. Implement thunk generation** (`CodeGenModule.cpp`):

```cpp
llvm::Function* CodeGenModule::getOrCreateObjCDirectThunk(
    const ObjCMethodDecl *OMD) {

  // Check cache first
  auto it = ObjCDirectThunks.find(OMD);
  if (it != ObjCDirectThunks.end())
    return it->second;

  // Get the true implementation function
  llvm::Function *TrueImpl = /* ... get from runtime ... */;

  // Create thunk function type (same as implementation)
  llvm::FunctionType *ThunkTy = TrueImpl->getFunctionType();

  // Generate thunk name: symbol + "_thunk"
  std::string ThunkName = TrueImpl->getName().str() + "_thunk";

  // Create thunk with linkonce_odr linkage
  llvm::Function *Thunk = llvm::Function::Create(
      ThunkTy,
      llvm::GlobalValue::LinkOnceODRLinkage,
      ThunkName,
      &getModule());

  // Set attributes
  Thunk->setVisibility(llvm::GlobalValue::HiddenVisibility);
  Thunk->setUnnamedAddr(llvm::GlobalValue::UnnamedAddr::Global);

  // CRITICAL: Copy function-level attributes from TrueImpl to Thunk
  // These attributes affect code generation and optimization
  llvm::AttributeList ImplAttrs = TrueImpl->getAttributes();
  Thunk->setAttributes(ImplAttrs);

  // CRITICAL: Copy parameter attributes for musttail compatibility
  // Parameter attributes like ns_consumed, sext, zext, inreg, byval must match exactly
  // The AttributeList already contains param attributes, so they're copied above

  // Generate thunk body
  llvm::BasicBlock *Entry = llvm::BasicBlock::Create(getLLVMContext(),
                                                     "entry", Thunk);
  llvm::BasicBlock *NilCase = llvm::BasicBlock::Create(getLLVMContext(),
                                                       "nil_case", Thunk);
  llvm::BasicBlock *NonNilCase = llvm::BasicBlock::Create(getLLVMContext(),
                                                          "non_nil_case", Thunk);

  llvm::IRBuilder<> Builder(Entry);

  // Determine the 'self' parameter index correctly
  // IMPORTANT: With sret, self is argument 1, not 0
  // Use CGFunctionInfo to determine correct parameter layout
  const CGFunctionInfo &FI = getTypes().arrangeObjCMethodDeclaration(OMD);
  bool UsesSRet = FI.getReturnInfo().isIndirect();

  // Get self parameter: index 0 normally, index 1 if using sret
  unsigned SelfIndex = UsesSRet ? 1 : 0;
  llvm::Value *Self = Thunk->getArg(SelfIndex);

  // For class methods: perform class realization first
  if (OMD->isClassMethod()) {
    // Call [self self] to realize the class
    // This ensures the class is initialized before proceeding
    // ... implementation details ...
  }

  // Check if self == null
  llvm::Value *IsNil = Builder.CreateIsNull(Self, "is_nil");
  Builder.CreateCondBr(IsNil, NilCase, NonNilCase);

  // Nil case: return zero-initialized value
  Builder.SetInsertPoint(NilCase);
  if (UsesSRet) {
    // With sret, write zero to the return buffer and return void
    llvm::Value *SRetPtr = Thunk->getArg(0);
    llvm::Type *RetTy = SRetPtr->getType()->getPointerElementType();
    llvm::Value *ZeroVal = llvm::Constant::getNullValue(RetTy);
    Builder.CreateStore(ZeroVal, SRetPtr);
    Builder.CreateRetVoid();
  } else {
    llvm::Type *RetTy = ThunkTy->getReturnType();
    if (RetTy->isVoidTy()) {
      Builder.CreateRetVoid();
    } else {
      llvm::Value *ZeroVal = llvm::Constant::getNullValue(RetTy);
      Builder.CreateRet(ZeroVal);
    }
  }

  // Non-nil case: musttail call to true implementation
  Builder.SetInsertPoint(NonNilCase);

  // Collect all arguments
  SmallVector<llvm::Value*, 8> Args;
  for (auto &Arg : Thunk->args())
    Args.push_back(&Arg);

  // Create musttail call
  // CRITICAL: All attributes were already copied, so this should verify correctly
  llvm::CallInst *Call = Builder.CreateCall(TrueImpl, Args);
  Call->setTailCallKind(llvm::CallInst::TCK_MustTail);
  Call->setCallingConv(TrueImpl->getCallingConv());

  // Return the result
  if (UsesSRet) {
    Builder.CreateRetVoid();
  } else {
    llvm::Type *RetTy = ThunkTy->getReturnType();
    if (RetTy->isVoidTy())
      Builder.CreateRetVoid();
    else
      Builder.CreateRet(Call);
  }

  // Cache the thunk
  ObjCDirectThunks[OMD] = Thunk;

  return Thunk;
}
```

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

**3. Class Realization (Class Methods)**
- Must call `[self self]` before nil check
- Ensures class is initialized even for non-null class objects
- Pattern:
  ```cpp
  // Get metaclass
  // Call objc_msgSend with @selector(self)
  // Then proceed with nil check
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

### Phase 4: Integrate Call Site Logic ⏸️ **PENDING**

**Objective**: Use nullability analysis to decide whether to call implementation directly or via thunk.

#### Files to Modify:
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjC.cpp`

#### Changes:

**Modify direct method call emission** (`CGObjC.cpp`):

Current location: Search for `EmitObjCMessageExpr` and direct method handling.

```cpp
// In the function that handles message send code generation

// Check if optimization is enabled (this also checks Method is non-null and direct)
if (CGM.shouldExposeSymbol(Method)) {

  // Handle variadic methods with inline nil checks
  if (CGM.shouldHaveNilCheckInline(Method)) {
    // ... variadic handling code from item 4 below ...
  }

  assert(CGM.shouldGenerateNilCheckThunk(Method));
  // Non-variadic methods: use thunk optimization
  // Perform nullability analysis
  const Expr *Receiver = /* ... extract receiver expression ... */;

  if (CGM.isObjCReceiverNonNull(Receiver, *this)) {
    // Case 1: Receiver is provably non-null
    // → Direct call to true implementation

    llvm::Function *TrueImpl = /* ... get implementation ... */;
    llvm::CallInst *Call = Builder.CreateCall(TrueImpl, Args);

    // Set calling convention and attributes
    Call->setCallingConv(TrueImpl->getCallingConv());
    // ... other attributes ...

    return RValue::get(Call);

  } else {
    // Case 2: Receiver may be nil
    // → Call through thunk

    llvm::Function *Thunk = CGM.getOrCreateObjCDirectThunk(Method);
    llvm::CallInst *Call = Builder.CreateCall(Thunk, Args);

    Call->setCallingConv(Thunk->getCallingConv());
    // ... other attributes ...

    return RValue::get(Call);
  }
  // llvm::unreachable();

} else {
  // Optimization disabled or not a direct method: use old behavior
  // Call hidden symbol directly (with nil check in implementation)
  // ... existing code ...
}
```

#### Implementation Details:

**1. Locate Direct Method Call Site**
```cpp
// Find where direct methods are called
// Look for: Method->isDirectMethod()
// In CGObjC.cpp, search for "isDirectMethod"
```

**2. Extract Receiver Expression**
```cpp
// For instance methods: receiver is the object
// For class methods: receiver is the class
const Expr *Receiver = /* ... from ObjCMessageExpr ... */;
```

**3. Get True Implementation Function**
```cpp
// The implementation should already exist if defined in current TU (created in Phase 1)
// Get it from the runtime's DirectMethodDefinitions map
llvm::Function *TrueImpl =
    Runtime->GetDirectMethodDefinition(Method);

// If TrueImpl is null, the method is defined in a different Translation Unit
// Create a declaration (prototype) to emit the call
if (!TrueImpl) {
  // Get function type for the method
  llvm::FunctionType *FnTy =
      Types.GetFunctionType(Types.arrangeObjCMethodDeclaration(Method));

  // Generate public symbol name (without \01 prefix)
  std::string Name = Runtime->getSymbolNameForMethod(
      Method, /*includeCategoryName*/ false, /*includePrefixByte*/ false);

  // Create function declaration with ExternalLinkage
  TrueImpl = llvm::Function::Create(FnTy, llvm::GlobalValue::ExternalLinkage,
                                     Name, &getModule());
  TrueImpl->setVisibility(llvm::GlobalValue::HiddenVisibility);
}
```

**4. Handle Variadic Methods (Special Case)**

Variadic methods are excluded from the thunk optimization (`!canHaveNilCheckThunk()`), but still get exposed symbols. The caller must emit an inline nil check:

```cpp
if (CGM.shouldHaveNilCheckInline(OMD)) {
  // Variadic methods: exposed symbols WITHOUT nil checks in implementation
  // Caller emits inline nil check before calling

  llvm::Value *Receiver = /* ... get receiver ... */;

  // Check if receiver is non-null (via nullability analysis)
  if (CGM.isObjCReceiverNonNull(ReceiverExpr, *this)) {
    // Provably non-null: skip nil check, call directly
    llvm::Function *Impl = /* ... get exposed implementation ... */;
    llvm::CallInst *Call = Builder.CreateCall(Impl, Args);
    // ... set attributes ...
    return RValue::get(Call);
  }

  // Potentially null: emit inline nil check
  llvm::BasicBlock *NilCheckBlock = createBasicBlock("varargs.nil.check");
  llvm::BasicBlock *CallBlock = createBasicBlock("varargs.call");
  llvm::BasicBlock *ContBlock = createBasicBlock("varargs.cont");

  // Check if receiver is nil
  llvm::Value *IsNil = Builder.CreateIsNull(Receiver);
  Builder.CreateCondBr(IsNil, NilCheckBlock, CallBlock);

  // Nil case: return zero value
  EmitBlock(NilCheckBlock);
  llvm::Type *RetTy = /* ... get return type ... */;
  llvm::Value *NilRet = RetTy->isVoidTy() ? nullptr
                                          : llvm::Constant::getNullValue(RetTy);
  if (NilRet)
    Builder.CreateStore(NilRet, /* ... result location ... */);
  Builder.CreateBr(ContBlock);

  // Non-nil case: call the implementation
  EmitBlock(CallBlock);
  llvm::Function *Impl = /* ... get exposed implementation ... */;
  llvm::CallInst *Call = Builder.CreateCall(Impl, Args);
  // ... set attributes ...
  if (!RetTy->isVoidTy())
    Builder.CreateStore(Call, /* ... result location ... */);
  Builder.CreateBr(ContBlock);

  // Continue
  EmitBlock(ContBlock);
  return /* ... load result if needed ... */;
}
```

**Rationale**: Variadic methods get exposed symbols (no `\01` prefix) and have NO nil checks in their implementation. Since thunks can't be used (musttail restrictions with va_arg), the caller emits an inline nil check before calling. This still achieves the optimization goal: non-null call sites (like `self`) skip the nil check entirely.

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
// Expected: direct call to @"+[Class classMethod]"
```

---

### Phase 5: Handle Special Cases and Edge Cases ⏸️ **PENDING**

**Objective**: Address corner cases and special scenarios.

#### 5.1: Variadic Methods

**Already handled in Phase 1-4:**
- Excluded from thunk optimization (`canHaveNilCheckThunk()` returns false)
- Keep hidden symbols with nil checks
- Call sites emit inline nil check if needed

**Verify:**
```bash
# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang
```

#### 5.2: ARC Compatibility

**Key Requirement**: Thunks must be transparent to ARC.

**Solution**: Use `musttail` call
- ARC optimizer treats musttail call as direct control transfer
- No ARC operations inserted between thunk and implementation
- Thunk doesn't affect retain/release behavior

**Test with ARC enabled:**
```objc
// Test ARC compatibility
- (id)getObjectDirect:(id)param __attribute__((objc_direct)) {
  return param;
}

void caller(MyClass *obj) {
  id result = [obj getObjectDirect:someObject];
  // ARC should handle retains/releases correctly
}
```

#### 5.3: Struct Return Types (SRet)

**Challenge**: Large structs may use "struct return" parameter convention.

**Detection:**
```cpp
// Check if method uses sret
const CGFunctionInfo &FI = CGM.getTypes().arrangeObjCMethodDeclaration(OMD);
bool UsesSRet = FI.getReturnInfo().isIndirect();
```

**Thunk handling:**
- SRet parameter becomes first parameter (before self)
- Must be correctly forwarded in musttail call
- Zero-initialization writes to sret pointer

**Test:**
```objc
struct LargeStruct {
  int data[100];
};

- (struct LargeStruct)getLargeStruct __attribute__((objc_direct));
```

#### 5.4: Weak-Linked Classes

**For class methods only:**
- Weak-linked classes may be nil at runtime
- Need nil check in thunk for weak-linked class methods

**Implementation** (already in Phase 3):
```cpp
if (OMD->isClassMethod()) {
  // Perform class realization
  // Then check if class is nil (for weak-linked)
}
```

#### 5.5: Properties

**Direct properties** use accessor methods with `objc_direct`:
```objc
@property(direct, readonly) int value;
```

**Implementation:**
- Property accessors are regular direct methods
- Already handled by existing phases
- No special case needed

**Test:**
```objc
@property(direct) int directProp;

int test(MyClass *obj) {
  return obj.directProp;  // Calls getter
}
```

---

### Phase 6: Update and Expand Tests ⏸️ **PENDING**

**Objective**: Comprehensive test coverage for all scenarios.

#### Files to Modify:
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method.m`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-nullability.m`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-thunks.m`

#### Test Scenarios:

**1. Basic Functionality Tests**
```objc
// Test instance method with nullable receiver
// CHECK-LABEL: @testNullableReceiver
// CHECK: call {{.*}} @"-[Class method]_thunk"
int testNullableReceiver(MyClass *obj) {
  return [obj directMethod];
}

// Test instance method with non-null receiver
// CHECK-LABEL: @testNonNullReceiver
// CHECK: call {{.*}} @"-[Class method]"
// CHECK-NOT: _thunk
int testNonNullReceiver(MyClass *_Nonnull obj) {
  return [obj directMethod];
}

// Test self is non-null
// CHECK-LABEL: @"-[Class caller]"
// CHECK: call {{.*}} @"-[Class method]"
// CHECK-NOT: _thunk
- (int)caller {
  return [self directMethod];
}
```

**2. Class Methods**
```objc
// Test class method (class objects are non-null)
// CHECK-LABEL: @testClassMethod
// CHECK: call {{.*}} @"+[Class classMethod]"
// CHECK-NOT: _thunk
int testClassMethod() {
  return [MyClass classMethod];
}
```

**3. Return Type Variations**
```objc
// Test void return
// CHECK-LABEL: @"-[Class voidMethod]"
// CHECK: ret void
- (void)voidMethod __attribute__((objc_direct)) { }

// Test struct return
// CHECK-LABEL: @"-[Class structMethod]"
struct Point { int x, y; };
- (struct Point)structMethod __attribute__((objc_direct)) {
  return (struct Point){1, 2};
}

// Test pointer return
// CHECK-LABEL: @"-[Class objectMethod]"
// CHECK: ret ptr
- (id)objectMethod __attribute__((objc_direct)) {
  return self;
}
```

**4. Thunk Structure Tests**
```objc
// Verify thunk has correct linkage
// CHECK: define linkonce_odr {{.*}} @"-[Class method]_thunk"

// Verify thunk has nil check
// CHECK: icmp eq ptr {{.*}}, null
// CHECK: br i1 {{.*}}, label %nil_case, label %non_nil_case

// Verify nil case returns zero
// CHECK: nil_case:
// CHECK: ret {{.*}} 0

// Verify non-nil case has musttail call
// CHECK: non_nil_case:
// CHECK: musttail call {{.*}} @"-[Class method]"
```

**5. Implementation Tests**
```objc
// Verify implementation has no nil check
// CHECK-LABEL: define {{.*}} @"-[Class method]"
// CHECK-NOT: icmp eq ptr {{.*}}, null
// CHECK-NOT: objc_direct_method.self_is_nil
- (int)method __attribute__((objc_direct)) {
  return 42;
}

// Verify implementation uses public symbol (no \01)
// CHECK-NOT: @"\01-[Class method]"
```

**6. Backward Compatibility Tests**
```objc
// Test without flag enabled
// RUN: %clang_cc1 -emit-llvm -fobjc-arc -triple x86_64-apple-darwin10 %s
// CHECK-LABEL: define hidden {{.*}} @"\01-[Class method]"
// CHECK: icmp eq ptr {{.*}}, null
```

**7. Edge Case Tests**
```objc
// Test variadic (should keep old behavior)
// CHECK-LABEL: define hidden {{.*}} @"\01-[Class varArgs:]"
- (int)varArgs:(int)first, ... __attribute__((objc_direct));

// Test with ARC
// RUN: %clang_cc1 -emit-llvm -fobjc-arc ...
- (id)arcMethod:(id)param __attribute__((objc_direct));

// Test property
@property(direct) int prop;
```

#### Validation Commands:
```bash
# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang
```

---

## Files to Modify

### Summary of All Files

| File | Phases | Purpose |
|------|--------|---------|
| `clang/include/clang/Basic/CodeGenOptions.def` | 0 | Add ObjCNilCheckThunk option |
| `clang/include/clang/Driver/Options.td` | 0 | Add compiler flag |
| `clang/include/clang/AST/DeclObjC.h` | 1 | Add canHaveNilCheckThunk() |
| `clang/lib/CodeGen/CodeGenModule.h` | 1, 2, 3 | Add optimization checks, nullability analysis, thunk cache |
| `clang/lib/CodeGen/CodeGenModule.cpp` | 1, 2, 3 | Implement helper functions |
| `clang/lib/CodeGen/CGObjCRuntime.h` | 1 | Refactor symbol name generation |
| `clang/lib/CodeGen/CGObjCRuntime.cpp` | 1 | Implement symbol name generation |
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
| Phase 0: Infrastructure | 1-2 hours | None |
| Phase 1: Implementation Gen | 1-2 days | Phase 0 |
| Phase 2: Nullability Analysis | 1 day | Phase 1 |
| Phase 3: Thunk Generation | 2-3 days | Phases 1, 2 |
| Phase 4: Call Site Logic | 1-2 days | Phases 1, 2, 3 |
| Phase 5: Special Cases | 1 day | Phase 4 |
| Phase 6: Tests | 1-2 days | All phases |
| **Total** | **1.5-2 weeks** | |

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
