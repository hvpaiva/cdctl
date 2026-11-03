# frozen_string_literal: true

require_relative 'lib/cdctl/version'

Gem::Specification.new do |spec|
  spec.name = 'cdctl'
  spec.version = Cdctl::VERSION
  spec.authors = ['Highlander Paiva']
  spec.email = ['contact@hvpaiva.dev']

  spec.summary = 'Observe and control Crimson Desert from the command line, with evidence'
  spec.description = 'cdctl finds a Steam installation of Crimson Desert, its process and its window, and reports ' \
                     'what it can prove about them as versioned JSON, including what it could not verify. It is ' \
                     'built for any language model, agent, script or person that can run a command and read JSON ' \
                     'and images. It needs no game hook, no driver and no service.'
  spec.homepage = 'https://github.com/hvpaiva/cdctl'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  # Only tracked files ship, so the gem has to be built from a git checkout.
  gemspec = File.basename(__FILE__)
  development_only = %w[bin/ rakelib/ test/ .github/ Gemfile Rakefile .rubocop.yml .editorconfig .gitattributes
                        .gitignore _typos.toml mise.toml CONTRIBUTING.md ARCHITECTURE.md]
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject { |f| f == gemspec || f.start_with?(*development_only) }
  end
  spec.bindir = 'exe'
  spec.executables = ['cdctl']
  spec.require_paths = ['lib']
end
