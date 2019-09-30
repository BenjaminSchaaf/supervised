# Supervised

[![Build Status](https://travis-ci.org/BenjaminSchaaf/supervised.svg?branch=master)](https://travis-ci.org/BenjaminSchaaf/supervised)

THIS PROJECT IS SUPERSEDED BY VIBE CORE. A better implementation of this, also partially built by me, can now be found in [vibe-core/eventcore](https://github.com/vibe-d/vibe-core). This project will no longer be maintained.

## Example

Here's a very incomplete example.

```d
auto processMonitor = new shared ProcessMonitor;
processMonitor.stdoutCallback = (string message) @safe {
    writeln(message);
};

processMonitor.start(['srcds', '-port', '8335']);
processMonitor.wait();
```