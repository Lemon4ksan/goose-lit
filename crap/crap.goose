// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// goose-lit: Integrated G-CRAP and Static Risk Engine.
namespace crap;

import std;

import core.bytes;
import core.proc;
import core.time;
import core.test;
import crap.lexer.scanner;
import crap.ast.model;
import crap.ast.analyzer;
import crap.compiler.bridge;
import crap.coverage.profile;
import crap.coverage.instrument;
import crap.metrics.crap;
import crap.report.formatter;
import crap.report.ratchet;
import crap.cli;
