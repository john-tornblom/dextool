// Written in ehe D programming language.
/**
Date: 2015-2016, Joakim Brännström
License: MPL-2, Mozilla Public License 2.0
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Version: Initial created: Jan 30, 2012
Copyright (c) 2012 Jacob Carlborg. All rights reserved.

Pass1, implicit anonymous struct and unions.
Pass2, struct or union decl who has no name.
Pass3, anonymous instantiated types.
Pass4, generic, last decision point for deriving data from the cursor.
PassType, derive type from the cursors type.
*/
module cpptooling.analyzer.clang.type;

import std.algorithm : among;
import std.conv : to;
import std.string : format;
import std.traits;
import std.typecons : Flag, Yes, No, Nullable, Tuple;
import logger = std.experimental.logger;

import deimos.clang.index : CXTypeKind;
import clang.Cursor : Cursor;
import clang.Type : Type;

public import cpptooling.analyzer.type;
import cpptooling.data.type : Location;

/// Find the first typeref node, if any.
auto takeOneTypeRef(T)(auto ref T in_) {
    import std.range : takeOne;
    import std.algorithm : filter, among;

    return in_.filter!(a => a.kind >= CXCursorKind.CXCursor_TypeRef
            && a.kind <= CXCursorKind.CXCursor_LastRef);
}

/** Iteratively try to construct a USR that is reproducable from the cursor.
 *
 * Only use when c.usr may return the empty string.
 *
 * Fallback case, using location to make it unique.
 */
private USRType makeFallbackUSR(ref Cursor c, in uint this_indent)
out (result) {
    import cpptooling.utility.logger;

    trace(cast(string) result, this_indent);
    assert(result.length > 0);
}
body {
    import std.array : appender;
    import std.conv : to;
    import clang.SourceLocation;

    // strategy 1, derive from lexical parent
    auto loc_ = backtrackLocation(c);

    // strategy 2, I give up.
    // Problem with this is that it isn't possible to reverse engineer.
    //TODO fix the magic number 100. Coming from an internal state of backtrackLocation. NOT GOOD
    // Checking if it is null_ should have been enough
    if (loc_.tag.kind == BacktrackLocation.Tag.Kind.null_ || loc_.backtracked == 100) {
        loc_.backtracked = 1;
        loc_.tag = c.toHash.to!string;
    }

    auto app = appender!string();
    putBacktrackLocation(c, loc_, app);

    return USRType(app.data);
}

private USRType makeUSR(string s)
out (result) {
    assert(result.length > 0);
}
body {
    return USRType(s);
}

void logType(ref Type type, in uint indent = 0, string func = __FUNCTION__, uint line = __LINE__) {
    import std.array : array;
    import std.range : repeat;
    import logger = std.experimental.logger;
    import clang.info;

    // dfmt off
    debug {
        string indent_ = repeat(' ', indent).array();
        logger.logf!(-1, "", "", "", "")
            (logger.LogLevel.trace,
             "%d%s %s|%s|%s|%s|%s [%s:%d]",
             indent,
             indent_,
             type.cursor.usr,
             type.kind,
             abilities(type),
             type.isValid ? "valid" : "invalid",
             type.typeKindSpelling,
             func,
             line);
    }
    // dfmt on
}

void assertTypeResult(const ref TypeResult result) {
    import std.range : chain, only;

    foreach (const ref tka; chain(only(result.primary), result.extra)) {
        assert(tka.toStringDecl("x").length > 0);
        assert(tka.kind.usr.length > 0);
        if (!tka.attr.isPrimitive) {
            assert(tka.kind.loc.file.length > 0);
        }
    }
}

struct BacktrackLocation {
    static import clang.SourceLocation;
    import cpptooling.utility.taggedalgebraic : TaggedAlgebraic;

    union TagType {
        typeof(null) null_;
        clang.SourceLocation.SourceLocation.Location loc;
        string spelling;
    }

    alias Tag = TaggedAlgebraic!TagType;

    Tag tag;

    /// Number of nodes backtracked through until a valid was found
    int backtracked;
}

/** Lexical backtrack from the argument cursor to first cursor with a valid
 * location.
 *
 * using a for loop to ensure it is NOT an infinite loop.
 * hoping 100 is enough for all type of nesting to reach at least translation
 * unit.
 *
 * Return: Location and nr of backtracks needed.
 */
private BacktrackLocation backtrackLocation(ref Cursor c) {
    import clang.SourceLocation : toString;

    BacktrackLocation rval;

    auto parent = c;
    for (rval.backtracked = 0; rval.tag.kind == BacktrackLocation.Tag.Kind.null_
            && rval.backtracked < 100; ++rval.backtracked) {
        auto loc = parent.location;
        if (loc.spelling.file is null) {
            // do nothing
        } else if (loc.toString.length != 0) {
            rval.tag = loc.toString;
        } else if (parent.isTranslationUnit) {
            rval.tag = loc.toString;
            break;
        }

        parent = parent.lexicalParent;
    }

    return rval;
}

/// TODO consider if .offset should be used too. But may make it harder to
/// reverse engineer a location.
private void putBacktrackLocation(T)(ref Cursor c, BacktrackLocation back_loc, ref T app) {
    // using a suffix that do NOT exist in the clang USR standard.
    // TODO lookup the algorithm for clang USR to see if $ is valid.
    enum marker = '$';

    final switch (back_loc.tag.kind) with (BacktrackLocation.Tag) {
    case Kind.loc:
        app.put(back_loc.tag.toString);
        break;
    case Kind.spelling:
        app.put(to!string(back_loc.tag));
        break;
    case Kind.null_:
        break;
    }
    app.put(marker);
    app.put(back_loc.backtracked.to!string);
    app.put(c.spelling);
}

private Location makeLocation(ref Cursor c) {
    import std.array : appender;

    auto loc = c.location.spelling;
    auto rval = Location(loc.file.name, loc.line, loc.column);

    if (rval.file.length > 0) {
        return rval;
    }

    auto back_loc = backtrackLocation(c);

    auto app = appender!string();
    putBacktrackLocation(c, back_loc, app);

    rval.file = app.data;
    return rval;
}

TypeAttr makeTypeAttr(ref Type type) {
    TypeAttr attr;

    attr.isConst = cast(Flag!"isConst") type.isConst;
    attr.isRef = cast(Flag!"isRef")(type.kind == CXTypeKind.CXType_LValueReference);
    attr.isPtr = cast(Flag!"isPtr")(type.kind == CXTypeKind.CXType_Pointer);
    attr.isArray = cast(Flag!"isArray") type.isArray;
    attr.isRecord = cast(Flag!"isRecord")(type.kind == CXTypeKind.CXType_Record);

    return attr;
}

TypeKindAttr makeTypeKindAttr(ref Type type) {
    TypeKindAttr tka;
    tka.attr = makeTypeAttr(type);

    return tka;
}

TypeKindAttr makeTypeKindAttr(ref Type type, ref TypeKind tk) {
    auto tka = makeTypeKindAttr(type);
    tka.kind = tk;

    return tka;
}

import deimos.clang.index : CXCursorKind;
import cpptooling.data.symbol.container : Container;
import cpptooling.data.symbol.types : USRType;
import cpptooling.utility.clang : logNode;

/** Deduct the type the node represents.
 *
 * pass 1, implicit anonymous structs and unions.
 * pass 2, implicit types aka no spelling exist for them.
 * pass 3, instansiated anonymous types and typedef of anonymous.
 * pass 4, normal nodes, typedefs and references.
 * passType, collect type information. The final result in most cases.
 *
 * TODO add "in" to parameter c.
 *
 * Params:
 *  c = cursor to retrieve from.
 *  container = container holding type symbols.
 *  indent = ?
 */
Nullable!TypeResult retrieveType(ref Cursor c, ref const Container container, in uint indent = 0)
in {
    logNode(c, indent);

    // unable to derive anything useful from a typeref when based on nothing else.
    // __va_list is an examle (found in stdarg.h).
    if (indent == 0 && c.kind.among(CXCursorKind.CXCursor_TypeRef,
            CXCursorKind.CXCursor_CXXBaseSpecifier, CXCursorKind.CXCursor_TemplateRef,
            CXCursorKind.CXCursor_NamespaceRef,
            CXCursorKind.CXCursor_MemberRef, CXCursorKind.CXCursor_LabelRef)) {
        assert(false);
    }
}
out (result) {
    logTypeResult(result, indent);

    // ensure no invalid data is returned
    if (!result.isNull && indent == 0) {
        assertTypeResult(result.get);
    }
}
body {
    import std.range;

    Nullable!TypeResult rval;

    // bail early
    if (c.kind.among(CXCursorKind.CXCursor_MacroDefinition)) {
        return rval;
    }

    foreach (pass; only(&pass1, &pass2, &pass3)) {
        auto r = pass(c, indent + 1);
        if (!r.isNull) {
            rval = TypeResult(r, null);
            return rval;
        }
    }

    rval = pass4(c, container, indent + 1);
    return rval;
}

/** Pass 1, implicit anonymous types for struct and union.
 */
private Nullable!TypeKindAttr pass1(ref Cursor c, uint indent)
in {
    logNode(c, indent);
}
body {
    Nullable!TypeKindAttr rval;

    if (!c.isAnonymous) {
        return rval;
    }

    switch (c.kind) with (CXCursorKind) {
    case CXCursor_StructDecl:
        goto case;
    case CXCursor_UnionDecl:
        auto type = c.type;
        rval = makeTypeKindAttr(type);

        string spell = type.spelling;
        rval.kind.info = TypeKind.SimpleInfo(spell ~ " %s");
        rval.kind.usr = USRType(c.usr);
        rval.kind.loc = makeLocation(c);
        break;
    default:
    }

    return rval;
}

/** Pass 2, detect anonymous types who has "no name".
 *
 * Only struct, enum, union can possibly have this attribute.
 * The types name.
 *
 * TODO consider using the identifier as the spelling.
 *
 * Example:
 * ---
 * struct (implicit name) { <-- and spelling is ""
 * } Struct;
 *
 * union (implicit name) { <-- and spelling is ""
 * } Union;
 *
 * typedef enum {
 *  X <--- this one
 * } Enum; <--- not this one, covered by "other" pass
 * ---
 */
private Nullable!TypeKindAttr pass2(ref Cursor c, uint indent)
in {
    logNode(c, indent);
}
body {
    Nullable!TypeKindAttr rval;

    switch (c.kind) with (CXCursorKind) {
    case CXCursor_StructDecl:
        goto case;
    case CXCursor_UnionDecl:
        goto case;
    case CXCursor_EnumDecl:
        if (c.spelling.length == 0) {
            auto type = c.type;
            rval = makeTypeKindAttr(type);

            string spell = type.spelling;
            rval.kind.info = TypeKind.SimpleInfo(spell ~ " %s");
            rval.kind.usr = USRType(c.usr);
            rval.kind.loc = makeLocation(c);
        }
        break;
    default:
    }

    return rval;
}

/** Detect anonymous types that have an instansiation.
 *
 * Continuation of Pass 2.
 * Kept separate from Pass 3 to keep the passes logically "small".
 * Less cognitive load to understand what the passes do.
 *
 * Examle:
 * ---
 * struct {
 * } Struct;
 * ---
 */
private Nullable!TypeKindAttr pass3(ref Cursor c, uint indent)
in {
    logNode(c, indent);
}
body {
    Nullable!TypeKindAttr rval;

    switch (c.kind) with (CXCursorKind) {
    case CXCursor_FieldDecl:
        goto case;
    case CXCursor_VarDecl:
        import std.range : takeOne;

        foreach (child; c.children.takeOne) {
            rval = pass2(child, indent + 1);
        }
        break;
    default:
    }

    return rval;
}

/**
 */
private Nullable!TypeResult pass4(ref Cursor c, ref const Container container, in uint this_indent)
in {
    logNode(c, this_indent);
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    auto indent = this_indent + 1;
    Nullable!TypeResult rval;

    switch (c.kind) with (CXCursorKind) {
    case CXCursor_TypedefDecl:
        rval = retrieveTypeDef(c, container, indent);
        break;

    case CXCursor_FieldDecl:
    case CXCursor_VarDecl:
        rval = retrieveInstanceDecl(c, container, indent);
        break;

    case CXCursor_ParmDecl:
        rval = retrieveParam(c, container, indent);
        break;

    case CXCursor_TemplateTypeParameter:
        rval = retrieveTemplateParam(c, container, indent);
        break;

    case CXCursor_ClassTemplate:
        rval = retrieveClassTemplate(c, container, indent);
        break;

    case CXCursor_StructDecl:
    case CXCursor_UnionDecl:
    case CXCursor_ClassDecl:
    case CXCursor_EnumDecl:
        auto type = c.type;
        rval = passType(c, type, container, indent);
        break;

    case CXCursor_CXXMethod:
    case CXCursor_FunctionDecl:
        rval = retrieveFunc(c, container, indent);
        break;

    case CXCursor_Constructor:
        auto type = c.type;
        rval = typeToCtor(c, type, container, indent);
        break;

    case CXCursor_Destructor:
        auto type = c.type;
        rval = typeToDtor(c, type, indent);
        break;

    case CXCursor_IntegerLiteral:
        auto type = c.type;
        rval = passType(c, type, container, indent);
        break;

    case CXCursor_TypeRef:
    case CXCursor_CXXBaseSpecifier:
    case CXCursor_TemplateRef:
    case CXCursor_NamespaceRef:
    case CXCursor_MemberRef:
    case CXCursor_LabelRef:
        auto refc = c.referenced;
        rval = retrieveType(refc, container, indent);
        break;

    case CXCursor_NoDeclFound:
        // nothing to do
        break;

    case CXCursor_UnexposedDecl:
        rval = retrieveUnexposed(c, container, indent);
        if (rval.isNull) {
            logger.trace("Not implemented type retrieval for node ", c.usr);
        }
        break;

    default:
        // skip for now, may implement in the future
        logger.trace("Not implemented type retrieval for node ", c.usr);
    }

    return rval;
}

private bool canConvertNodeDeclToType(CXCursorKind kind) {
    switch (kind) with (CXCursorKind) {
    case CXCursor_TypedefDecl:
    case CXCursor_TemplateTypeParameter:
    case CXCursor_ClassTemplate:
    case CXCursor_StructDecl:
    case CXCursor_UnionDecl:
    case CXCursor_ClassDecl:
    case CXCursor_EnumDecl:
    case CXCursor_CXXMethod:
    case CXCursor_FunctionDecl:
    case CXCursor_Constructor:
    case CXCursor_Destructor:
    case CXCursor_IntegerLiteral:
        return true;
    default:
        return false;
    }
}

private bool isRefNode(CXCursorKind kind) {
    switch (kind) with (CXCursorKind) {
    case CXCursor_TypeRef:
    case CXCursor_CXXBaseSpecifier:
    case CXCursor_TemplateRef:
    case CXCursor_NamespaceRef:
    case CXCursor_MemberRef:
    case CXCursor_LabelRef:
        return true;
    default:
        return false;
    }
}

private Nullable!TypeResult retrieveUnexposed(ref Cursor c,
        ref const Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    assert(c.kind == CXCursorKind.CXCursor_UnexposedDecl);
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    import std.range : takeOne;

    auto indent = this_indent + 1;
    Nullable!TypeResult rval;

    foreach (child; c.children.takeOne) {
        switch (child.kind) with (CXCursorKind) {
        case CXCursor_CXXMethod:
        case CXCursor_FunctionDecl:
            rval = pass4(child, container, indent);
            if (!rval.isNull && rval.primary.kind.info.kind != TypeKind.Info.Kind.func) {
                // cases like typeof(x) y;
                // fix in the future
                rval.nullify;
            }
            break;

        default:
        }
    }

    return rval;
}

private Nullable!TypeResult passType(ref Cursor c, ref Type type,
        const ref Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    logType(type, this_indent);

    //TODO investigate if the below assumption is as it should be.
    // Not suposed to be handled here.
    // A typedef cursor shall have been detected and then handled by inspecting the child.
    // MAYBE move primitive type detection here.
    //assert(type.kind != CXTypeKind.CXType_Typedef);
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    import std.range : takeOne;

    auto indent = 1 + this_indent;
    Nullable!TypeResult rval;

    switch (type.kind) with (CXTypeKind) {
    case CXType_FunctionNoProto:
    case CXType_FunctionProto:
        rval = typeToFuncProto(c, type, container, indent);
        break;

    case CXType_BlockPointer:
        rval = typeToFuncPtr(c, type, container, indent);
        break;

        // handle ref and ptr the same way
    case CXType_LValueReference:
    case CXType_Pointer:
        //TODO fix architecture so this check isn't needed.
        //Should be possible to merge typeToFunPtr and typeToPointer
        if (type.isFunctionPointerType) {
            rval = typeToFuncPtr(c, type, container, indent);
        } else {
            rval = typeToPointer(c, type, container, indent);
        }
        break;

    case CXType_ConstantArray:
    case CXType_IncompleteArray:
        rval = typeToArray(c, type, container, indent);
        break;

    case CXType_Record:
        rval = typeToRecord(c, type, indent);
        break;

    case CXType_Typedef:
        // unable to represent a typedef as a typedef.
        // Falling back on representing as a Simple.
        // Note: the usr from the cursor is null.
        rval = typeToFallbackTyperef(c, type, indent);
        break;

    case CXType_Unexposed:
        debug {
            logger.trace("Unexposed, investigate if any other action should be taken");
        }
        if (!c.kind.among(CXCursorKind.CXCursor_FunctionDecl, CXCursorKind.CXCursor_CXXMethod)) {
            // see retrieveUnexposed for why
            rval = typeToSimple(c, type, indent);
        }
        break;

    default:
        rval = typeToSimple(c, type, indent);
    }

    return rval;
}

private TypeResult typeToFallbackTyperef(ref Cursor c, ref Type type, in uint this_indent)
in {
    logNode(c, this_indent);
    logType(type, this_indent);
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    string spell = type.spelling;

    // ugly hack to remove const
    if (type.isConst) {
        spell = spell[6 .. $];
    }

    auto rval = makeTypeKindAttr(type);

    auto info = TypeKind.SimpleInfo(spell ~ " %s");
    rval.kind.info = info;

    // a typedef like __va_list has a null usr
    if (c.usr.length == 0) {
        rval.kind.usr = makeFallbackUSR(c, this_indent + 1);
    } else {
        rval.kind.usr = c.usr;
    }

    rval.kind.loc = makeLocation(c);

    return TypeResult(rval, null);
}

private TypeResult typeToSimple(ref Cursor c, ref Type type, in uint this_indent)
in {
    logNode(c, this_indent);
    logType(type, this_indent);
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    auto rval = makeTypeKindAttr(type);

    auto maybe_primitive = translateCursorType(type.kind);

    if (maybe_primitive.isNull) {
        string spell = type.spelling;
        rval.kind.info = TypeKind.SimpleInfo(spell ~ " %s");

        rval.kind.usr = c.usr;
        if (rval.kind.usr.length == 0) {
            rval.kind.usr = makeFallbackUSR(c, this_indent + 1);
        }
    } else {
        string spell = maybe_primitive.get;
        rval.kind.info = TypeKind.SimpleInfo(spell ~ " %s");
        rval.attr.isPrimitive = Yes.isPrimitive;

        rval.kind.usr = makeUSR(maybe_primitive.get);
    }

    rval.kind.loc = makeLocation(c);

    return TypeResult(rval, null);
}

/// A function proto signature?
/// Workaround by checking if the return type is valid.
private bool isFuncProtoTypedef(ref Cursor c) {
    auto result_t = c.type.func.resultType;
    return result_t.isValid;
}

private TypeResult typeToTypedef(ref Cursor c, ref Type type, USRType typeRef,
        USRType canonicalRef, const ref Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    logType(type, this_indent);
    assert(type.kind == CXTypeKind.CXType_Typedef);
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    string spell = type.spelling;

    // ugly hack
    if (type.isConst && spell.length > 6 && spell[0 .. 6] == "const ") {
        spell = spell[6 .. $];
    }

    TypeKind.TypeRefInfo info;
    info.fmt = spell ~ " %s";
    info.typeRef = typeRef;
    info.canonicalRef = canonicalRef;

    TypeResult rval;
    rval.primary.attr = makeTypeAttr(type);
    rval.primary.kind.info = info;

    // a typedef like __va_list has a null usr
    if (c.usr.length == 0) {
        rval.primary.kind.usr = makeFallbackUSR(c, this_indent + 1);
    } else {
        rval.primary.kind.usr = c.usr;
    }

    rval.primary.kind.loc = makeLocation(c);

    return rval;
}

private TypeResult typeToRecord(ref Cursor c, ref Type type, in uint indent)
in {
    logNode(c, indent);
    logType(type, indent);
    assert(type.kind == CXTypeKind.CXType_Record);
}
out (result) {
    logTypeResult(result, indent);
}
body {
    string spell = type.spelling;

    // ugly hack needed when canonicalType has been used to get the type of a
    // cursor
    if (type.isConst && spell.length > 6 && spell[0 .. 6] == "const ") {
        spell = spell[6 .. $];
    }

    TypeKind.RecordInfo info;
    info.fmt = spell ~ " %s";

    auto rval = makeTypeKindAttr(type);
    rval.kind.info = info;

    if (c.isDeclaration) {
        auto decl_c = type.declaration;
        rval.kind.usr = decl_c.usr;
        rval.kind.loc = makeLocation(decl_c);
    } else {
        // fallback
        rval.kind.usr = c.usr;
        rval.kind.loc = makeLocation(c);
    }

    if (rval.kind.usr.length == 0) {
        rval.kind.usr = makeFallbackUSR(c, indent + 1);
        rval.kind.loc = makeLocation(c);
    }

    return TypeResult(rval, null);
}

/** Represent a pointer type hierarchy.
 *
 * TypeResult.primary.attr is the pointed at attribute.
 */
private TypeResult typeToPointer(ref Cursor c, ref Type type,
        const ref Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    logType(type, this_indent);
    assert(type.kind.among(CXTypeKind.CXType_Pointer, CXTypeKind.CXType_LValueReference));
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    import std.array;
    import std.range : dropBack;
    import cpptooling.utility.logger;

    auto indent = this_indent + 1;

    auto getPointee() {
        auto pointee = type.pointeeType;
        auto c_pointee = pointee.declaration;

        debug {
            logNode(c_pointee, indent);
            logType(pointee, indent);
        }

        TypeResult rval;

        // find the underlying type information
        if (pointee.kind == CXTypeKind.CXType_Unexposed) {
            pointee = type.canonicalType;
            while (pointee.kind.among(CXTypeKind.CXType_Pointer, CXTypeKind.CXType_LValueReference)) {
                pointee = pointee.pointeeType;
            }
            rval = passType(c, pointee, container, indent).get;
        } else if (c_pointee.kind == CXCursorKind.CXCursor_NoDeclFound) {
            // primitive types do not have a declaration cursor.
            // find the underlying primitive type.
            while (pointee.kind.among(CXTypeKind.CXType_Pointer, CXTypeKind.CXType_LValueReference)) {
                pointee = pointee.pointeeType;
            }
            rval = passType(c, pointee, container, indent).get;
        } else {
            rval = retrieveType(c_pointee, container, indent).get;
        }

        return rval;
    }

    auto pointee = getPointee();

    auto attrs = retrievePointeeAttr(type, indent);

    TypeKind.PointerInfo info;
    info.pointee = pointee.primary.kind.usr;
    info.attrs = attrs.ptrs;

    switch (pointee.primary.kind.info.kind) with (TypeKind.Info) {
    case Kind.array:
        info.fmt = pointee.primary.kind.toStringDecl(TypeAttr.init, "(%s%s)");
        break;
    default:
        info.fmt = pointee.primary.kind.toStringDecl(TypeAttr.init, "%s%s");
    }

    TypeResult rval;
    rval.primary.kind.info = info;
    // somehow pointee.primary.attr is wrong, somehow. Don't undestand why.
    // TODO remove this hack
    rval.primary.attr = attrs.base;

    if (pointee.primary.attr.isPrimitive) {
        // represent a usr to a primary more intelligently
        rval.primary.kind.usr = rval.primary.kind.toStringDecl(TypeAttr.init, "");
        // TODO shouldnt be needed, it is a primitive....
        rval.primary.kind.loc = makeLocation(c);
    } else {
        rval.primary.kind.usr = c.usr;
        rval.primary.kind.loc = makeLocation(c);
        if (rval.primary.kind.usr.length == 0) {
            rval.primary.kind.usr = makeFallbackUSR(c, indent);
        }
    }

    rval.extra = [pointee.primary] ~ pointee.extra;

    return rval;
}

/** Represent a function pointer type.
 *
 * Return: correct formatting and attributes for a function pointer.
 */
private TypeResult typeToFuncPtr(ref Cursor c, ref Type type,
        const ref Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    logType(type, this_indent);
    assert(type.kind.among(CXTypeKind.CXType_Pointer, CXTypeKind.CXType_LValueReference));
    assert(type.isFunctionPointerType);
}
out (result) {
    logTypeResult(result, this_indent);
    with (TypeKind.Info.Kind) {
        // allow catching the logical error in debug build
        assert(!result.primary.kind.info.kind.among(ctor, dtor, record, simple, array));
    }
}
body {
    auto indent = this_indent + 1;

    // find the underlying function prototype
    auto pointee_type = type;
    while (pointee_type.kind.among(CXTypeKind.CXType_Pointer, CXTypeKind.CXType_LValueReference)) {
        pointee_type = pointee_type.pointeeType;
    }
    debug {
        logType(pointee_type, indent);
    }

    auto attrs = retrievePointeeAttr(type, indent);
    auto pointee = typeToFuncProto(c, pointee_type, container, indent + 1);

    TypeKind.FuncPtrInfo info;
    info.pointee = pointee.primary.kind.usr;
    info.attrs = attrs.ptrs;
    info.fmt = pointee.primary.kind.toStringDecl(TypeAttr.init, "(%s%s)");

    TypeResult rval;
    rval.primary.kind.info = info;
    rval.primary.kind.usr = c.usr;
    rval.primary.kind.loc = makeLocation(c);
    // somehow pointee.primary.attr is wrong, somehow. Don't undestand why.
    // TODO remove this hack
    rval.primary.attr = attrs.base;

    rval.extra = [pointee.primary] ~ pointee.extra;

    return rval;
}

private TypeResult typeToFuncProto(ref Cursor c, ref Type type,
        const ref Container container, in uint indent)
in {
    logNode(c, indent);
    logType(type, indent);
    assert(type.isFunctionType || type.isTypedef || type.kind == CXTypeKind.CXType_FunctionNoProto);
}
out (result) {
    logTypeResult(result, indent);
}
body {
    import std.array;
    import std.algorithm : map;
    import std.string : strip;

    // append extra types directly to referenced TypeResult
    TypeKindAttr retrieveReturn(ref TypeResult tr) {
        TypeResult rval;

        auto result_type = type.func.resultType;
        auto result_decl = result_type.declaration;
        debug {
            logNode(result_decl, indent);
            logType(result_type, indent);
        }

        if (result_decl.kind == CXCursorKind.CXCursor_NoDeclFound) {
            rval = passType(result_decl, result_type, container, indent + 1).get;
        } else {
            rval = retrieveType(result_decl, container, indent + 1).get;
        }

        tr.extra ~= [rval.primary] ~ rval.extra;

        return rval.primary;
    }

    TypeResult rval;

    // writing to rval
    auto return_t = retrieveReturn(rval);

    auto params = extractParams2(c, type, container, indent);
    auto primary = makeTypeKindAttr(type);

    // a C++ member function must be queried for constness via a different API
    primary.attr.isConst = cast(Flag!"isConst") c.func.isConst;

    TypeKind.FuncInfo info;
    info.fmt = format("%s %s(%s)", return_t.toStringDecl.strip, "%s", params.joinParamId());
    info.return_ = return_t.kind.usr;
    info.returnAttr = return_t.attr;
    info.params = params.map!(a => FuncInfoParam(a.tka.kind.usr, a.tka.attr, a.id, a.isVariadic)).array();

    primary.kind.info = info;
    // in the case of __sighandler_t it is already used for the typedef
    primary.kind.usr = makeFallbackUSR(c, indent);
    primary.kind.loc = makeLocation(c);

    rval.primary = primary;
    rval.extra ~= params.map!(a => a.tka).array();

    return rval;
}

private TypeResult typeToCtor(ref Cursor c, ref Type type, const ref Container container,
        in uint indent)
in {
    logNode(c, indent);
    logType(type, indent);
    assert(c.kind == CXCursorKind.CXCursor_Constructor);
}
out (result) {
    logTypeResult(result, indent);
}
body {
    import std.algorithm : map;
    import std.array;

    TypeResult rval;
    auto params = extractParams2(c, type, container, indent);
    auto primary = makeTypeKindAttr(type);

    TypeKind.CtorInfo info;
    info.fmt = format("%s(%s)", "%s", params.joinParamId());
    info.params = params.map!(a => FuncInfoParam(a.tka.kind.usr, a.tka.attr, a.id, a.isVariadic)).array();
    info.id = c.spelling;

    primary.kind.info = info;
    primary.kind.usr = c.usr;
    primary.kind.loc = makeLocation(c);

    rval.primary = primary;
    rval.extra ~= params.map!(a => a.tka).array();

    return rval;
}

private TypeResult typeToDtor(ref Cursor c, ref Type type, in uint indent)
in {
    logNode(c, indent);
    logType(type, indent);
    assert(c.kind == CXCursorKind.CXCursor_Destructor);
}
out (result) {
    logTypeResult(result, indent);
}
body {
    TypeResult rval;
    auto primary = makeTypeKindAttr(type);

    TypeKind.DtorInfo info;
    info.fmt = format("~%s()", "%s");
    info.id = c.spelling[1 .. $]; // remove the leading ~

    primary.kind.info = info;
    primary.kind.usr = c.usr;
    primary.kind.loc = makeLocation(c);

    rval.primary = primary;
    return rval;
}

//TODO change the array to an appender, less GC pressure
private alias PointerTypeAttr = Tuple!(TypeAttr[], "ptrs", TypeAttr, "base");

/** Retrieve the attributes of the pointers until base condition.
 *
 * [$] is the value pointed at.
 *
 * Params:
 *  underlying = the value type, injected at correct position.
 *  type = a pointer or reference type.
 *  indent = indent for the log strings.
 * Return: An array of attributes for the pointers.
 */
private PointerTypeAttr retrievePointeeAttr(ref Type type, in uint this_indent)
in {
    logType(type, this_indent);
}
out (result) {
    import std.range : chain, only;

    foreach (r; chain(only(result.base), result.ptrs)) {
        logTypeAttr(r, this_indent);
    }
}
body {
    auto indent = this_indent + 1;
    PointerTypeAttr rval;

    if (type.kind.among(CXTypeKind.CXType_Pointer, CXTypeKind.CXType_LValueReference)) {
        // recursive
        auto pointee = type.pointeeType;
        rval = retrievePointeeAttr(pointee, indent);
        // current appended so right most ptr is at position 0.
        rval.ptrs ~= makeTypeAttr(type);
    } else {
        // Base condition.
        rval.base = makeTypeAttr(type);
    }

    return rval;
}

private TypeResult typeToArray(ref Cursor c, ref Type type,
        const ref Container container, in uint indent)
in {
    logNode(c, indent);
    logType(type, indent);
}
out (result) {
    logTypeResult(result, indent);
    assert(result.primary.kind.info.kind == TypeKind.Info.Kind.array);
}
body {
    import std.format : format;

    ArrayInfoIndex[] index_nr;

    // beware, used in primitive arrays
    auto index = type;

    while (index.kind.among(CXTypeKind.CXType_ConstantArray, CXTypeKind.CXType_IncompleteArray)) {
        auto arr = index.array;

        switch (index.kind) with (CXTypeKind) {
        case CXType_ConstantArray:
            index_nr ~= ArrayInfoIndex(arr.size);
            break;
        case CXType_IncompleteArray:
            index_nr ~= ArrayInfoIndex();
            break;
        default:
            break;
        }

        index = arr.elementType;
    }

    TypeResult element;
    USRType primary_usr;
    Location primary_loc;

    auto index_decl = index.declaration;

    if (index_decl.kind == CXCursorKind.CXCursor_NoDeclFound) {
        // on purpuse not checking if it is null before using
        element = passType(c, index, container, indent + 1).get;

        primary_usr = element.primary.kind.toStringDecl(TypeAttr.init) ~ index_nr.toRepr;
        primary_loc = element.primary.kind.loc;
    } else {
        // on purpuse not checking if it is null before using
        element = retrieveType(index_decl, container, indent + 1).get;

        primary_usr = element.primary.kind.usr;
        primary_loc = element.primary.kind.loc;
    }

    if (primary_loc.file.length == 0) {
        // TODO this is stupid ... fix it. Shouldn't be needed but happens
        // when it is an array of primary types.
        // Probably the correct fix is the contract in retrieveType to check
        // that if it is an array at primary types it do NOT check for length.
        primary_loc = makeLocation(c);
    }

    TypeKind.ArrayInfo info;
    info.element = element.primary.kind.usr;
    info.elementAttr = element.primary.attr;
    info.indexes = index_nr;
    // TODO probably need to adjust elementType and format to allow ptr to
    // array etc. int * const x[10];
    info.fmt = element.primary.kind.toStringDecl(TypeAttr.init, "%s%s");

    TypeResult rval;
    rval.primary.kind.usr = primary_usr;
    rval.primary.kind.loc = primary_loc;
    rval.primary.kind.info = info;
    rval.primary.attr = makeTypeAttr(type);
    rval.extra ~= [element.primary] ~ element.extra;

    return rval;
}

/** Retrieve the type of an instance declaration.
 *
 * Questions to consider:
 *  - Is the type a typeref?
 *  - Is it a function pointer?
 *  - Is the type a primitive type?
 */
private Nullable!TypeResult retrieveInstanceDecl(ref Cursor c,
        const ref Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    with (CXCursorKind) {
        assert(c.kind.among(CXCursor_VarDecl, CXCursor_FieldDecl,
                CXCursor_TemplateTypeParameter, CXCursor_ParmDecl));
    }
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    import std.range : takeOne;

    const auto indent = this_indent + 1;
    auto c_type = c.type;

    auto handlePointer(ref Nullable!TypeResult rval) {
        switch (c_type.kind) with (CXTypeKind) {
            // Is it a pointer?
            // Then preserve the pointer structure but dig deeper for the
            // pointed at type.
        case CXType_LValueReference:
        case CXType_Pointer:
            // must retrieve attributes from the pointed at type thus need a
            // more convulated deduction
            rval = passType(c, c_type, container, indent);
            foreach (tref; c.children.takeOne) {
                auto child = retrieveType(tref, container, indent);
                if (!child.isNull) {
                    rval.extra ~= [child.primary] ~ child.extra;
                }
            }
            break;

        default:
        }
    }

    auto handleTypedef(ref Nullable!TypeResult rval) {
        foreach (child; c.children.takeOne) {
            switch (child.kind) with (CXCursorKind) {
            case CXCursor_TypeRef:
                rval = pass4(child, container, indent);
                break;
            default:
            }
        }

        if (!rval.isNull) {
            rval.primary.attr = makeTypeAttr(c_type);
        }
    }

    auto handleTypeWithDecl(ref Nullable!TypeResult rval) {
        auto c_type_decl = c_type.declaration;
        if (c_type_decl.isValid) {
            auto type = c_type_decl.type;
            rval = passType(c_type_decl, type, container, indent);
        }
    }

    auto fallback(ref Nullable!TypeResult rval) {
        rval = passType(c, c_type, container, indent);
    }

    auto ensureUSR(ref Nullable!TypeResult rval) {
        if (!rval.isNull && rval.primary.kind.usr.length == 0) {
            rval.primary.kind.usr = makeFallbackUSR(c, this_indent);
        }
    }

    Nullable!TypeResult rval;
    foreach (f; [&handlePointer, &handleTypedef, &handleTypeWithDecl, &fallback]) {
        f(rval);
        if (!rval.isNull) {
            break;
        }
    }

    ensureUSR(rval);

    return rval;
}

private Nullable!TypeResult retrieveTypeDef(ref Cursor c,
        const ref Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    assert(c.kind == CXCursorKind.CXCursor_TypedefDecl);
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    import std.range : takeOne;

    const uint indent = this_indent + 1;

    auto handleTyperef(ref Nullable!TypeResult rval) {
        if (isFuncProtoTypedef(c)) {
            // this case is handled by handleTyperefFuncProto
            return;
        }

        // any TypeRef children and thus need to traverse the tree?
        foreach (child; c.children.takeOneTypeRef) {
            if (!child.kind.among(CXCursorKind.CXCursor_TypeRef)) {
                break;
            }

            auto tref = pass4(child, container, indent);

            auto type = c.type;
            if (tref.primary.kind.info.kind == TypeKind.Info.Kind.typeRef) {
                rval = typeToTypedef(c, type, tref.primary.kind.usr,
                        tref.primary.kind.info.canonicalRef, container, indent);
            } else {
                rval = typeToTypedef(c, type, tref.primary.kind.usr,
                        tref.primary.kind.usr, container, indent);
            }
            rval.extra = [tref.primary] ~ tref.extra;
        }
    }

    auto handleDecl(ref Nullable!TypeResult rval) {
        auto child_ = c.children.takeOne;
        if (child_.length == 0 || !child_[0].kind.canConvertNodeDeclToType) {
            return;
        }

        auto c_child = child_[0];
        auto tref = retrieveType(c_child, container, indent);

        auto type = c.type;
        if (tref.primary.kind.info.kind == TypeKind.Info.Kind.typeRef) {
            rval = typeToTypedef(c, type, tref.primary.kind.usr,
                    tref.primary.kind.info.canonicalRef, container, indent);
        } else {
            rval = typeToTypedef(c, type, tref.primary.kind.usr,
                    tref.primary.kind.usr, container, indent);
        }
        rval.extra = [tref.primary] ~ tref.extra;
    }

    auto handleTypeRefToTypeDeclFuncProto(ref Nullable!TypeResult rval) {
        static bool isFuncProto(ref Cursor c) {
            //TODO consider merging or improving isFuncProtoTypedef with this
            if (!isFuncProtoTypedef(c)) {
                return false;
            }

            if (c.children.length == 0) {
                return false;
            }

            auto child_t = c.children[0].type;
            if (!child_t.isFunctionType || child_t.isPointer) {
                return false;
            }

            return true;
        }

        if (!isFuncProto(c)) {
            return;
        }

        auto child = c.children[0];
        auto ref_child = child.referenced;
        if (ref_child.kind != CXCursorKind.CXCursor_TypedefDecl) {
            return;
        }

        auto tref = retrieveType(ref_child, container, indent);

        // TODO consolidate code. Copied from handleDecl
        auto type = c.type;
        if (tref.primary.kind.info.kind == TypeKind.Info.Kind.typeRef) {
            rval = typeToTypedef(c, type, tref.primary.kind.usr,
                    tref.primary.kind.info.canonicalRef, container, indent);
        } else {
            rval = typeToTypedef(c, type, tref.primary.kind.usr,
                    tref.primary.kind.usr, container, indent);
        }
        rval.extra = [tref.primary] ~ tref.extra;
    }

    auto handleFuncProto(ref Nullable!TypeResult rval) {
        if (!isFuncProtoTypedef(c)) {
            return;
        }
        auto type = c.type;
        auto func = typeToFuncProto(c, type, container, indent);
        // a USR for the function do not exist because the only sensible would
        // be the typedef... but it is used by the typedef _for this function_
        func.primary.kind.usr = makeFallbackUSR(c, indent);

        rval = typeToTypedef(c, type, func.primary.kind.usr,
                func.primary.kind.usr, container, indent);
        rval.extra = [func.primary] ~ func.extra;
    }

    auto underlying(ref Nullable!TypeResult rval) {
        auto underlying = c.typedefUnderlyingType;
        auto tref = passType(c, underlying, container, indent);

        auto type = c.type;
        rval = typeToTypedef(c, type, tref.primary.kind.usr,
                tref.primary.kind.usr, container, indent);
        rval.extra = [tref.primary] ~ tref.extra;
    }

    // TODO investigate if this can be removed, aka always covered by underlying.
    auto fallback(ref Nullable!TypeResult rval) {
        // fallback, unable to represent as a typedef ref'ing a type
        auto type = c.type;
        rval = passType(c, type, container, indent);
    }

    typeof(return) rval;
    foreach (idx, f; [&handleTypeRefToTypeDeclFuncProto, &handleTyperef,
            &handleFuncProto, &handleDecl, &underlying, &fallback]) {
        debug {
            import std.conv : to;
            import cpptooling.utility.logger : trace;

            trace(idx.to!string(), this_indent);
        }
        f(rval);
        if (!rval.isNull) {
            break;
        }
    }

    return rval;
}

/** Retrieve the type representation of a FuncDecl or CXXMethod.
 *
 * case a. A typedef of a function signature.
 * When it is instansiated it results in a FunctionDecl with a TypeRef.
 * Note in the example that the child node is a TypeRef.
 *
 * Example:
 * FunctionDecl "tiger" [Keyword "extern", Identifier "func_type", Identifier "tiger"] c:@F@tiger
 *   TypeRef "func_type" [Identifier "func_type"]
 *
 * case b. A function with a return type which is a TypeRef to a TypedefDecl.
 * The first child node is a TypeRef.
 * This case should NOT be confused with case a.
 *
 * case c. A function declared "the normal way", void foo();
 *
 * solve case a.
 * Try resolving the type of the first child node.
 * If the canonical type is a function, good. Case a.
 * Otherwise case b and c.
 */
private Nullable!TypeResult retrieveFunc(ref Cursor c,
        const ref Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    assert(c.kind.among(CXCursorKind.CXCursor_FunctionDecl, CXCursorKind.CXCursor_CXXMethod));
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    import std.range : chain, only, takeOne;

    const uint indent = this_indent + 1;
    typeof(return) rval;

    foreach (child; c.children.takeOneTypeRef) {
        if (child.kind != CXCursorKind.CXCursor_TypeRef) {
            break;
        }
        auto retrieved_ref = retrieveType(child, container, indent);

        if (!retrieved_ref.isNull && retrieved_ref.primary.kind.info.kind == TypeKind
                .Info.Kind.func) {
            // fast path
            rval = retrieved_ref;
        } else if (!retrieved_ref.isNull
                && retrieved_ref.primary.kind.info.kind == TypeKind.Info.Kind.typeRef) {
            // check the canonical type
            foreach (k; chain(only(retrieved_ref.primary), retrieved_ref.extra)) {
                if (k.kind.usr == retrieved_ref.primary.kind.info.canonicalRef
                        && k.kind.info.kind == TypeKind.Info.Kind.func) {
                    rval = retrieved_ref;
                }
            }
        }
    }

    if (rval.isNull) {
        auto type = c.type;
        rval = passType(c, type, container, indent);
    }

    return rval;
}

/** Only able to uniquely represent the class template.
 *
 * TODO Unable to instansiate.
 */
private TypeResult retrieveClassTemplate(ref Cursor c, const ref Container container, in uint indent)
in {
    logNode(c, indent);
    assert(c.kind == CXCursorKind.CXCursor_ClassTemplate);
}
body {
    TypeResult rval;

    auto type = c.type;
    rval.primary = makeTypeKindAttr(type);
    rval.primary.kind = makeSimple2(c.spelling);
    rval.primary.kind.usr = c.usr;
    rval.primary.kind.loc = makeLocation(c);

    return rval;
}

/** Extract the type of a parameter cursor.
 *
 * TODO if nothing changes remove either retrieveParam or retrieveInstanceDecl,
 * code duplication.
 */
private Nullable!TypeResult retrieveParam(ref Cursor c,
        const ref Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    // TODO add assert for the types allowed
}
out (result) {
    logTypeResult(result, this_indent);
}
body {
    return retrieveInstanceDecl(c, container, this_indent + 1);
}

/** Only able to uniquely represent the class template.
 *
 * TODO Unable to instansiate.
 */
private Nullable!TypeResult retrieveTemplateParam(ref Cursor c,
        const ref Container container, in uint this_indent)
in {
    logNode(c, this_indent);
    // TODO add assert for the types allowed
}
body {
    import std.range : takeOne;

    uint indent = this_indent + 1;
    Nullable!TypeResult rval;

    if (c.spelling.length == 0) {
        //TODO could probably be a random name, the location or something.
        // Example when it occurs:
        // template <typename/*here*/> class allocator;
        return rval;
    }

    auto type = c.type;
    rval = retrieveParam(c, container, indent);

    return rval;
}

//TODO handle anonymous namespace
//TODO maybe merge with backtrackNode in clang/utility.d?
private string[] backtrackScope(ref Cursor c) {
    import cpptooling.analyzer.clang.utility;

    static struct GatherScope {
        import std.array : Appender;

        Appender!(string[]) app;

        void apply(ref Cursor c, int depth)
        in {
            logNode(c, depth);
        }
        body {
            if (c.kind.among(CXCursorKind.CXCursor_UnionDecl, CXCursorKind.CXCursor_StructDecl,
                    CXCursorKind.CXCursor_ClassDecl, CXCursorKind.CXCursor_Namespace)) {
                app.put(c.spelling);
            }
        }
    }

    GatherScope gs;
    backtrackNode(c, gs);

    return gs.app.data;
}

private alias PTuple2 = Tuple!(TypeKindAttr, "tka", string, "id",
        Flag!"isVariadic", "isVariadic");

PTuple2[] extractParams2(ref Cursor c, ref Type type, const ref Container container,
        in uint this_indent)
in {
    logNode(c, this_indent);
    logType(type, this_indent);
    assert(type.isFunctionType || type.isTypedef || type.kind == CXTypeKind.CXType_FunctionNoProto);
}
out (result) {
    import cpptooling.utility.logger : trace;

    foreach (p; result) {
        trace(p.tka.toStringDecl(p.id), this_indent);
    }
}
body {
    auto indent = this_indent + 1;

    void appendParams(ref Cursor c, ref PTuple2[] params) {
        import std.range : enumerate;

        foreach (idx, p; c.children.enumerate) {
            if (p.kind != CXCursorKind.CXCursor_ParmDecl) {
                logNode(p, this_indent);
                continue;
            }

            auto tka = retrieveType(p, container, indent);
            auto id = p.spelling;
            params ~= PTuple2(tka.primary, id, No.isVariadic);
        }

        if (type.func.isVariadic) {
            import clang.SourceLocation;

            TypeKindAttr tka;

            auto info = TypeKind.SimpleInfo("...%s");
            tka.kind.info = info;
            tka.kind.usr = "..." ~ c.location.toString();
            tka.kind.loc = makeLocation(c);

            // TODO remove this ugly hack
            // space as id to indicate it is empty
            params ~= PTuple2(tka, " ", Yes.isVariadic);
        }
    }

    PTuple2[] params;

    if (c.kind == CXCursorKind.CXCursor_TypeRef) {
        auto cref = c.referenced;
        appendParams(cref, params);
    } else {
        appendParams(c, params);
    }

    return params;
}

/// Join an array slice of PTuples to a parameter string of "type" "id"
private string joinParamId(PTuple2[] r) {
    import std.algorithm : joiner, map, filter;
    import std.conv : text;
    import std.range : enumerate;

    static string getTypeId(ref PTuple2 p, ulong uid) {
        if (p.id.length == 0) {
            //TODO decide if to autogenerate for unnamed parameters here or later
            //return p.tka.toStringDecl("x" ~ text(uid));
            return p.tka.toStringDecl("");
        } else {
            return p.tka.toStringDecl(p.id);
        }
    }

    // using cache to avoid calling getName twice.
    return r.enumerate.map!(a => getTypeId(a.value, a.index)).filter!(a => a.length > 0)
        .joiner(", ").text();

}

private Nullable!string translateCursorType(CXTypeKind kind)
in {
    import std.conv : to;

    logger.trace(to!string(kind));
}
out (result) {
    logger.trace(!result.isNull, result);
}
body {
    Nullable!string r;

    with (CXTypeKind) switch (kind) {
    case CXType_Invalid:
        break;
    case CXType_Unexposed:
        break;
    case CXType_Void:
        r = "void";
        break;
    case CXType_Bool:
        r = "bool";
        break;
    case CXType_Char_U:
        r = "unsigned char";
        break;
    case CXType_UChar:
        r = "unsigned char";
        break;
    case CXType_Char16:
        break;
    case CXType_Char32:
        break;
    case CXType_UShort:
        r = "unsigned short";
        break;
    case CXType_UInt:
        r = "unsigned int";
        break;
    case CXType_ULong:
        r = "unsigned long";
        break;
    case CXType_ULongLong:
        r = "unsigned long long";
        break;
    case CXType_UInt128:
        break;
    case CXType_Char_S:
        r = "char";
        break;
    case CXType_SChar:
        r = "char";
        break;
    case CXType_WChar:
        r = "wchar_t";
        break;
    case CXType_Short:
        r = "short";
        break;
    case CXType_Int:
        r = "int";
        break;
    case CXType_Long:
        r = "long";
        break;
    case CXType_LongLong:
        r = "long long";
        break;
    case CXType_Int128:
        break;
    case CXType_Float:
        r = "float";
        break;
    case CXType_Double:
        r = "double";
        break;
    case CXType_LongDouble:
        r = "long double";
        break;
    case CXType_NullPtr:
        r = "null";
        break;
    case CXType_Overload:
        break;
    case CXType_Dependent:
        break;

    case CXType_ObjCId:
    case CXType_ObjCClass:
    case CXType_ObjCSel:
        break;

    case CXType_Complex:
    case CXType_Pointer:
    case CXType_BlockPointer:
    case CXType_LValueReference:
    case CXType_RValueReference:
    case CXType_Record:
    case CXType_Enum:
    case CXType_Typedef:
    case CXType_FunctionNoProto:
    case CXType_FunctionProto:
    case CXType_Vector:
    case CXType_IncompleteArray:
    case CXType_VariableArray:
    case CXType_DependentSizedArray:
    case CXType_MemberPointer:
        break;

    default:
        logger.trace("Unhandled type kind ", to!string(kind));
    }

    return r;
}
