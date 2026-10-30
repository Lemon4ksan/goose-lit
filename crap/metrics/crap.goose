// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Mathematical engine for Classic CRAP and Modified G-CRAP metrics.
// Conforms to the G-CRAP mathematical model:
// 1. Classic CRAP: CC^2 * (1 - cov)^3 + CC
// 2. Risk_struct: EffCC^2 * (1 - cov)^3
// 3. Risk_safety: sum_{b in U(m)} depth(b) * (alpha * bce_keep(b) + beta * ovf(b))
// 4. G-CRAP: Risk_struct + Risk_safety
namespace crap;

import std;
import crap.ast.model;

fn cube_f64(x: f64) -> f64 {
    return x * x * x;
}

// Computes classic CRAP and modified G-CRAP for each function.
fn compute_crap_metrics(
    cfg:       const RiskConfig&,
    functions: FunctionInfo[>..]&,
    branches:  const BranchSite[:],
) {
    for fi in functions.len {
        let cc = functions[fi].cyclomatic_cc as f64;
        let eff_cc = functions[fi].effective_cc as f64;
        let cov = functions[fi].cov_branch;

        let uncov_fraction = if cov <= 1.0 { 1.0 - cov } else { 0.0 };
        let uncov_cubed = cube_f64(uncov_fraction);

        // 1. Classic CRAP: CC^2 * (1 - cov)^3 + CC
        let classic = (cc * cc * uncov_cubed) + cc;
        functions[fi].classic_crap = classic;

        // 2. Structural Risk: EffCC^2 * (1 - cov)^3 (zero linear floor!)
        let r_struct = eff_cc * eff_cc * uncov_cubed;
        functions[fi].risk_struct = r_struct;

        // 3. Safety Risk: sum over uncovered branches
        var r_safety: f64 = 0.0;
        let first = functions[fi].first_branch;
        let count = functions[fi].branch_count;

        for bi in count {
            let idx: i64 = first + bi;
            if idx < branches.len {
                let b = branches[idx];
                if !b.covered {
                    let d = (if b.depth > 0 { b.depth } else { 1 }) as f64;
                    let bce_term = b.bce_keep * cfg.alpha_bce_keep;
                    let ovf_term = b.ovf_ops * cfg.beta_ovf;
                    r_safety += d * (bce_term + ovf_term);
                }
            }
        }
        functions[fi].risk_safety = r_safety;

        // 4. Composite G-CRAP
        let g_crap_val = r_struct + r_safety;
        functions[fi].g_crap = g_crap_val;

        // 5. Fuzzing priority score with --specs fusion
        var fuzz_score = g_crap_val;
        if functions[fi].trust_class == TRUST_UNTRUSTED {
            fuzz_score *= cfg.untrusted_weight;
        }
        if functions[fi].has_noinline {
            fuzz_score *= 1.25;
        }
        if functions[fi].max_spec_nodes >= 200 {
            fuzz_score *= 1.2;
        }
        functions[fi].fuzz_priority = fuzz_score;

        // 6. Assign diagnostic archetype with --specs fusion
        if functions[fi].uninstantiated_generic {
            functions[fi].archetype = ARCHETYPE_DEAD_CODE_AUDIT;
        } else if functions[fi].cyclomatic_cc >= 20 && cov >= 0.99 && functions[fi].uncovered_bce_keep == 0 {
            functions[fi].archetype = ARCHETYPE_VERIFIED_DISPATCH;
        } else if functions[fi].uncovered_bce_keep > 0 && cov < 0.99 {
            functions[fi].archetype = ARCHETYPE_PANIC_HAZARD;
        } else if functions[fi].trust_class == TRUST_UNTRUSTED &&
                   (g_crap_val >= cfg.gcrap_threshold || cov < 0.5) {
            functions[fi].archetype = ARCHETYPE_FUZZ_PRIORITY;
        } else if cov >= 0.90 && functions[fi].uncovered_bce_keep == 0 {
            functions[fi].archetype = ARCHETYPE_SAFE_PRIMITIVE;
        } else if cov >= 0.50 && cov < 1.0 {
            functions[fi].archetype = ARCHETYPE_DEAD_CODE_AUDIT;
        } else {
            functions[fi].archetype = ARCHETYPE_LOW_PRIORITY;
        }
    }
}
