# Issue #134: Generator Relies on Undocumented `_`-Prefix Convention for Synthetic oneofs

## Priority: P2 Medium

## Problem

`scripts/gen_python_proto.py:327–338` detects real proto `oneof` blocks versus synthetic oneofs (created by the `optional` keyword in proto3) by checking whether `oneofDecl[i]["name"]` starts with `"_"`. This works because `protoc` and `buf` use a naming convention where synthetic oneofs have names like `_image`, `_author`, etc. (the field name prefixed with `_`).

However, this is an **undocumented implementation detail** of `buf`/`protoc`. It is not specified in the protobuf language specification or the `buf` documentation. If `buf` or `protoc` changes this naming convention in a future release, the generator will silently produce incorrect output:
- Real oneofs whose first field name starts with `_` would be misclassified as synthetic (no validator generated).
- Synthetic oneofs whose field names do not follow the `_` convention would be misclassified as real (spurious validators generated — breaking at test time but hard to diagnose).

## Impact

Validator drift: if `buf` changes the synthetic oneof naming convention, `ClassifyRequest` would lose its `_validate_input_oneof` validator silently. Requests with both `image` and `image_url` set would be accepted instead of rejected with a validation error, potentially causing model inference errors or unexpected behaviour downstream.

## Evidence

- `scripts/gen_python_proto.py:327` — `_get_real_oneof_groups`: `if not name.startswith("_")`
- No reference to the `buf` or `protoc` specification justifying this convention.
- The `proto3` specification states that `optional` fields are represented as a synthetic oneof in the descriptor, but does not mandate the `_` prefix naming.
- This convention has been stable in `protoc` since proto3 optional was introduced (proto3.5+), but there is no guarantee of permanence.

## Suggested Fix

1. Add a comment in `gen_python_proto.py` that cites the protoc source/issue that establishes this convention (e.g., `google/protobuf/descriptor.pb.go` or the protobuf GitHub issue where proto3 optional was introduced).
2. Add a unit test for `_get_real_oneof_groups` that runs against a known descriptor fixture — both a real oneof and a synthetic oneof — and asserts correct classification.
3. Consider an additional guard: if `proto3Optional=true` is set on the field, treat the oneof as synthetic regardless of the name. This is a more robust signal because `proto3Optional` IS part of the descriptor specification.

The `proto3Optional` field on the `FieldDescriptorProto` is the correct machine-readable indicator, not the `_` prefix. The `_` prefix is a naming side-effect, not the semantic signal.

## Agent Assignment

python-agent

## Definition of Done

- [ ] `_get_real_oneof_groups` uses `proto3Optional` field as the primary synthetic oneof signal
- [ ] Comment cites authoritative source for the synthetic oneof convention
- [ ] Unit test for `_get_real_oneof_groups` with both real and synthetic oneof fixtures
