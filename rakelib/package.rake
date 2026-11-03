# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

namespace :package do
  desc 'Build the gem, install it into an empty GEM_HOME and run the installed executable'
  task :check do
    Dir.mktmpdir('cdctl-package-') do |dir|
      gem = File.join(dir, 'cdctl.gem')
      home = File.join(dir, 'gems')
      Bundler.with_unbundled_env do
        sh 'gem', 'build', 'cdctl.gemspec', '--output', gem
        sh 'gem', 'install', '--local', '--no-document', '--install-dir', home, '--bindir', File.join(home, 'bin'), gem
        PackageSmoke.new(home, dir).run
      end
    end
  end
end

# Runs the installed executable with nothing but its own GEM_HOME and an empty home directory, so a
# file missing from the gem or an undeclared dependency fails here rather than for the first user.
class PackageSmoke
  def initialize(home, directory)
    @home = home
    @env = { 'GEM_HOME' => home, 'GEM_PATH' => home, 'RUBYOPT' => nil, 'RUBYLIB' => nil, 'HOME' => directory,
             'DISPLAY' => nil, 'WAYLAND_DISPLAY' => nil, 'HYPRLAND_INSTANCE_SIGNATURE' => nil }
    @cdctl = File.join(home, 'bin', 'cdctl')
  end

  def run
    %w[version --help].each { |argument| cdctl(argument) }
    document('version')
    schema_names.each { |name| document('schema', name) }
    look_at_the_machine if ENV['CI']
    puts 'package:check: the installed gem answers on a machine with nothing else'
  end

  private

  # These read the real /proc and the real X server of whatever computer runs them, which on a
  # developer's machine can be a game someone is playing. A CI runner has none to reach.
  def look_at_the_machine
    %w[status capabilities].each { |command| document(command) }
  end

  # Read from the installed gem, so a schema file left out of the package fails here.
  def schema_names = document('schema').dig('data', 'names')

  def document(*arguments)
    result = JSON.parse(cdctl(*arguments, '--json'))
    abort "package:check: cdctl #{arguments.join(' ')} did not succeed: #{result}" unless result['ok']

    result
  end

  def cdctl(*arguments)
    out, err, status = Open3.capture3(@env, @cdctl, *arguments)
    abort "package:check: cdctl #{arguments.join(' ')} failed:\n#{err}" unless status.success?

    out
  end
end
