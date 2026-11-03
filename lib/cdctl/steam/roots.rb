# frozen_string_literal: true

require_relative '../platform'

module Cdctl
  module Steam
    # Where Steam can live. The library list inside each root says where the games are.
    module Roots
      LINUX = [
        File.join('.local', 'share', 'Steam'),
        File.join('.steam', 'steam'),
        File.join('.steam', 'root'),
        File.join('.var', 'app', 'com.valvesoftware.Steam', '.local', 'share', 'Steam'),
        File.join('.var', 'app', 'com.valvesoftware.Steam', 'data', 'Steam'),
        File.join('snap', 'steam', 'common', '.local', 'share', 'Steam')
      ].freeze
      MACOS = [File.join('Library', 'Application Support', 'Steam')].freeze
      WINDOWS_VARIABLES = %w[ProgramFiles(x86) ProgramFiles].freeze
      EXPLICIT_VARIABLE = 'CDCTL_STEAM_ROOT'

      module_function

      # An explicit root replaces the search, so a caller can pin one installation.
      def candidates(platform:, home:, env:, configured: nil)
        explicit = env[EXPLICIT_VARIABLE].to_s
        return [explicit] unless explicit.empty?
        return [configured] if configured

        case platform
        when Platform::LINUX then LINUX.map { File.join(home, it) }
        when Platform::MACOS then MACOS.map { File.join(home, it) }
        when Platform::WINDOWS then env.values_at(*WINDOWS_VARIABLES).compact.map { File.join(it, 'Steam') }
        else []
        end
      end

      # The default locations are often symlinks to one directory.
      def existing(candidates)
        candidates.select { File.directory?(File.join(it, 'steamapps')) }.uniq { File.realpath(it) }
      end
    end
  end
end
