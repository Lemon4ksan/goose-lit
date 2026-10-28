# Agent rules

Guidelines and invariants for agents working in the `goose-lit` repository.

## Commit conventions and releases

Releases are automated via Google's `release-please` workflow on `main`.

- Follow the Conventional Commits specification for all commit messages:
  - `feat:` for new capabilities.
  - `fix:` for bug fixes.
  - `refactor:` for code restructuring without behavioral changes.
  - `perf:` for performance optimizations.
  - `style:` for formatting or whitespace changes.
  - `test:` for adding or adjusting test suites.
  - `chore:` for toolchain, workflow, or build adjustments.
- Mark breaking changes with an exclamation mark after the type or scope (`feat!:`, `refactor(wire)!:`) or provide a `BREAKING CHANGE:` footer in the commit body.
- Version tracking resides in `version.txt`. Do not bump `version.txt` by hand during feature branches; let `release-please` manage version bumps and `CHANGELOG.md` updates through its release PR.

## Local verification and testing

- Run typecheck validation before opening a pull request or finalizing a commit:
  ```powershell
  just check
  ```
- Run the full test suite:
  ```powershell
  just test
  ```
- Run the LIT test runner directly:
  ```powershell
  just lit
  ```
- Verify license headers across tracked source files:
  ```powershell
  just license-check
  ```
- Check code formatting:
  ```powershell
  just fmt-check
  ```

## Engineering invariants

- Zero library dependency on production targets: `goose-lit` is an external verification runtime. Production targets do not link against `goose-lit` internal modules.
- Slice ABI contract: borrowed byte slices (`const u8[:]`) serve as the sole data boundary contract between test harnesses and verified targets.
- Allocation discipline: zero dynamic memory allocation on wire inspection, prefix slicing, mutation, and FileCheck pattern matching hot paths. Use bounded inline buffers and stack slices.
- Thread isolation: interactive runs and fuzzing iterations execute in contained threads (`thread_spawn_contained`) or isolated child processes (`shim/proc.c`) so traps and aborts are captured deterministically.
- File endings: use Unix line feeds (`\n`) for all repository files.
- Goose language declarations: write extern symbols after function signatures (Goose section 7.10):
  ```goose
  extern fn native_exec_to_file(cmd: const u8[:], out_path: const u8[:]) -> i32 = "crap_exec_to_file";
  ```
- Generic function passing: in Goose, function values are compile-time only and cannot be stored or re-passed as variables (Goose section 18). Define generic callers with `fn verify<F: fn(...) -> ...>(...)` and call `F(...)` directly in the function body.

## Verification pipeline architecture

The runtime organizes testing into four distinct stages:

1. Static gate and bounds check elimination radar (`lit::crap`):
   - Computes cyclomatic complexity, cognitive complexity, and effective nesting depth.
   - Evaluates bounds-check elimination data (`goose --bce-lines`) to flag unproven index lookups (`unproven_bce`).
   - Assesses function risk archetypes (`SAFE_PRIMITIVE`, `VERIFIED_DISPATCH`, `FUZZ_PRIORITY`, `PANIC_HAZARD`).
   - Generates structured SARIF, JSON, and TSV diagnostics for continuous integration.

2. Hardware page edge positioning and stream verification (`lit::wire`):
   - Aligns buffers against hardware page boundaries (`65536 - len`) to detect out-of-bounds reads.
   - Slices binary streams across all prefixes `1..len` to confirm parsers reject truncated frames gracefully without crashing.
   - Mutates payloads using deterministic pseudo-random sequences (`xorshift64_step`).
   - Inspects linear memory in formatted hex dumps and 128-bit SIMD lane representations.

3. FileCheck output assertions (`lit::check`):
   - Scans program standard output and standard error for pattern directives.
   - Supports `CHECK:`, `CHECK-NEXT:`, `CHECK-NOT:`, `CHECK-LABEL:`, `CHECK-SAME:`, and `CHECK-EMPTY:`.

4. Test execution runner (`lit::runner`):
   - Discovers test files matching `.goose` or `.lit` extensions.
   - Parses `// RUN:` commands in comments, substituting `%s` (source file), `%S` (source directory), `%t` (temporary file), `%FileCheck`, and `%lit`.
   - Executes pipelines and aggregates execution times and pass/fail statuses.

## Documentation and communication style

- Start directly with facts or actions taken without conversational filler or polite sign-offs.
- Avoid AI buzzwords (`crucial`, `robust`, `comprehensive`, `seamlessly`, `vital`, `testament`, `delve`, `meticulously`, `pivotal`, `leverage`).
- Use sentence case for headings, straight quotes (`'` and `"`), and hyphens, commas, or parentheses instead of em dashes (`—`).
- Avoid inline bold-colon list structures (`- **Item**: explanation`).
- Link file paths with clickable `file:///` markdown links and wrap symbols and paths in backticks.
