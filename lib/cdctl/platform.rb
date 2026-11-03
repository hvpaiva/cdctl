# frozen_string_literal: true

require 'rbconfig'

module Cdctl
  module Platform
    LINUX = 'linux'
    WINDOWS = 'windows'
    MACOS = 'macos'
    OTHER = 'other'

    def self.current(host_os = RbConfig::CONFIG['host_os'])
      case host_os
      when /linux/ then LINUX
      when /mingw|mswin|cygwin/ then WINDOWS
      when /darwin/ then MACOS
      else OTHER
      end
    end
  end
end
