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

import supervised.errors;
import supervised.logging;

private enum CloseStdin { init };
private enum ProcessTerminated { init };

@safe shared class ProcessMonitor {
    alias FileCallback = void delegate(string);
    alias EventCallback = void delegate();

    private {
        // Monitor mutex
        TaskMutex _mutex;

        Task _watcher;
        bool _running = false;
        TaskMutex _runningMutex; // Mutex that is locked while the process is running. Used for wait()
        int _exitStatus;

        Duration _killTimeout = 20.seconds;

        Pid _pid;
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

        @property Pid pid() @trusted {
            return cast(Pid)instance._pid;
        }

        package @property void pid(Pid pid) @trusted {
            instance._pid = cast(shared)pid;
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
            enforce!InvalidStateException(running, "Process is not running, cannot send message.");

            logger.tracef("Sending stdin message: %s", message);
            watcher.send(message);
        }
    }

    private auto withLock(T)(T delegate(Sync) fn) shared @trusted {
        logger.trace("Locking mutex");
        scope(exit) logger.trace("Unlocked mutex");

        synchronized (_mutex) {
            logger.trace("Aquired mutex lock");

            return fn(Sync(cast(ProcessMonitor)this));
        }
    }

    @property bool running() shared {
        return withLock((self) => self.running);
    }

    @property Duration killTimeout() shared {
        return withLock((self) => self.killTimeout);
    }

    @property void killTimeout(in Duration duration) shared {
        withLock((self) => self.killTimeout = duration);
    }

    @property Pid pid() shared {
        return withLock((self) => self.pid);
    }

    @property void stdoutCallback(in FileCallback fn) {
        withLock((self) => self.stdoutCallback = fn);
    }

    @property void stderrCallback(in FileCallback fn) {
        withLock((self) => self.stderrCallback = fn);
    }

    @property void terminateCallback(in EventCallback fn) {
        withLock((self) => self.terminateCallback = fn);
    }

    private void callStdoutCallback(in string message) shared @trusted {
        auto callback = _stdoutCallback;

        if (callback !is null) {
            try {
                callback(message);
            } catch (Throwable e) {
                logger.errorf("Stdout Callback Task(%s) Error: %s\nDue to line: %s", Task.getThis(), e, message);
            }
        }
    }

    private void callStderrCallback(in string message) shared @trusted {
        auto callback = _stderrCallback;

        if (callback !is null) {
            try {
                callback(message);
            } catch (Throwable e) {
                logger.errorf("Stderr Callback Task(%s) Error: %s\nDue to line: %s", Task.getThis(), e, message);
            }
        }
    }

    private void callTerminateCallback() shared @trusted {
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
        withLock((self) => self.send(message));
    }

    void closeStdin() shared {
        withLock((self) @trusted {
            enforce!InvalidStateException(self.running, "Process it not running, cannot close stdin.");

            logger.tracef("Sending closeStdin message");
            self.watcher.send(CloseStdin.init);
        });
    }

    void start(immutable string[] args, immutable Tuple!(string, string)[] env = null, immutable string workingDir = null) shared {
        withLock((self) @trusted {
            enforce!InvalidStateException(!self.running, "Process is already running, cannot start it.");

            static void fn(shared ProcessMonitor monitor, Tid sender, immutable string[] args, immutable Tuple!(string, string)[] _env, immutable string workingDir) {
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

            self.running = true;
            runWorkerTask(&fn, this, thisTid, args.idup, env.idup, workingDir.idup);

            receive(
                (Task watcher, shared Pid pid) {
                    self.watcher = watcher;
                    self.pid = cast(Pid)pid;
                },
                (shared Throwable error) {
                    throw cast(Throwable)error;
                },
            );

            logger.tracef("Process started, monitor: %s", self.watcher);
        });
    }

    void kill(int signal = SIGTERM) shared {
        withLock((self) @trusted {
            enforce!InvalidStateException(self.running, "Process is not running, cannot kill it");

            logger.tracef("Killing process with signal %s, monitor: %s", signal, self.watcher);
            self.watcher.send(signal);
        });
    }

    int wait() shared {
        auto pair = withLock((self) => tuple(self.runningMutex, self.exitStatus));
        auto runningMutex = pair[0];

        if (runningMutex is null) {
           return pair[1];
        }

        // Wait on the running mutex
        logger.trace("Waiting on process to finish");
        synchronized(runningMutex) {}

        return withLock((self) => self.exitStatus);
    }

    private void runWatcher(Tid starter, in string[] args, in string[string] env, in string workingDir) shared @trusted {
        auto thisTask = Task.getThis();
        logger.infof("Watcher(%s): started with %s", thisTask, args);

        // Start the process
        immutable config = Config.newEnv;

        ProcessPipes processPipes;
        try {
            processPipes = pipeProcess(args, Redirect.all, env, config, workingDir);
        } catch (ProcessException exception) {
            logger.tracef("Watcher(%s): Exception starting process: %s", thisTask, exception);
            starter.send(cast(shared Throwable)exception);
            return;
        }

        auto process = processPipes.pid;
        auto stdin = processPipes.stdin;
        auto stdout = processPipes.stdout;
        auto stderr = processPipes.stderr;
        logger.tracef("Watcher(%s): [pid: %s, stdin: %s, stdout: %s, stderr: %s]", thisTask, process, stdin.fileno, stdout.fileno, stderr.fileno);

        // The monitor is locked by our starter, lets sneek in some state
        auto runningMutex = new TaskMutex;
        runningMutex.lock(); // We have to lock in this task, or we get an error!
        _runningMutex = cast(shared)runningMutex;

        // Fetch some attributes, remember we're still locked (ie. kill timeout)
        immutable killTimeout = _killTimeout;

        // Notify the task that started the watcher that the watcher has started
        logger.tracef("Watcher(%s): Notifying starter that process has started", thisTask);
        starter.send(thisTask, cast(shared)process);

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
                logger.tracef("Watcher(%s) STDOUT >> %s", thisTask, line);
                callStdoutCallback(line);
            }
            logger.tracef("Watcher(%s) STDOUT: Thread completed", thisTask);
        }).start();
        scope(exit) stdoutThread.join(false);

        auto stderrThread = new Thread({
            readBarrier.wait();
            foreach (line; stderr.byLineCopy()) {
                logger.tracef("Watcher(%s) STDERR >> %s", thisTask, line);
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
            Thread.sleep(50.msecs); // Wait for stderr and stdout to be fully processed.
            logger.tracef("Watcher(%s) WAIT: Process terminated, notifying watcher", thisTask);
            thisTask.send(ProcessTerminated.init);
        }).start();
        scope(exit) waitThread.join();
        waitThread.isDaemon = true;

        // Keep a timer for catching zombies
        Timer killTimer;

        bool running = true;
        while (running) {
            // Handle messages
            try {
                logger.tracef("Watcher(%s): polling...", thisTask);
                receive(
                    // Send
                    (string message) {
                        logger.tracef("Watcher(%s): Sending message: %s", thisTask, message);
                        stdin.writeln(message);
                        stdin.flush();
                    },
                    // Kill
                    (int signal) {
                        //if (process.tryWait().terminated) return;

                        logger.tracef("Watcher(%s): Sending kill signal %s", thisTask, signal);
                        process.kill(signal);
                        logger.tracef("Watcher(%s): Kill signal sent", thisTask, signal);

                        // Start kill timer
                        if (killTimeout > 0.msecs && !killTimer) {
                            logger.tracef("Watcher(%s): Starting kill timeout", thisTask);
                            killTimer = setTimer(killTimeout, {
                                logger.warningf("Watcher(%s): Killing after kill timeout", thisTask);
                                thisTask.send(SIGKILL);
                            });
                        }
                    },
                    (CloseStdin _) {
                        logger.tracef("Watcher(%s): Closing stdin", thisTask);
                        stdin.close();
                    },
                    // Process terminated
                    (ProcessTerminated _) {
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

        // Stop the timer if its started.
        if (killTimer) killTimer.stop();

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

        logger.infof("Watcher(%s): stopped", thisTask);
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

        logger.trace("Calling process termination callback");
        callTerminateCallback();
    }
}
