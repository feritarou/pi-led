require "pi-gpio"
require "ini"
require "option_parser"
require "log"

module Pi

  # `pi-led` is a simple helper program for Raspberry Pi to control LEDs attached to one or multiple GPIO pins.
  #
  # Both single- or multichannel (RGB) LEDs are supported; the attached pins can be configured through a simple configuration file.
  # Through the same mechanism, `pi-led` also provides an easy way to let an LED flash or blink with some particular pattern.
  #
  # ## Configuration
  # To inform `pi-led` about your LEDs and the GPIO pins they are connected to, you must provide it with a simple configuration file.
  # By default, `pi-led` attempts to read the file `~/.pi-led.ini`. This path can be overridden with the `-c` command line option.
  #
  # The config file is an INI-style list of sections, where
  # 1. each section title must be a unique name that distinguishes some particular LED (*LED identifier*);
  # 2. in each key-value pair, the key must consist of a **single letter** that serves as a *channel identifier*; and
  # 3. the value denotes the GPIO pin number this channel is connected at, in the range 0..27.
  # Example of a configuration file for a 2 LEDs setup:
  # ```
  # [MyFirstLED]
  # W=15
  # [Colored]
  # R=2
  # G=3
  # B=4
  # ```
  #
  # ## Patterns
  # Channel and LED identifiers can then be used together with pausing information to create arbitrary *blinking patterns*
  # that your LEDs will repeat until another pattern is put into effect. Patterns are composed from tokens separated by whitespace,
  # where each token must be one of the following:
  # - An LED identifier that matches exactly the name of the corresponding section in the config file and is followed by a colon
  #   as in `MyFirstLED:`. This will affect all subsequent tokens until another LED identifier is encountered. As long as no
  #   LED identifier is present, `pi-led` will interpret all channels as referring to the first LED section in the config file.
  # - A combination of uppercase and lowercase versions of channel identifiers: An uppercase letter leads to the channel being
  #   turned on (i.e., the corresponding GPIO pin will be set to "high" voltage), while lowercase letters turn it off again.
  # - A pause command, consisting of an integer and an optional unit string that together denote a time span to wait before
  #   the next token is executed. Valid unit strings are `h`, `min`, `s`, `ms`, `µs`, and `ns`. If no unit string is specified,
  #   "ms" (milliseconds) is assumed as default.
  # - A single hyphen character (`-`), which serves as a shortcut to switch off all channels of the currently selected LED.
  #   (Thus, if the LED has three channels `a`, `b`, and `c`, `-` would be equivalent to `abc`.)
  #
  # ## Usage
  # Once `pi-led` runs, patterns can be started by simply providing them on STDIN as a line of input. The pattern will be stay
  # in effect until it is replaced by another one.
  # Thus patterns can also be easily switched by scripts or other programs that rely on `pi-led` as a child process, via piping.
  module LED
    extend self

    # =======================================================================================
    # Nested structs
    # =======================================================================================

    # :nodoc:
    abstract struct Op; end
    # :nodoc:
    record Nop   < Op
    # :nodoc:
    record On    < Op, pin : Int32
    # :nodoc:
    record Off   < Op, pin : Int32
    # :nodoc:
    record Pause < Op, time : Time::Span

    # =======================================================================================
    # Constants
    # =======================================================================================

    # :nodoc:
    Log = ::Log.for("pi-led")

    # =======================================================================================
    # Class variables
    # =======================================================================================

    @@led : Hash(String, Hash(Char, Int32)) = {} of String => Hash(Char, Int32)
    @@used_pins = Set(Int32).new
    @@cfgfile : Path = Path["~/.pi-led.ini"].expand(home: true)
    @@ops = StaticArray(Op, 1000).new(Nop.new)
    @@static = true

    # =======================================================================================
    # Methods
    # =======================================================================================

    def parse_config_file
      OptionParser.parse do |p|
        p.banner = "Usage: pi-led [args]"

        p.on "-c PATH",
             "--config-file=PATH",
             "Specifies a path to the config file (default: ~/.pi-led.ini)" do |path|
          if File.exists? path
            @@cfgfile = Path[path]
          else
            STDERR.puts "Config file '#{path}' not found! Aborting."
            exit 1
          end
        end

        p.invalid_option do |flag|
          STDERR.puts "Invalid option #{flag}. Aborting."
          STDERR.puts p
          exit 1
        end
      end

      ret = ""
      begin
        file = File.open @@cfgfile
        entries = INI.parse file
        file.close
        entries.each_with_index do |entry, index|
          map = {} of Char => Int32
          led_name, settings = entry
          settings.each do |channel, pin|
            if channel =~ /[a-zA-Z]/
              if pin.to_i.in? 0...27
                pin = pin.to_i
                if pin.in? @@used_pins
                  raise "Pin #{pin} was assigned to multiple channels"
                else
                  map[channel.chars.first.downcase] = pin
                  @@used_pins << pin
                end
              else
                raise "Detected invalid pin value '#{pin}'"
              end
            else
              raise "Invalid channel identifier '#{channel}': " +
                    "A channel identifier must be a single character in the range A-Z"
            end
          end
          @@led[led_name] = map
          ret = led_name if index.zero?
        end
      rescue ex
        msg = String.build do |s|
          s << "Parsing error while reading from '"
          s << @@cfgfile.to_s
          case ex
          when INI::ParseException
            s << "' (line "
            s << ex.line_number
            s << ", col "
            s << ex.column_number
            s << "): "
            s << ex.message
          else
            s << "': "
            s << ex
          end

          s << ". Aborting."
        end

        STDERR.puts msg
        exit 1
      end

      Log.trace &.emit "Successfully parsed config file", led: @@led
      Log.trace &.emit "Return value", ret: ret
      ret
    end

    # ---------------------------------------------------------------------------------------

    # The main thread of execution.
    def run
      ::Log.setup_from_env
      closing = false

      # Register signal handler for Ctrl+C
      Signal::INT.trap do
        closing = true
        Fiber.yield
        @@used_pins.each { |n| Pi.gpio[n].low! }
        exit
      end

      first_led = parse_config_file

      current = @@led[first_led]
      @@used_pins.each { |n| Pi.gpio[n].as_output }

      spawn do
        i = 0
        until closing
          op = @@ops.unsafe_fetch i

          if op.is_a? Nop
            i = 0
            Fiber.yield if @@static
            next
          end

          case op
          when On    then Pi.gpio[op.pin].high!
          when Off   then Pi.gpio[op.pin].low!
          when Pause then sleep op.time
          end

          i += 1
          Fiber.yield if @@static
        end
      end

      until closing
        pattern = gets
        if pattern
          @@static = true
          @@ops.[]= Nop.new
          k = 0
          @@used_pins.each { |n| Pi.gpio[n].low! }
          tokens = pattern.split
          tokens.each do |token|
            case token
            when /^([[:alpha:]][^:]*):$/
              current = @@led[$1] || current

            when /^(\d+)(h|min|s|ms|µs|ns)?$/
              amount = $1.to_i
              duration = case $2?
                when "h"    then amount.hours
                when "min"  then amount.minutes
                when "s"    then amount.seconds
                when "ms"   then amount.milliseconds
                when "µs"   then amount.microseconds
                when "ns"   then amount.nanoseconds
                else             amount.milliseconds
                end
              @@ops[k] = Pause.new duration
              @@static = false
              k += 1

            when /^[a-zA-Z]+$/
              token.chars.each do |c|
                d = c.downcase
                Log.trace &.emit "Checking for entry", channel: d.to_s
                pin = current[d]?
                if pin
                  if c.ascii_lowercase?
                    Log.trace &.emit "Found! Adding an OFF to the operations list", pin: pin
                    @@ops[k] = Off.new pin
                  else
                    Log.trace &.emit "Found! Adding an ON to the operations list", pin: pin
                    @@ops[k] = On.new pin
                  end
                  k += 1
                end
              end

            when "-"
              current.values.each do |pin|
                @@ops[k] = Off.new pin
                k += 1
              end
            end
          end
        end
        Fiber.yield
      end

    end

  end
end

Pi::LED.run
