module supervised.errors;

public import std.process : ProcessException;

private mixin template ExceptionCtorMixin() {
    this(string msg, string file = __FILE__, ulong line = cast(ulong)__LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe {
        super(msg, file, line, nextInChain);
    }
}

class SupervisedException : Exception {
    mixin ExceptionCtorMixin;
}

class InvalidStateException : SupervisedException {
    mixin ExceptionCtorMixin;
}
