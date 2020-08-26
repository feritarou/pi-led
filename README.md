# pi-led

A simple helper program to control LEDs attached to one or multiple GPIO pins of a Raspberry Pi.
It supports single- or multichannel (RGB) LEDs via the use of a simple configuration file.

## Installation

There are two basic ways to install `pi-led`: Build it directly on the Raspberry Pi, or via cross-compilation.

The first way is more convenient if you just wish to use `pi-led`; if you plan on forking your own version, the second way
may be a better choice because it will likely lead to shorter compilation times and enables you to use the development
environment on your desktop PC.

In either case you will need the Crystal compiler installed on the RPi, which is nothing of a problem anymore: E.g., on Raspbian/Raspberry Pi OS, just enter
```bash
sudo apt install crystal
```
into a terminal and you're done.

### Method 1: Build directly on the Raspberry Pi
Clone the GitHub repository to a folder on the Raspberry Pi. `cd` into that folder and run `shards build`. That's it! The program should now be available in the `bin` subfolder and can be copied/linked to however you see fit.

### Method 2: Cross-compile
Clone the GitHub repository to a folder on your desktop PC. Under the assumptions that ...

1. you are working on Raspbian/Raspberry Pi OS,
2. left the default user and host name on the RPi unchanged (`pi@raspberrypi`),
3. can connect to the Raspberry Pi via SSH using a non-interactive authentication method like public key or SSL certificate,

... you may be able to follow the exact same build procedure that works for me, which I have automated with a Makefile:
First, turn on your Pi (headless is completely sufficient). Then, on your desktop PC, `cd` into your local clone of the repo,
and enter `make cross-pi` or simply `make`. This will attempt to
- invoke the Crystal compiler once on your desktop machine with the `--cross-compile` option set,
- transfer the resulting object file and linkage information to the Pi via SFTP, and
- link everything together on the Pi by issuing a remote command via SSH.

It is, however, not unlikely that things don't work out for you that simple. In this case, check that the above conditions are all
met in your setting, and try to adjust the values in the Makefile accordingly. If it still doesn't work, you may have to reproduce
the make procedure step by step - or revert to method 1 outlined above.

## Configuration
To inform `pi-led` about your LEDs and the GPIO pins they are connected to, you must provide it with a simple configuration file.
By default, `pi-led` attempts to read the file `~/.pi-led.ini`. This path can be overridden with the `-c` command line option.

The config file is an INI-style list of sections, where
1. each section title must be a unique name that distinguishes some particular LED (*LED identifier*);
2. in each key-value pair, the key must consist of a **single letter** that serves as a *channel identifier*; and
3. the value denotes the GPIO pin number this channel is connected at, in the range 0..27.
Example of a configuration file for a 2 LEDs setup:
```
[MyFirstLED]
W=15
[Colored]
R=2
G=3
B=4
```

## Patterns
Channel and LED identifiers can then be used together with pausing information to create arbitrary *blinking patterns*
that your LEDs will repeat until another pattern is put into effect. Patterns are composed from tokens separated by whitespace,
where each token must be one of the following:
- An LED identifier that matches exactly the name of the corresponding section in the config file and is followed by a colon
  as in `MyFirstLED:`. This will affect all subsequent tokens until another LED identifier is encountered. As long as no
  LED identifier is present, `pi-led` will interpret all channels as referring to the first LED section in the config file.
- A combination of uppercase and lowercase versions of channel identifiers: An uppercase letter leads to the channel being
  turned on (i.e., the corresponding GPIO pin will be set to "high" voltage), while lowercase letters turn it off again.
- A pause command, consisting of an integer and an optional unit string that together denote a time span to wait before
  the next token is executed. Valid unit strings are `h`, `min`, `s`, `ms`, `µs`, and `ns`. If no unit string is specified,
  "ms" (milliseconds) is assumed as default.
- A single hyphen character (`-`), which serves as a shortcut to switch off all channels of the currently selected LED.
  (Thus, if the LED has three channels `a`, `b`, and `c`, `-` would be equivalent to `abc`.)

## Usage
Once `pi-led` runs, patterns can be started by simply providing them on STDIN as a line of input. The pattern will be stay
in effect until it is replaced by another one.
Thus patterns can also be easily switched by scripts or other programs that rely on `pi-led` as a child process, via piping.

## Contributing

1. Fork it (<https://github.com/mastoryberlin/pi-led/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Mastory Berlin](https://github.com/mastoryberlin) - creator and maintainer
