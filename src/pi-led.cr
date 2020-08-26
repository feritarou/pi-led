require "pi-gpio"
require "ini"
require "option_parser"
require "log"

module Pi

  # A simple helper program to control LEDs attached to one or multiple GPIO pins
  # of a Raspberry Pi.
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
            when /[0-9]+/
              duration = token.to_i
              @@ops[k] = Pause.new duration.microseconds
              @@static = false
              k += 1
            when /[a-zA-Z]+/
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
            end
          end
        end
        Fiber.yield
      end

    end

  end
end

Pi::LED.run
