// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Zero-allocation lexical scanner for Goose source files.
// Extracts tokens with byte offsets and line numbers, plus inline BCE/CRAP pragma comments.
namespace crap;

import std;
import sys.bytes;

let TOK_EOF:    u8 = 0;
let TOK_IDENT:  u8 = 1;
let TOK_NUMBER: u8 = 2;
let TOK_STRING: u8 = 3;

// Keywords (Goose reference §1, Appendix A / spec §2)
let TOK_FN:        u8 = 10;
let TOK_EXTERN:    u8 = 11;
let TOK_NAMESPACE: u8 = 12;
let TOK_STRUCT:    u8 = 13;
let TOK_ENUM:      u8 = 14;
let TOK_IF:        u8 = 15;
let TOK_ELSE:      u8 = 16;
let TOK_GUARD:     u8 = 17;
let TOK_WHILE:     u8 = 18;
let TOK_FOR:       u8 = 19;
let TOK_LOOP:      u8 = 20;
let TOK_MATCH:     u8 = 21;
let TOK_RETURN:    u8 = 22;
let TOK_BREAK:     u8 = 23;
let TOK_CONTINUE:  u8 = 24;
let TOK_AS:        u8 = 25;
let TOK_FROM:      u8 = 26;
let TOK_CONST:     u8 = 27;
let TOK_DEFER:     u8 = 28;
let TOK_BLOCK:     u8 = 29;
let TOK_IMPORT:    u8 = 81;

// Delimiters
let TOK_LPAREN:     u8 = 30;
let TOK_RPAREN:     u8 = 31;
let TOK_LBRACKET:   u8 = 32;
let TOK_RBRACKET:   u8 = 33;
let TOK_LCURLY:     u8 = 34;
let TOK_RCURLY:     u8 = 35;
let TOK_SEMI:       u8 = 36;
let TOK_COMMA:      u8 = 37;
let TOK_COLON:      u8 = 38;
let TOK_COLONCOLON: u8 = 39;
let TOK_DOT:        u8 = 40;
let TOK_DOTDOT:     u8 = 41;
let TOK_ARROW:      u8 = 42;
let TOK_FATARROW:   u8 = 43;

// Logical & ternary
let TOK_ANDAND:   u8 = 50;
let TOK_OROR:     u8 = 51;
let TOK_QUESTION: u8 = 52;

// Arithmetic & shift operators (used for overflow risk detection)
let TOK_PLUS:    u8 = 60;
let TOK_MINUS:   u8 = 61;
let TOK_MUL:     u8 = 62;
let TOK_SHL:     u8 = 63;
let TOK_PLUSEQ:  u8 = 64;
let TOK_MINUSEQ: u8 = 65;
let TOK_MULEQ:   u8 = 66;
let TOK_SHLEQ:   u8 = 67;
let TOK_INC:     u8 = 68;
let TOK_DEC:     u8 = 69;
let TOK_DIV:     u8 = 74;
let TOK_MOD:     u8 = 75;
let TOK_DIVEQ:   u8 = 76;
let TOK_MODEQ:   u8 = 77;

// Other operators
let TOK_LT:     u8 = 70;
let TOK_GT:     u8 = 71;
let TOK_ASSIGN: u8 = 72;
let TOK_BANG:   u8 = 73;
let TOK_OTHER:  u8 = 80;

// Inline comment pragma kinds
let PRAGMA_BCE_KEEP:            u8 = 1;
let PRAGMA_BCE_ELIDE:           u8 = 2;
let PRAGMA_CRAP_UNTRUSTED:      u8 = 3;
let PRAGMA_CRAP_TRUSTED:        u8 = 4;
let PRAGMA_CRAP_IGNORE:         u8 = 5;
let PRAGMA_CRAP_TRUSTED_BOUNDS: u8 = 6;

struct Token {
    kind:  u8  = 0,
    line:  i32 = 1,
    start: i32 = 0,
    len:   i32 = 0,
}

struct LinePragma {
    kind: u8  = 0,
    line: i32 = 1,
}

fn classify_keyword(word: const u8[:]) -> u8 {
    if word == "fn" || word == "thread_fn" { return TOK_FN; }
    if word == "extern" { return TOK_EXTERN; }
    if word == "namespace" { return TOK_NAMESPACE; }
    if word == "struct" { return TOK_STRUCT; }
    if word == "enum" { return TOK_ENUM; }
    if word == "if" { return TOK_IF; }
    if word == "else" { return TOK_ELSE; }
    if word == "guard" { return TOK_GUARD; }
    if word == "while" { return TOK_WHILE; }
    if word == "for" { return TOK_FOR; }
    if word == "loop" { return TOK_LOOP; }
    if word == "match" { return TOK_MATCH; }
    if word == "return" { return TOK_RETURN; }
    if word == "break" { return TOK_BREAK; }
    if word == "continue" { return TOK_CONTINUE; }
    if word == "as" { return TOK_AS; }
    if word == "from" { return TOK_FROM; }
    if word == "const" { return TOK_CONST; }
    if word == "defer" { return TOK_DEFER; }
    if word == "block" { return TOK_BLOCK; }
    if word == "import" { return TOK_IMPORT; }
    return TOK_IDENT;
}

fn scan_comment_pragmas(comment: const u8[:], line: i32, pragmas: LinePragma[>..]&) {
    if slice_contains(comment, "bce:keep") {
        pragmas.push(LinePragma { kind: PRAGMA_BCE_KEEP, line: line });
    }
    if slice_contains(comment, "bce:elide") {
        pragmas.push(LinePragma { kind: PRAGMA_BCE_ELIDE, line: line });
    }
    if slice_contains(comment, "crap:untrusted") || slice_contains(comment, "@untrusted") {
        pragmas.push(LinePragma { kind: PRAGMA_CRAP_UNTRUSTED, line: line });
    }
    if slice_contains(comment, "crap:trusted-bounds") || slice_contains(comment, "@trusted-bounds") {
        pragmas.push(LinePragma { kind: PRAGMA_CRAP_TRUSTED_BOUNDS, line: line });
    }
    if slice_contains(comment, "crap:trusted") || slice_contains(comment, "@trusted") {
        pragmas.push(LinePragma { kind: PRAGMA_CRAP_TRUSTED, line: line });
    }
    if slice_contains(comment, "crap:ignore") {
        pragmas.push(LinePragma { kind: PRAGMA_CRAP_IGNORE, line: line });
    }
}

// Tokenizes a Goose source buffer into `tokens` and `pragmas`.
fn tokenize_goose(src: const u8[:], tokens: Token[>..]&, pragmas: LinePragma[>..]&) {
    var i: i64 = 0;
    let n = src.len;
    var line: i32 = 1;

    while i < n {
        let c = src[i];

        if c == '\n' {
            line++;
            i++;
            continue;
        }
        if c == ' ' || c == '\t' || c == '\r' {
            i++;
            continue;
        }

        // Line comment: // ...
        if c == '/' && i + 1 < n && src[i + 1] == '/' {
            let start = i;
            i += 2;
            while i < n && src[i] != '\n' {
                i++;
            }
            scan_comment_pragmas(src[start..i], line, pragmas);
            continue;
        }

        // Block comment: /* ... */ (supports nested /* ... */ per Goose spec §2)
        if c == '/' && i + 1 < n && src[i + 1] == '*' {
            let start_line = line;
            let start = i;
            i += 2;
            var comment_depth: i32 = 1;
            while i < n && comment_depth > 0 {
                if src[i] == '\n' {
                    line++;
                    i++;
                } else if src[i] == '/' && i + 1 < n && src[i + 1] == '*' {
                    comment_depth++;
                    i += 2;
                } else if src[i] == '*' && i + 1 < n && src[i + 1] == '/' {
                    comment_depth--;
                    i += 2;
                } else {
                    i++;
                }
            }
            scan_comment_pragmas(src[start..i], start_line, pragmas);
            continue;
        }

        // Raw string literal: """ ... """ (no escapes, per Goose spec §2)
        if c == '"' && i + 2 < n && src[i + 1] == '"' && src[i + 2] == '"' {
            let start = i as i32;
            let start_line = line;
            i += 3;
            while i < n {
                if src[i] == '\n' {
                    line++;
                    i++;
                } else if src[i] == '"' && i + 2 < n && src[i + 1] == '"' && src[i + 2] == '"' {
                    i += 3;
                    break;
                } else {
                    i++;
                }
            }
            tokens.push(Token {
                kind:  TOK_STRING,
                line:  start_line,
                start: start,
                len:   (i as i32) - start,
            });
            continue;
        }

        // String or char literal
        if c == '"' || c == '\'' {
            let quote = c;
            let start = i as i32;
            let start_line = line;
            i++;
            while i < n {
                let sc = src[i];
                if sc == '\n' {
                    line++;
                }
                if sc == '\\' && i + 1 < n {
                    i += 2;
                    continue;
                }
                i++;
                if sc == quote {
                    break;
                }
            }
            tokens.push(Token {
                kind:  TOK_STRING,
                line:  start_line,
                start: start,
                len:   (i as i32) - start,
            });
            continue;
        }

        // Identifier or keyword
        if is_ident_start(c) {
            let start = i;
            i++;
            while i < n && is_ident_cont(src[i]) {
                i++;
            }
            let word = src[start..i];
            tokens.push(Token {
                kind:  classify_keyword(word),
                line:  line,
                start: start as i32,
                len:   (i - start) as i32,
            });
            continue;
        }

        // Number literal (supports scientific notation 2.5e-3, 1e+9 and C99 hex floats 0x1.8p-3 per Goose spec §2)
        if is_ascii_digit(c) {
            let start = i;
            i++;
            while i < n {
                let nc = src[i];
                if is_ident_cont(nc) {
                    if (nc == 'e' || nc == 'E' || nc == 'p' || nc == 'P') && i + 1 < n &&
                       (src[i + 1] == '+' || src[i + 1] == '-') {
                        i += 2;
                        continue;
                    }
                    i++;
                } else if nc == '.' && i + 1 < n && is_ascii_digit(src[i + 1]) {
                    i++;
                } else if nc == '.' && i + 1 < n && src[i + 1] != '.' &&
                          start + 1 < n && src[start] == '0' && (src[start + 1] == 'x' || src[start + 1] == 'X') {
                    i++;
                } else {
                    break;
                }
            }
            tokens.push(Token {
                kind:  TOK_NUMBER,
                line:  line,
                start: start as i32,
                len:   (i - start) as i32,
            });
            continue;
        }

        // Multi-character operators
        let start32 = i as i32;
        if i + 2 < n && src[i] == '<' && src[i + 1] == '<' && src[i + 2] == '=' {
            tokens.push(Token { kind: TOK_SHLEQ, line: line, start: start32, len: 3 });
            i += 3;
            continue;
        }
        if i + 2 < n && src[i] == '>' && src[i + 1] == '>' && src[i + 2] == '=' {
            tokens.push(Token { kind: TOK_OTHER, line: line, start: start32, len: 3 });
            i += 3;
            continue;
        }
        if i + 2 < n && src[i] == '.' && src[i + 1] == '=' && src[i + 2] == '=' {
            tokens.push(Token { kind: TOK_OTHER, line: line, start: start32, len: 3 });
            i += 3;
            continue;
        }
        if i + 2 < n && src[i] == '.' && src[i + 1] == '!' && src[i + 2] == '=' {
            tokens.push(Token { kind: TOK_OTHER, line: line, start: start32, len: 3 });
            i += 3;
            continue;
        }
        if i + 1 < n {
            let c2 = src[i + 1];
            var two_kind: u8 = 0;
            if c == '&' && c2 == '&' { two_kind = TOK_ANDAND; }
            else if c == '|' && c2 == '|' { two_kind = TOK_OROR; }
            else if c == '=' && c2 == '>' { two_kind = TOK_FATARROW; }
            else if c == '-' && c2 == '>' { two_kind = TOK_ARROW; }
            else if c == ':' && c2 == ':' { two_kind = TOK_COLONCOLON; }
            else if c == '.' && c2 == '.' { two_kind = TOK_DOTDOT; }
            else if c == '.' && c2 == '=' { two_kind = TOK_ASSIGN; }
            else if c == '+' && c2 == '+' { two_kind = TOK_INC; }
            else if c == '-' && c2 == '-' { two_kind = TOK_DEC; }
            else if c == '+' && c2 == '=' { two_kind = TOK_PLUSEQ; }
            else if c == '-' && c2 == '=' { two_kind = TOK_MINUSEQ; }
            else if c == '*' && c2 == '=' { two_kind = TOK_MULEQ; }
            else if c == '/' && c2 == '=' { two_kind = TOK_DIVEQ; }
            else if c == '%' && c2 == '=' { two_kind = TOK_MODEQ; }
            else if c == '<' && c2 == '<' { two_kind = TOK_SHL; }
            else if c == '=' && c2 == '=' { two_kind = TOK_OTHER; }
            else if c == '!' && c2 == '=' { two_kind = TOK_OTHER; }
            else if c == '<' && c2 == '=' { two_kind = TOK_OTHER; }
            else if c == '>' && c2 == '=' { two_kind = TOK_OTHER; }
            else if c == '>' && c2 == '>' { two_kind = TOK_OTHER; }
            else if c == '&' && c2 == '=' { two_kind = TOK_OTHER; }
            else if c == '|' && c2 == '=' { two_kind = TOK_OTHER; }
            else if c == '^' && c2 == '=' { two_kind = TOK_OTHER; }

            if two_kind != 0 {
                tokens.push(Token { kind: two_kind, line: line, start: start32, len: 2 });
                i += 2;
                continue;
            }
        }

        // Single-character punctuation & operators
        var one_kind: u8 = TOK_OTHER;
        if c == '(' { one_kind = TOK_LPAREN; }
        else if c == ')' { one_kind = TOK_RPAREN; }
        else if c == '[' { one_kind = TOK_LBRACKET; }
        else if c == ']' { one_kind = TOK_RBRACKET; }
        else if c == '{' { one_kind = TOK_LCURLY; }
        else if c == '}' { one_kind = TOK_RCURLY; }
        else if c == ';' { one_kind = TOK_SEMI; }
        else if c == ',' { one_kind = TOK_COMMA; }
        else if c == ':' { one_kind = TOK_COLON; }
        else if c == '.' { one_kind = TOK_DOT; }
        else if c == '?' { one_kind = TOK_QUESTION; }
        else if c == '+' { one_kind = TOK_PLUS; }
        else if c == '-' { one_kind = TOK_MINUS; }
        else if c == '*' { one_kind = TOK_MUL; }
        else if c == '/' { one_kind = TOK_DIV; }
        else if c == '%' { one_kind = TOK_MOD; }
        else if c == '<' { one_kind = TOK_LT; }
        else if c == '>' { one_kind = TOK_GT; }
        else if c == '=' { one_kind = TOK_ASSIGN; }
        else if c == '!' { one_kind = TOK_BANG; }

        tokens.push(Token { kind: one_kind, line: line, start: start32, len: 1 });
        i++;
    }

    tokens.push(Token { kind: TOK_EOF, line: line, start: n as i32, len: 0 });
}
