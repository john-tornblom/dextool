/**
Copyright: Copyright (c) 2016, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.
*/
module cpptooling.analyzer.clang.ast.tree;

import logger = std.experimental.logger;

import clang.Cursor : Cursor;

import deimos.clang.index : CXCursorKind;

import cpptooling.analyzer.clang.ast.attribute;
import cpptooling.analyzer.clang.ast.declaration;
import cpptooling.analyzer.clang.ast.directive;
import cpptooling.analyzer.clang.ast.expression;
import cpptooling.analyzer.clang.ast.preprocessor;
import cpptooling.analyzer.clang.ast.reference;
import cpptooling.analyzer.clang.ast.statement;
import cpptooling.analyzer.clang.ast.translationunit;

import cpptooling.analyzer.clang.ast.nodes : CXCursorKind_PrefixLen;

version (unittest) {
    import unit_threaded : Name, shouldEqual, shouldBeTrue;
} else {
    private struct Name {
        string name_;
    }
}

private enum hasIncrDecr(VisitorT) = __traits(hasMember, VisitorT, "incr")
        && __traits(hasMember, VisitorT, "decr");

/**
 * Wrap a clang cursor. No restrictions on what type of cursor it is.
 * Accept a Visitor.
 * During accept traverse the AST to:
 *  - wrap Cursors's in specific classes corresponding to the kind of cursor.
 *  - call Visitor's visit(...) with wrapped cursor.
 *
 * Starts traversing the AST from the root.
 *
 * Optional functions:
 *   void incr(). Called before descending a node.
 *   void decr(). Called after ascending a node.
 */
struct ClangAST(VisitorT) {
    import std.traits : isArray;
    import clang.Cursor : Cursor;

    Cursor root;

    void accept(ref VisitorT visitor) @safe {
        static if (isArray!VisitorT && hasIncrDecr!(typeof(VisitorT.init[0]))) {
            foreach (v; visitor) {
                v.incr();
            }

            scope (success) {
                foreach (v; visitor) {
                    v.decr();
                }
            }

        } else if (hasIncrDecr!VisitorT) {
            visitor.incr();
            scope (success)
                visitor.decr();
        }

        dispatch(root, visitor);
    }
}

/** Apply the visitor to the children of the cursor.
 *
 * Optional functions:
 *   void incr(). Called before descending a node.
 *   void decr(). Called after ascending a node.
 */
void accept(VisitorT)(ref const(Cursor) cursor, ref VisitorT visitor) @safe {
    import std.traits : isArray;
    import clang.Visitor : Visitor;

    static if (isArray!VisitorT && hasIncrDecr!(typeof(VisitorT.init[0]))) {
        foreach (v; visitor) {
            v.incr();
        }

        scope (success) {
            foreach (v; visitor) {
                v.decr();
            }
        }

    } else if (hasIncrDecr!VisitorT) {
        visitor.incr();
        scope (success)
            visitor.decr();
    }

    () @trusted{
        foreach (child, _; Visitor(cursor)) {
            dispatch(child, visitor);
        }
    }();
}

/** Static wrapping of the cursor followed by a passing it to the visitor.
 *
 * The cursor is wrapped in the class that corresponds to the kind of the
 * cursor.
 *
 * Note that the mixins shall be ordered alphabetically.
 */
void dispatch(VisitorT)(ref const(Cursor) cursor, ref VisitorT visitor) @safe {
    import cpptooling.analyzer.clang.ast.nodes;
    import std.conv : to;

    switch (cursor.kind) {
        mixin(wrapCursor!(visitor, cursor)(AttributeSeq));
        mixin(wrapCursor!(visitor, cursor)(DeclarationSeq));
        mixin(wrapCursor!(visitor, cursor)(DirectiveSeq));
        mixin(wrapCursor!(visitor, cursor)(ExpressionSeq));
        mixin(wrapCursor!(visitor, cursor)(PreprocessorSeq));
        mixin(wrapCursor!(visitor, cursor)(ReferenceSeq));
        mixin(wrapCursor!(visitor, cursor)(StatementSeq));
        mixin(wrapCursor!(visitor, cursor)(TranslationUnitSeq));

    default:
        debug logger.trace("Node not handled:", to!string(cursor.kind));
    }
}

private:

string wrapCursor(alias visitor, alias cursor)(immutable(string)[] cases) {
    import cpptooling.analyzer.clang.ast.nodes : CXCursorKind_PrefixLen;
    import std.format : format;

    static if (is(typeof(visitor) : T[], T)) {
        // is an array
        enum visit = "foreach (v; " ~ visitor.stringof ~ ") { v.visit(wrapped); }";
    } else {
        enum visit = visitor.stringof ~ ".visit(wrapped);";
    }

    //TODO allocate in an allocator, not GC with "new"
    string result;

    foreach (case_; cases) {
        string case_skip = case_[CXCursorKind_PrefixLen .. $];
        result ~= format("case CXCursorKind.%s: auto wrapped = new %s(%s); %s break;\n",
                case_, case_skip, cursor.stringof, visit);
    }

    return result;
}

@Name("Should be a bounch of 'case'")
unittest {
    import std.conv : to;

    enum Dummy {
        xCase1,
        xCase2
    }

    int visitor;
    int cursor;

    wrapCursor!(visitor, cursor)(["Dummy.xCase1", "Dummy.xCase2"]).shouldEqual(
            "case Dummy.xCase1: auto wrapped = new Case1(cursor); visitor.visit(wrapped); break;
case Dummy.xCase2: auto wrapped = new Case2(cursor); visitor.visit(wrapped); break;
");
}

@Name("A name for the test")
@safe unittest {
    import cpptooling.analyzer.clang.ast : Visitor;
    import cpptooling.analyzer.clang.ast.nodes;

    final class TestVisitor : Visitor {
        alias visit = Visitor.visit;

        bool attribute;
        override void visit(const(Attribute)) {
            attribute = true;
        }

        bool declaration;
        override void visit(const(Declaration)) {
            declaration = true;
        }

        bool directive;
        override void visit(const(Directive)) {
            directive = true;
        }

        bool expression;
        override void visit(const(Expression)) {
            expression = true;
        }

        bool preprocessor;
        override void visit(const(Preprocessor)) {
            preprocessor = true;
        }

        bool reference;
        override void visit(const(Reference)) {
            reference = true;
        }

        bool statement;
        override void visit(const(Statement)) {
            statement = true;
        }

        bool translationunit;
        override void visit(const(TranslationUnit)) {
            translationunit = true;
        }
    }

    auto test = new TestVisitor;

    Cursor cursor;

    foreach (kind; [__traits(getMember, CXCursorKind, AttributeSeq[0]), __traits(getMember,
            CXCursorKind, DeclarationSeq[0]), __traits(getMember, CXCursorKind,
            DirectiveSeq[0]), __traits(getMember, CXCursorKind,
            ExpressionSeq[0]), __traits(getMember, CXCursorKind, PreprocessorSeq[0]), __traits(getMember, CXCursorKind,
            ReferenceSeq[0]), __traits(getMember, CXCursorKind, StatementSeq[0]),
            __traits(getMember, CXCursorKind, TranslationUnitSeq[0])]) {
        switch (kind) {
            mixin(wrapCursor!(test, cursor)(AttributeSeq));
            mixin(wrapCursor!(test, cursor)(DeclarationSeq));
            mixin(wrapCursor!(test, cursor)(DirectiveSeq));
            mixin(wrapCursor!(test, cursor)(ExpressionSeq));
            mixin(wrapCursor!(test, cursor)(PreprocessorSeq));
            mixin(wrapCursor!(test, cursor)(ReferenceSeq));
            mixin(wrapCursor!(test, cursor)(StatementSeq));
            mixin(wrapCursor!(test, cursor)(TranslationUnitSeq));
        default:
            assert(0);
        }
    }

    test.attribute.shouldBeTrue;
    test.declaration.shouldBeTrue;
    test.directive.shouldBeTrue;
    test.expression.shouldBeTrue;
    test.preprocessor.shouldBeTrue;
    test.reference.shouldBeTrue;
    test.statement.shouldBeTrue;
    test.translationunit.shouldBeTrue;
}
