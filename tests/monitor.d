module tests.api.v1;

import core.time;
import core.thread;

import std.path;
import std.stdio;
import std.range;
import std.format;
import std.typecons;
import std.algorithm;
import std.experimental.logger;

import fluent.asserts;
import trial.discovery.spec;

import supervised;

private alias suite = Spec!({
describe("ProcessMonitor", {
    before({
        import supervised.logging;

        writeln("Writing test logs to `tests.log`");
        supervised.logging.logger = new FileLogger("tests.log", LogLevel.trace);
    });

    it("handles multiple consecutive single short run processes", {
        auto monitor = new shared ProcessMonitor;

        foreach (i; 0..100) {
            monitor.running.should.equal(false).because("(At iteration %s)".format(i));

            auto count = 0;
            auto others = 0;
            monitor.stdoutCallback = (string message) @safe {
                if (message == "foo bar") count++;
                else others++;
            };

            monitor.start(["echo", "foo bar"]);
            monitor.running.should.equal(true).because("(At iteration %s)".format(i));
            monitor.wait().should.equal(0).because("(At iteration %s)".format(i));

            count.should.equal(1).because("(At iteration %s)".format(i));
            others.should.equal(0).because("(At iteration %s)".format(i));
            monitor.running.should.equal(false).because("(At iteration %s)".format(i));
        }
    });

    it("handles passing messages to stdin, in order", {
        auto monitor = new shared ProcessMonitor;

        string[] outputs;
        monitor.stdoutCallback = (string message) @safe {
            outputs ~= message;
        };

        auto inputs = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
                        .repeat(1000).join.array;

        monitor.start(["cat"]);
        monitor.running.should.equal(true);

        foreach (input; inputs) {
            monitor.send(input);
        }

        monitor.closeStdin();
        monitor.wait();

        outputs.should.equal(inputs);
    });

    it("handles capturing stderr", {
        auto monitor = new shared ProcessMonitor;

        string[] outputs;
        monitor.stderrCallback = (string message) @safe {
            outputs ~= message;
        };

        auto inputs = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
                        .repeat(1000).join.array;

        monitor.start(["python3", "tests/support/cat_stderr.py"]);
        monitor.running.should.equal(true);

        foreach (input; inputs) {
            monitor.send(input);
        }

        monitor.closeStdin();
        monitor.wait();

        outputs.should.equal(inputs);
    });

    it("can kill a process that randomly dies", {
        auto monitor = new shared ProcessMonitor;

        foreach (i; 0..20) {
            monitor.running.should.equal(false);

            monitor.start(["python3", "tests/support/random_exit.py"]);
            monitor.running.should.equal(true);

            Thread.sleep(500.msecs);
            try {
                monitor.kill();
            } catch (Exception e) {}
            monitor.wait();

            monitor.running.should.equal(false);
        }
    });

    it("can kill a process that ignores SIGTERM", {
        auto monitor = new shared ProcessMonitor;
        monitor.killTimeout = 2.seconds;

        string[] outputs;
        monitor.stdoutCallback = (string message) @safe {
            outputs ~= message;
        };
        monitor.stderrCallback = (string message) @safe {
            outputs ~= message;
        };

        monitor.start(["python3", "tests/support/ignore_sigterm.py"]);
        monitor.running.should.equal(true);

        // Give python some time to install the signal handler
        Thread.sleep(200.msecs);

        monitor.kill();
        monitor.send("foo");
        monitor.running.should.equal(true);

        monitor.wait();

        monitor.running.should.equal(false);

        outputs.should.equal(["foo"]);
    });

    it("handles a process that doesn't exit immediately", {
        auto monitor = new shared ProcessMonitor;
        monitor.killTimeout = 3.seconds;

        string[] outputs;
        monitor.stdoutCallback = (string message) @safe {
            outputs ~= message;
        };

        monitor.start(["python3", "tests/support/late_exit.py"]);
        monitor.running.should.equal(true);

        // Give python some time to install the signal handler
        Thread.sleep(200.msecs);

        monitor.send("foo");
        Thread.sleep(100.msecs);
        monitor.kill();
        monitor.running.should.equal(true);

        monitor.wait();

        monitor.running.should.equal(false);

        outputs.should.equal(["foo", "INTERRUPTED"]);
    });

    // TODO: Support this feature
    /*it("handles processes that write directly to tty", {
        auto monitor = new shared ProcessMonitor;

        string[] outputs;
        monitor.stdoutCallback = (string message) @safe {
            outputs ~= message;
        };

        monitor.start(["python3", "tests/support/cat_tty.py"]);
        monitor.running.should.equal(true);

        monitor.send("foo");

        Thread.sleep(100.msecs);
        monitor.kill();
        monitor.wait();

        outputs.should.equal(["foo"]);
    });*/

    describe("this()", {
        it("Starts a process immediately", {
            auto monitor = new shared ProcessMonitor(["echo", "foo bar"]);
            scope(exit) monitor.wait();

            monitor.running.should.equal(true);
        });
    });

    describe("start()", {
        it("Starts process with proper environment", {
            auto monitor = new shared ProcessMonitor;

            string[] outputs;
            monitor.stdoutCallback = (string message) @safe {
                outputs ~= message;
            };

            monitor.start(
                ["python3", "print_env.py"],
                [tuple("foo", "bar")],
                "tests/support"
            );
            monitor.wait();

            outputs.length.should.equal(3);
            outputs[0].should.equal("['print_env.py']");
            outputs[1].canFind("'foo': 'bar'").should.equal(true);
            outputs[2].should.equal(absolutePath("tests/support"));
        });

        it("Fails running a non-existent process", {
            auto monitor = new shared ProcessMonitor;

            ({
                monitor.start(["tests/supports/this-file-does-not-exist"]);
            }).should.throwException!ProcessException;
        });

        it("Fails if a process is already running", {
            auto monitor = new shared ProcessMonitor(["python3", "tests/support/print_on_exit.py"]);

            scope(exit) {
                monitor.kill();
                monitor.wait();
            }

            ({
                monitor.start(["echo", "foo"]);
            }).should.throwException!InvalidStateException;

        });
    });

    describe("kill()", {
        it("Fails if process is not running", {
            auto monitor = new shared ProcessMonitor;

            ({
                monitor.kill(4);
            }).should.throwException!InvalidStateException;
        });
    });

    describe("wait()", {
        it("Returns the exit code", {
            auto monitor = new shared ProcessMonitor(["python3", "tests/support/exit_code.py", "2"]);

            monitor.wait().should.equal(2);
            monitor.wait().should.equal(2);

            monitor.start(["python3", "tests/support/exit_code.py", "0"]);

            monitor.wait().should.equal(0);
            monitor.wait().should.equal(0);
        });

        it("Handles being called without the process having started", {
            auto monitor = new shared ProcessMonitor;

            monitor.wait().should.equal(0);
        });
    });

    describe("closeStdin()", {
        it("Fails if process is not running", {
            auto monitor = new shared ProcessMonitor;

            ({
                monitor.closeStdin();
            }).should.throwException!InvalidStateException;
        });
    });

    describe("callbacks", {
        it("Calls all callbacks", {
            auto monitor = new shared ProcessMonitor;

            string[] stdout;
            monitor.stdoutCallback = (string message) @safe {
                stdout ~= message;
            };

            string[] stderr;
            monitor.stderrCallback = (string message) @safe {
                stderr ~= message;
            };

            auto terminations = 0;
            monitor.terminateCallback = () @safe {
                terminations += 1;
            };

            monitor.start(["bash", "-c", "echo foo >&2; echo bar"]);
            monitor.wait().should.equal(0);

            stdout.should.equal(["bar"]);
            stderr.should.equal(["foo"]);
            terminations.should.equal(1);
        });
    });
});
});
