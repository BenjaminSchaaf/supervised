module supervised.logging;

import std.stdio;
import std.experimental.logger;

private __gshared Logger _logger;

shared static this() {
    debug(supervised_debug) {
        auto loglevel = LogLevel.trace;
    } else debug {
        auto loglevel = LogLevel.info;
    } else {
        auto loglevel = LogLevel.info;
    }

    _logger = new FileLogger(stdout, loglevel);
}

@property Logger logger() @trusted {
    return _logger;
}

@property void logger(Logger logger) @trusted {
    synchronized {
        _logger = logger;
    }
}
