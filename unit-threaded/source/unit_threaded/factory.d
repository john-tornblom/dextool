module unit_threaded.factory;

import unit_threaded.testcase;
import unit_threaded.reflection;
import unit_threaded.asserts;
import unit_threaded.should;

import std.stdio;
import std.traits;
import std.typetuple;
import std.algorithm;
import std.array;
import std.string;
import core.runtime;

/**
 * Replace the D runtime's normal unittest block tester with our own
 */
shared static this() {
    Runtime.moduleUnitTester = &moduleUnitTester;
}

private bool moduleUnitTester() {
    //this is so unit-threaded's own tests run
    foreach(module_; ModuleInfo) {
        if(module_ && module_.unitTest && module_.name.startsWith("unit_threaded")) {
            module_.unitTest()();
        }
    }

    return true;
}


/**
 * Creates tests cases from the given modules.
 * If testsToRun is empty, it means run all tests.
 */
TestCase[] createTestCases(in TestData[] testData, in string[] testsToRun = []) {
    bool[TestCase] tests;
    foreach(const data; testData) {
        if(!isWantedTest(data, testsToRun)) continue;
        auto test = createTestCase(data);
        if(test !is null) tests[test] = true; //can be null if abtract base class
    }

    return tests.keys.sort!((a, b) => a.getPath < b.getPath).array;
}


private TestCase createTestCase(in TestData testData) {
    TestCase createImpl() {
        TestCase testCase;
        if(testData.testFunction is null) // a class, then
            testCase = cast(TestCase) Object.factory(testData.name);
        else
            testCase = testData.builtin ? new BuiltinTestCase(testData) : new FunctionTestCase(testData);

        return testData.shouldFail ? new ShouldFailTestCase(testCase) : testCase;
    }

    auto testCase = createImpl();

    if(testData.singleThreaded) {
        // @Serial tests in the same module run sequentially.
        // A CompositeTestCase is created for each module with at least
        // one @Serial test and subsequent @Serial tests
        // appended to it
        static CompositeTestCase[string] serialComposites;

        const moduleName = testData.name.splitter(".").
            array[0 .. $ - 1].
            reduce!((a, b) => a ~ "." ~ b);

        // create one if not already there
        if(moduleName !in serialComposites) {
            serialComposites[moduleName] = new CompositeTestCase;
        }

        // add the current test to the composite
        serialComposites[moduleName] ~= testCase;
        return serialComposites[moduleName];
    }

    assert(testCase !is null || testData.testFunction is null,
           "Could not create TestCase object for test " ~ testData.name);

    return testCase;
}


private bool isWantedTest(in TestData testData, in string[] testsToRun) {
    if(!testsToRun.length) return !testData.hidden; //all tests except the hidden ones
    bool matchesExactly(in string t) { return t == testData.name; }
    bool matchesPackage(in string t) { //runs all tests in package if it matches
        with(testData) return !hidden && name.length > t.length &&
                       name.startsWith(t) && name[t.length .. $].canFind(".");
    }
    return testsToRun.any!(t => matchesExactly(t) || matchesPackage(t));
}


unittest {
    //existing, wanted
    assert(isWantedTest(TestData("tests.server.testSubscribe"), ["tests"]));
    assert(isWantedTest(TestData("tests.server.testSubscribe"), ["tests."]));
    assert(isWantedTest(TestData("tests.server.testSubscribe"), ["tests.server.testSubscribe"]));
    assert(!isWantedTest(TestData("tests.server.testSubscribe"), ["tests.server.testSubscribeWithMessage"]));
    assert(!isWantedTest(TestData("tests.stream.testMqttInTwoPackets"), ["tests.server"]));
    assert(isWantedTest(TestData("tests.server.testSubscribe"), ["tests.server"]));
    assert(isWantedTest(TestData("pass_tests.testEqual"), ["pass_tests"]));
    assert(isWantedTest(TestData("pass_tests.testEqual"), ["pass_tests.testEqual"]));
    assert(isWantedTest(TestData("pass_tests.testEqual"), []));
    assert(!isWantedTest(TestData("pass_tests.testEqual"), ["pass_tests.foo"]));
    assert(!isWantedTest(TestData("example.tests.pass.normal.unittest"),
                         ["example.tests.pass.io.TestFoo"]));
    assert(isWantedTest(TestData("example.tests.pass.normal.unittest"), []));
    assert(!isWantedTest(TestData("tests.pass.attributes.testHidden", null, true /*hidden*/), ["tests.pass"]));
}
