module supervised.monitor;

import core.time;
import core.thread;
import core.sync.barrier;

import core.sys.posix.signal : SIGKILL, SIGTERM;

import std.stdio;
import std.process;
import std.typecons;
import std.algorithm;
import std.exception;

import vibe.core.core;
import vibe.core.sync;
import vibe.core.task;
import vibe.core.concurrency;

import supervised.logging;

shared class ProcessMonitor {
    @safe:

    alias FileCallback = void delegate(string) @safe;
    alias EventCallback = void delegate() @safe;

    private {
        // Monitor mutex
        TaskMutex _mutex;

        Task _watcher;
        bool _running = false;
        TaskMutex _runningMutex; // Mutex that is locked while the process is running. Used for wait()
        int _exitStatus;

        Duration _killTimeout = 20.seconds;

        FileCallback _stdoutCallback;
        FileCallback _stderrCallback;
        EventCallback _terminateCallback;
    }

    this() shared @trusted {
        this._mutex = cast(shared)new TaskMutex();
    }

    this(immutable(string[]) args, immutable(Tuple!(string, string)[]) env = null, string workingDir = null) shared {
        this();
        start(args, env, workingDir);
    }

    ~this() shared {
        if (running) kill();
    }

    private struct Sync {
        ProcessMonitor instance;

        @property bool running() {
            return instance._running;
        }

        package @property void running(bool value) {
            instance._running = value;
        }

        package @property Task watcher() {
            return instance._watcher;
        }

        package @property void watcher(Task task) {
            instance._watcher = task;
        }

        package @property TaskMutex runningMutex() @trusted {
            return cast(TaskMutex)instance._runningMutex;
        }

        package @property void runningMutex(TaskMutex mutex) @trusted {
            instance._runningMutex = cast(shared)mutex;
        }

        @property int exitStatus() {
            return instance._exitStatus;
        }

        package @property void exitStatus(int status) {
            instance._exitStatus = status;
        }

        @property Duration killTimeout() {
            return instance._killTimeout;
        }

        @property void killTimeout(Duration timeout) {
            instance._killTimeout = timeout;
        }

        @property void stdoutCallback(FileCallback fn) {
            instance._stdoutCallback = fn;
        }

        @property void stderrCallback(FileCallback fn) {
            instance._stderrCallback = fn;
        }

        @property void terminateCallback(EventCallback fn) {
            instance._terminateCallback = fn;
        }

        void send(string message) @trusted {
            enforce(running);

            watcher.sendCompat(message);
        }
    }

    auto withLock(T)(T delegate(Sync) @safe fn) shared @trusted {
        synchronized (_mutex) {
            return fn(Sync(cast(ProcessMonitor)this));
        }
    }

    @property bool running() shared {
        return withLock((self) @safe => self.running);
    }

    @property Duration killTimeout() shared {
        return withLock((self) @safe => self.killTimeout);
    }

    @property void killTimeout(Duration duration) shared {
        withLock((self) @safe => self.killTimeout = duration);
    }

    @property void stdoutCallback(FileCallback fn) {
        withLock((self) @safe => self.stdoutCallback = fn);
    }

    @property void stderrCallback(FileCallback fn) {
        withLock((self) @safe => self.stderrCallback = fn);
    }

    @property void terminateCallback(EventCallback fn) {
        withLock((self) @safe => self.terminateCallback = fn);
    }

    void callStdoutCallback(string message) shared @trusted {
        auto callback = _stdoutCallback;

        if (callback !is null) {
            try {
                callback(message);
            } catch (Throwable e) {
                logger.errorf("Stdout Callback Task(%s) Error: %s\nDue to line: %s", Task.getThis(), e, message);
            }
        }
    }

    void callStderrCallback(string message) shared @trusted {
        auto callback = _stderrCallback;

        if (callback !is null) {
            try {
                callback(message);
            } catch (Throwable e) {
                logger.errorf("Stderr Callback Task(%s) Error: %s\nDue to line: %s", Task.getThis(), e, message);
            }
        }
    }

    void callTerminateCallback() shared @trusted {
        auto callback = _terminateCallback;

        if (callback !is null) {
            try {
                callback();
            } catch (Throwable e) {
                logger.errorf("Terminate Callback Task(%s) Error: %s", Task.getThis(), e);
            }
        }
    }

    void send(string message) shared {
        withLock((self) @safe => self.send(message));
    }

    void start(immutable(string[]) args, immutable(Tuple!(string, string)[]) env = null, string workingDir = null) shared {
        withLock((self) @trusted {
            enforce(!self.running);

            static void fn(shared ProcessMonitor monitor, Tid sender, immutable(string[]) args, immutable(Tuple!(string, string)[]) _env, string workingDir) {
                // Create the env associative array
                string[string] env;
                foreach (item; _env) {
                    env[item[0]] = item[1];
                }

                try {
                    monitor.runWatcher(sender, args, env, workingDir);
                } catch (Throwable e) {
                    logger.criticalf("Critical Error in watcher: %s", e);
                }
            }
            runWorkerTask(&fn, this, thisTid, args.idup, env.idup, workingDir);
            self.watcher = receiveOnly!Task;

            logger.tracef("Process started, monitor: %s", self.watcher);

            self.running = true;
        });
    }

    void kill(int signal = SIGTERM) shared {
        withLock((self) @trusted {
            enforce(self.running);

            logger.tracef("Killing process with signal %s, monitor: %s", signal, self.watcher);
            self.watcher.prioritySendCompat(signal);
        });
    }

    int wait() shared {
        auto pair = withLock((self) @safe => tuple(self.runningMutex, self.exitStatus));
        auto runningMutex = pair[0];

        if (runningMutex is null) {
           return pair[1];
        }

        // Wait on the running mutex
        logger.trace("Waiting on process to finish");
        synchronized(runningMutex) {}

        return withLock((self) @safe => self.exitStatus);
    }

    private void runWatcher(Tid starter, immutable string[] args, string[string] env, string workingDir) shared @trusted {
        auto thisTask = Task.getThis();
        logger.tracef("Watcher(%s): started with %s", thisTask, args);

        // Start the process
        auto config = Config.newEnv;
        auto processPipes = pipeProcess(args, Redirect.all, env, config, workingDir);
        auto process = processPipes.pid;
        auto stdin = processPipes.stdin;
        auto stdout = processPipes.stdout;
        auto stderr = processPipes.stderr;
        logger.tracef("Watcher(%s): [stdin: , stdout: %s, stderr: %s]", stdin.fileno, stdout.fileno, stderr.fileno);

        // The monitor is locked by our starter, lets sneek in some state
        auto runningMutex = new TaskMutex;
        runningMutex.lock(); // We have to lock in this task, or we get an error!
        _runningMutex = cast(shared)runningMutex;

        // TODO: Fetch some attributes, remember we're still locked (ie. kill timeout)
        auto killTimeout = cast(immutable)_killTimeout;

        // Notify the task that started the watcher that the watcher has started
        starter.send(thisTask);

        // Make sure we clean up after the watcher exits
        scope(exit) {
            int exitStatus = process.wait();
            onProcessTermination(exitStatus);
        }

        // Create a barrier to wait for the read threads to start.
        // This is to ensure that stdout and stderr have started before we try to handle any messages
        auto readBarrier = new Barrier(3); // stdout + stderr + current threads.

        // Start threads for reading stdout and stderr
        auto stdoutThread = new Thread({
            readBarrier.wait();
            foreach (line; stdout.byLineCopy()) {
                //logger.tracef("Watcher(%s) STDOUT >> %s", thisTask, line);
                callStdoutCallback(line);
            }
            logger.tracef("Watcher(%s) STDOUT: Thread completed", thisTask);
        }).start();
        scope(exit) stdoutThread.join(false);

        auto stderrThread = new Thread({
            readBarrier.wait();
            foreach (line; stderr.byLineCopy()) {
                //logger.tracef("Watcher(%s) STDERR >> %s", thisTask, line);
                callStderrCallback(line);
            }
            logger.tracef("Watcher(%s) STDERR: Thread completed", thisTask);
        }).start();
        scope(exit) stderrThread.join(false);

        // Wait for all read threads to start
        readBarrier.wait();

        // Start thread for waiting on the process to finish
        auto waitThread = new Thread({
            process.wait();
            logger.tracef("Watcher(%s) WAIT: Process terminated, notifying watcher", thisTask);
            thisTask.prioritySendCompat(true);
        }).start();
        scope(exit) waitThread.join();
        waitThread.isDaemon = true;

        Timer killTimer;
        scope(exit) if (killTimer) killTimer.stop();

        // Keep a timer for catching zombies
        Nullable!MonoTime killTime;

        bool running = true;
        while (running) {
            // Handle messages
            try {
                logger.tracef("Watcher(%s): polling...", thisTask);
                receiveCompat(
                    // Send
                    (string message) {
                        if (message is null && stdin.isOpen) {
                            logger.tracef("Watcher(%s): Closing stdin", thisTask);
                            stdin.close();
                        } else if (stdin.isOpen) {
                            logger.tracef("Watcher(%s): Sending message: %s", thisTask, message);
                            stdin.writeln(message);
                            stdin.flush();
                        }
                    },
                    // Kill
                    (int signal) {
                        if (process.tryWait().terminated) return;

                        logger.tracef("Watcher(%s): Sending kill signal %s", thisTask, signal);
                        process.kill(signal);
                        logger.tracef("Watcher(%s): Kill signal sent", thisTask, signal);

                        // Start kill timer
                        if (killTimeout > 0.msecs && !killTimer) {
                            logger.tracef("Watcher(%s): Starting kill timeout", thisTask);
                            killTimer = setTimer(killTimeout, {
                                logger.warningf("Watcher(%s): Killing after kill timeout", thisTask);
                                thisTask.prioritySendCompat(SIGKILL);
                            });
                        }
                    },
                    // Process terminated
                    (bool _) {
                        logger.tracef("Watcher(%s): Process terminated", thisTask);
                        running = false;
                    }
                );
            } catch (OwnerTerminated e) {
                // Terminate the process if the owner is terminated
                logger.errorf("Watcher(%s): Owner terminated, killing child.", thisTask);
                process.kill(SIGKILL);
            }
        }

        // Close all open pipes
        logger.tracef("Watcher(%s): Closing all pipes", thisTask);
        foreach (file; [stdout, stderr, stdin]) {
            if (file.isOpen) file.close();
        }

        // For sanity
        logger.tracef("Watcher(%s): Sending SIGKILL and waiting", thisTask);
        try {
            process.kill(SIGKILL);
        } catch (Throwable e) {}
        process.wait();

        logger.tracef("Watcher(%s): stopped", thisTask);
    }

    /// Called by watcher thread when the process has terminated
    private void onProcessTermination(int status) shared {
        // the watcher pauses itself
        logger.trace("Process terminated");

        withLock((self) {
            self.running = false;
            self.exitStatus = status;
            self.runningMutex.unlock();
            self.runningMutex = null;
        });

        callTerminateCallback();
    }
}
