/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

// #TST-statement_del_call_expression
*/
module dextool_test.mutate_stmt_deletion;

import dextool_test.utility;
import dextool_test.fixtures;

class SdlFixture : MutantFixture {
    override string op() {
        return "sdl";
    }
}

// shall delete the body of functions returning void.
class ShallDeleteBodyOfFuncsReturningVoid : SdlFixture {
    override string programFile() {
        return "sdl_func_body_del.cpp";
    }

    override string op() {
        return "sdl";
    }

    override void test() {
        mixin(EnvSetup(globalTestdir));
        auto r = precondition(testEnv);
        testAnyOrder!SubStr([`from ' f1Global = 2.2; ' to ''`,
                `from ' z = 1.2; ' to ''`, `from ' method1 = 2.2; ' to ''`]).shouldBeIn(r.stdout);

        testAnyOrder!SubStr([`from ' return static_cast<int>(w);`, `from ' return method2`]).shouldNotBeIn(
                r.stdout);
    }
}

class ShallDeleteFuncCalls : SdlFixture {
    override string programFile() {
        return "sdl_func_call.cpp";
    }

    override void test() {
        mixin(EnvSetup(globalTestdir));
        auto r = precondition(testEnv);
        testAnyOrder!SubStr(["'gun()' to ''", "'wun(5)' to ''", "'calc(6)' to ''",
                "'wun(calc(6))' to ''", "'calc(7)' to ''", "'calc(8)' to ''",]).shouldBeIn(
                r.stdout);
        //TODO: maybe these should be deletable too? But it would require forward
        //looking.
        //"'calc(10)' to ''",
        //"'calc(11)' to ''",
    }
}

class ShallDeleteThrowStmt : SdlFixture {
    override string programFile() {
        return "sdl_throw.cpp";
    }

    override void test() {
        mixin(EnvSetup(globalTestdir));
        auto r = precondition(testEnv);

        testAnyOrder!SubStr([`from 'throw Foo()' to ''`]).shouldBeIn(r.stdout);

        // this would result in "throw ;" which is totally junk. This is the
        // old behavior before the introduced fix of being throw aware.
        testAnyOrder!SubStr([`from 'Foo()' to ''`]).shouldNotBeIn(r.stdout);
    }
}

class ShallDeleteAssignment : SdlFixture {
    override string programFile() {
        return "sdl_assignment.cpp";
    }

    override void test() {
        mixin(EnvSetup(globalTestdir));
        auto r = precondition(testEnv);
        testAnyOrder!SubStr([`from 'w = 4' to ''`]).shouldBeIn(r.stdout);

        testAnyOrder!SubStr([`from 'int x = 2' to ''`,
                `from 'bool y = true' to ''`, `from 'int w = 3' to ''`,]).shouldNotBeIn(r.stdout);
    }
}
