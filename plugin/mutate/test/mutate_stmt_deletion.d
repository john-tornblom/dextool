/**
Copyright: Copyright (c) 2017, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module dextool_test.mutate_stmt_deletion;

import dextool_test.utility;

// dfmt off

@("shall successfully run the ABS mutator (no validation of the result)")
unittest {
    mixin(EnvSetup(globalTestdir));

    makeDextool(testEnv)
        .addInputArg(testData ~ "statement_deletion.cpp")
        .addArg(["--mode", "analyzer"])
        .run;
    makeDextool(testEnv)
        .addArg(["--mode", "test_mutants"])
        .addArg(["--mutant-compile", "/bin/true"])
        .addArg(["--mutant-test", "/bin/true"])
        .addArg(["--mutant-test-runtime", "10000"])
        .addArg(["--mutation", "stmtDel"])
        .run;
}