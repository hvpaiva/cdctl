# frozen_string_literal: true

module Cdctl
  module X11
    # Reads MIT-MAGIC-COOKIE-1 entries from Xauthority files. Each desktop keeps the file somewhere
    # else, and the game's own XAUTHORITY can point inside its container, so several places are
    # tried. A cookie is a credential: it goes to the X server and is never printed or logged.
    module Authority
      SCHEME = 'MIT-MAGIC-COOKIE-1'
      RUNTIME_PATTERNS = ['xauth_*', '.mutter-Xwaylandauth.*', File.join('gdm', 'Xauthority'), 'Xauthority'].freeze

      module_function

      def cookies(display_number, paths)
        paths.flat_map { read(it) }.select { |entry| matches?(entry, display_number) }.map { it[:data] }.uniq
      end

      def candidate_paths(env:, home:, runtime_dir:, process_path: nil)
        explicit = [env['XAUTHORITY'], process_path, File.join(home, '.Xauthority')]
        (explicit + in_runtime_dir(runtime_dir)).compact.reject(&:empty?).uniq
      end

      def in_runtime_dir(directory)
        return [] unless directory

        RUNTIME_PATTERNS.flat_map { Dir.glob(it, base: directory) }.map { File.join(directory, it) }
      end
      private_class_method :in_runtime_dir

      def matches?(entry, display_number)
        entry[:name] == SCHEME && (entry[:number].empty? || entry[:number] == display_number.to_s)
      end

      # Entries are four length-prefixed big-endian fields after a 16-bit family.
      def read(path)
        bytes = File.binread(path)
        entries = []
        offset = 0
        while offset + 2 <= bytes.bytesize
          offset += 2
          address, offset = field(bytes, offset)
          number, offset = field(bytes, offset)
          name, offset = field(bytes, offset)
          data, offset = field(bytes, offset)
          entries << { address:, number:, name:, data: }
        end
        entries
      rescue SystemCallError, ArgumentError, TypeError
        []
      end

      def field(bytes, offset)
        length = bytes.byteslice(offset, 2).unpack1('n')
        value = bytes.byteslice(offset + 2, length)
        raise ArgumentError, 'truncated entry' unless value && value.bytesize == length

        [value, offset + 2 + length]
      end
      private_class_method :field
    end
  end
end
