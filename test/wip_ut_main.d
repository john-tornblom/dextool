//Automatically generated by unit_threaded.gen_ut_main, do not edit by hand
import std.stdio;
import std.experimental.testing.runner;

int main(string[] args) {
    writeln(`Running unit tests from dirs ["generator", "translator", "test", "wipapp"]`);
    //dfmt off
    return args.runTests!(
                          "cpptooling.data.representation",
                          "cpptooling.utility.clang",
                          "cpptooling.utility.range",
                          "test.helpers",
                          "wipapp.wip_main"
                          );
    //dfmt on
}
