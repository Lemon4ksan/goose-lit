// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/filecheck_test.goose - Unit tests for FileCheck engine.
// RUN: goose check %s
import std;
import cli from "..";

fn main() {
    // 1. Basic matching
    let sample_output = """
        Entering main loop
        Parsed 42 items
        Status: OK
        Leaving main loop
        """;

    let test_file = """
        // CHECK: Entering main loop
        // CHECK-NEXT: Parsed 42 items
        // CHECK-NOT: ERROR
        // CHECK: Status: OK
        // CHECK: Leaving main loop
        """;

    var diag1: u8[>..] = [];
    let ok1 = lit::run_filecheck(sample_output, test_file, "CHECK", diag1);
    if !ok1 {
        print("FAIL basic: ", diag1);
        return;
    }

    // 2. CHECK-DAG test (unordered lines)
    let dag_output = """
        Headers:
        Content-Type: text/plain
        Server: goose-wing/0.1
        Date: Thu, 29 Oct 2026
        End
        """;

    let dag_test = """
        // CHECK: Headers:
        // CHECK-DAG: Date: {{.*}}
        // CHECK-DAG: Server: goose-wing/{{[0-9.]+}}
        // CHECK-DAG: Content-Type: text/plain
        // CHECK: End
        """;

    var diag2: u8[>..] = [];
    let ok2 = lit::run_filecheck(dag_output, dag_test, "CHECK", diag2);
    if !ok2 {
        print("FAIL dag: ", diag2);
        return;
    }

    // 3. Variable capture [[VAR:spec]] and reference [[VAR]]
    let var_output = """
        OPEN stream 103 type HTTP2
        PROCESSING stream 103
        CLOSE stream 103
        """;

    let var_test = """
        // CHECK: OPEN stream [[SID:[0-9]+]] type {{.*}}
        // CHECK-NEXT: PROCESSING stream [[SID]]
        // CHECK-NEXT: CLOSE stream [[SID]]
        """;

    var diag3: u8[>..] = [];
    let ok3 = lit::run_filecheck(var_output, var_test, "CHECK", diag3);
    if !ok3 {
        print("FAIL var: ", diag3);
        return;
    }

    // 4. CHECK-COUNT test
    let count_output = """
        Items:
        item: alpha
        item: beta
        item: gamma
        Done
        """;

    let count_test = """
        // CHECK: Items:
        // CHECK-COUNT-3: item: {{.*}}
        // CHECK: Done
        """;

    var diag4: u8[>..] = [];
    let ok4 = lit::run_filecheck(count_output, count_test, "CHECK", diag4);
    if !ok4 {
        print("FAIL count: ", diag4);
        return;
    }

    // 5. CHECK-LABEL, CHECK-SAME, and CHECK-EMPTY test
    let label_output = """
        SECTION Alpha
        Key: Status
        Result: 200 OK detail=fine

        SECTION Beta
        Key: Status
        Result: 404 NOT_FOUND
        """;

    let label_test = """
        // CHECK-LABEL: SECTION Alpha
        // CHECK: Key: Status
        // CHECK: Result: 200
        // CHECK-SAME: OK
        // CHECK-SAME: detail=fine
        // CHECK-EMPTY:
        // CHECK-LABEL: SECTION Beta
        // CHECK: Key: Status
        // CHECK: Result: 404
        // CHECK-SAME: NOT_FOUND
        """;

    var diag5: u8[>..] = [];
    let ok5 = lit::run_filecheck(label_output, label_test, "CHECK", diag5);
    if !ok5 {
        print("FAIL label_same_empty: ", diag5);
        return;
    }

    // 6. Numeric FileCheck [[#VAR:]], [[#VAR + N]], [[#VAR - N]], [[#]]
    let num_output = """
        PACKET_TX pn=100 len=48
        PACKET_ACK pn=100
        PACKET_TX pn=101 len=32
        PACKET_TX pn=110 len=64
        PACKET_RETX pn=95 len=16
        """;

    let num_test = """
        // CHECK: PACKET_TX pn=[[#PN:]] len=[[#]]
        // CHECK: PACKET_ACK pn=[[#PN]]
        // CHECK-NEXT: PACKET_TX pn=[[#PN + 1]] len=[[#]]
        // CHECK: PACKET_TX pn=[[#PN + 10]] len=[[#]]
        // CHECK: PACKET_RETX pn=[[#PN - 5]] len=[[#]]
        """;

    var diag6: u8[>..] = [];
    let ok6 = lit::run_filecheck(num_output, num_test, "CHECK", diag6);
    if !ok6 {
        print("FAIL numeric_expr: ", diag6);
        return;
    }

    // 7. CHECK-LABEL isolation negative test
    // Target is in SECTION Beta, but sought in SECTION Alpha -> MUST fail!
    let iso_test = """
        // CHECK-LABEL: SECTION Alpha
        // CHECK: Result: 404
        // CHECK-LABEL: SECTION Beta
        """;

    var diag7: u8[>..] = [];
    let ok7 = lit::run_filecheck(label_output, iso_test, "CHECK", diag7);
    if ok7 {
        print("FAIL label_isolation: pattern from Beta matched in Alpha!");
        return;
    }

    print("FileCheck self-test passed!");
}
