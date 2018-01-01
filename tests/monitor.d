module tests.api.v1;

import core.time;
import core.thread;

import std.stdio;
import std.range;
import std.format;
import std.algorithm;

import fluent.asserts;
import trial.discovery.spec;

import supervised.monitor;

private alias suite = Spec!({
    describe("ProcessMonitor", {
        it("handles multiple consecutive single short run processes", {
            auto monitor = new shared ProcessMonitor;

            foreach (i; 0..100) {
                monitor.running.should.equal(false);

                auto count = 0;
                auto others = 0;
                monitor.stdoutCallback = (string message) @safe {
                    if (message == "foo bar") count++;
                    else others++;
                };

                monitor.start(["echo", "foo bar"]);
                monitor.running.should.equal(true);
                monitor.wait();

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

            monitor.send(null);
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

            monitor.send(null);
            monitor.wait();

            outputs.should.equal(inputs);
        });

        it("can kill a process that randomly dies", {
            auto monitor = new shared ProcessMonitor;

            foreach (i; 0..100) {
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
    });
});
