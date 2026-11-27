# Changelog

## 1.0.0 (2026-11-27)


### Features

* add .litconfig configuration parser and auto-detection for .lit-baseline ([c01a5af](https://github.com/Lemon4ksan/goose-lit/commit/c01a5afae78b46804478b7135a31b559d4880003))
* add baseline grandfathering, exclude globs, command timeouts, and clean up invariants ([19af755](https://github.com/Lemon4ksan/goose-lit/commit/19af75587680dbc4e61c27a7c871492d8cc116dc))
* add gate and inspect subcommands, smart coverage parsing and pipeline quoting fix ([78f6dd9](https://github.com/Lemon4ksan/goose-lit/commit/78f6dd97011837129e266ad6d8de9c0dd00610fb))
* add inspect and bench modules, test suites and python tools ([1e0e531](https://github.com/Lemon4ksan/goose-lit/commit/1e0e5316fe5d1c26ebd24592378f550832b0eefb))
* add native coverage, parallel runner/check/verify, profiler, fuzzer, and alloc counter ([f224eae](https://github.com/Lemon4ksan/goose-lit/commit/f224eaecf16a3c58ff1695202c555af60f41706d))
* **check,runner:** implement CHECK-LABEL isolation, CHECK-SAME, numeric exprs, and xfail/requires ([b389231](https://github.com/Lemon4ksan/goose-lit/commit/b389231c77e2e6c14ea56f296a015427c32d5677))
* **check:** add CHECK-DAG, CHECK-COUNT, regex wildcards, variable capture, and not subcommand ([fc200cd](https://github.com/Lemon4ksan/goose-lit/commit/fc200cd67580b26d974ccab6b9e94012bee7221c))
* **check:** resolve package root entries for internal submodules in check and verify ([797487c](https://github.com/Lemon4ksan/goose-lit/commit/797487c07767e5753b7710d7bd8e96740c2fcc93))
* **config:** add OS-specific cc overrides and RAM-aware auto jobs ([9698fd5](https://github.com/Lemon4ksan/goose-lit/commit/9698fd5488b5034354cc50e596c2ae8a3d6cc72f))
* **config:** support cc and goose_cc configuration and auto-discovery on Windows ([50ba879](https://github.com/Lemon4ksan/goose-lit/commit/50ba8791e3bb95fb56e0d51b46189fc325800bf6))
* **crap:** add v2 baseline snapshot format and temporary binary cleanup ([0b7ac90](https://github.com/Lemon4ksan/goose-lit/commit/0b7ac90cd618cf5616aea15741ce34533c548616))
* **crap:** store canonical relative paths in baseline snapshots and enhance cross-environment path matching ([aedc1c0](https://github.com/Lemon4ksan/goose-lit/commit/aedc1c0cdfa822f4eb955fc5ce24db5bb7acdfc5))
* **infra:** add agent rules, github workflows, and project templates ([2d9ff82](https://github.com/Lemon4ksan/goose-lit/commit/2d9ff822b0b3fad9534b7216e7d670dda516aa5b))
* isolate command capture scratch files in .lit/cache and support auto-executing _test.goose ([89ff9cc](https://github.com/Lemon4ksan/goose-lit/commit/89ff9cc1bb3846a2f3e1b606e371c30fa6f85dac))
* **lit:** initial release of goose-lit test runtime, FileCheck matcher, wire fuzzer and G-CRAP radar ([84b6b66](https://github.com/Lemon4ksan/goose-lit/commit/84b6b66066b1fe5921ab00fbe39387ca8a540f73))
* **proc:** add native host OS, arch, and CPU count introspection shims ([89f4250](https://github.com/Lemon4ksan/goose-lit/commit/89f4250d583b38446a9c178f5a199d63a74bbebe))
* **sloc:** add baseline ratchet, pareto gate, and report formatters ([04c97bd](https://github.com/Lemon4ksan/goose-lit/commit/04c97bd813c2caf20b13c95c81b675045ca6fe0e))
* **sloc:** add model, scanner, smells, dead_fn, and multi-entry bce ([591a958](https://github.com/Lemon4ksan/goose-lit/commit/591a9586ef35490567f732b3367973107df767db))
* **sloc:** add sloc config keys and abs path resolution ([c2f722b](https://github.com/Lemon4ksan/goose-lit/commit/c2f722becb2fb754d70f9578f3d20715e2b85dc3))
* **sloc:** add sloc-map parser and RDTSC cycle correlator ([67e9f2b](https://github.com/Lemon4ksan/goose-lit/commit/67e9f2bc7ecc8d49dfdda18c4c81467d2b392f59))
* **sloc:** wire goose-lit sloc CLI subcommand and tests ([b53db77](https://github.com/Lemon4ksan/goose-lit/commit/b53db7704defd45ee7337fe4ab9b138014f74c36))


### Bug Fixes

* **cli:** eliminate unreachable dead code and generate collision-safe scratch files ([57074c8](https://github.com/Lemon4ksan/goose-lit/commit/57074c8a6f83a7046eed862834e5752979592f9c))
* **crap:** eliminate legacy bounded buffer penalty and fix unary minus operator detection ([a1c6bee](https://github.com/Lemon4ksan/goose-lit/commit/a1c6bee44a9fdf21ceebe6083b069b550c2c9c11))
* **gate,runner:** exempt verified dispatch from EffCC gate and use native slashes on windows ([f546baa](https://github.com/Lemon4ksan/goose-lit/commit/f546baa6dcd19bd0f86d1418748f1805c0f8dea0))
* harden integer parsing and bounded buffers and remove dead code ([81efb87](https://github.com/Lemon4ksan/goose-lit/commit/81efb870719b81f32b817f555a83428b93b74a8c))
* **proc:** expand relative cc path to absolute path in crap_setenv ([a932540](https://github.com/Lemon4ksan/goose-lit/commit/a932540810008f05f83cad33a7e5382d4d3b2cb6))
* resolve beta feedback, compiler bridge, and swarm audit defects ([c180b75](https://github.com/Lemon4ksan/goose-lit/commit/c180b75495c531b5bd71737630bc571a4102d1b0))
* **runner:** embed runtime shim assets for standalone release binaries ([cdd365b](https://github.com/Lemon4ksan/goose-lit/commit/cdd365b1a4c7f17ea7440738e6d2c956c03c0c54))
* **runner:** resolve host features dynamically and preserve POSIX forward slashes ([4f95347](https://github.com/Lemon4ksan/goose-lit/commit/4f95347ba262853b29aef2e93e98b808fe8cadcb))
* **shim:** fix POSIX warnings, normalize LF endings, and scope -mstackrealign to Windows ([f8c4e2a](https://github.com/Lemon4ksan/goose-lit/commit/f8c4e2a8527622a90f084ea2fb8dccc2703f9730))
* **shim:** remove redundant outer quotes in Windows _wpopen command ([5354fe8](https://github.com/Lemon4ksan/goose-lit/commit/5354fe8a552324d87425ad66dae53f81ae693128))
* **sloc:** avoid false delta-packing flag when tokens drop sharply ([18ad84b](https://github.com/Lemon4ksan/goose-lit/commit/18ad84b882ae75b1ff9a747455ee09d814d6e279))
* **sloc:** deduplicate hot-growth credit, shell-free argv exec, and CLI hardening ([0f5f9ed](https://github.com/Lemon4ksan/goose-lit/commit/0f5f9ed3576ab84d4f6ceeb397ddbac23c164d65))
* **sloc:** handle namespace-qualified fn declarations in dead_fn scanner ([6ed139a](https://github.com/Lemon4ksan/goose-lit/commit/6ed139a49e6af2fbbf83c523dbd287c5c3de25a2))
