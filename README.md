# Supervised

[![Build Status](https://travis-ci.org/BenjaminSchaaf/supervised.svg?branch=master)](https://travis-ci.org/BenjaminSchaaf/supervised)

## Example

Here's a very incomplete example.

```d
auto processMonitor = new ProcessMonitor;
processMonitor.stdoutCallback = (string message) @safe {
    writeln(message);
};

processMonitor.start(['srcds', '-port', '8335']);
processMonitor.wait();
```