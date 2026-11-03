# frozen_string_literal: true

require 'fileutils'
require 'securerandom'

module Cdctl
  # Captures and observations can show what is on the player's screen, so they are readable by
  # their owner alone. A temporary name created with O_EXCL and then renamed never follows a link
  # planted at the destination, which matters when a caller picks a path under /tmp.
  module PrivateFiles
    module_function

    def directory(path) = FileUtils.mkdir_p(path, mode: 0o700)

    def write(path, bytes)
      temporary = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |io|
        io.write(bytes)
        io.fsync
      end
      File.rename(temporary, path)
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end

    # Deletes only files this tool named, by the pattern the caller passes. The directory goes in
    # `base` because glob characters in a path would otherwise match, and delete from, another one.
    def keep_newest(directory, pattern, count)
      files = Dir.glob(pattern, base: directory).map { File.join(directory, it) }.select { File.file?(it) }
      files.sort_by { -File.mtime(it).to_f }.drop(count).each { File.unlink(it) }
    rescue SystemCallError
      nil
    end
  end
end
