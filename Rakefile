# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'bundler/audit/task'
require 'minitest/test_task'
require 'rubocop/rake_task'
require_relative 'rakelib/support/tools'

# Coverage gates for test:cov. Each sits under what test:cov measures, overall or for the least
# covered file, and is raised when the measured figure rises.
MINIMUM_LINE_COVERAGE = 96
MINIMUM_BRANCH_COVERAGE = 84
MINIMUM_LINE_COVERAGE_BY_FILE = 87
MINIMUM_BRANCH_COVERAGE_BY_FILE = 49

# Minitest joins the prelude into a single-quoted shell string, so it stays on one line without
# quotes of its own. Bundler loads version.rb through the gemspec before SimpleCov starts, so that
# file would count as never run; skip leaves it out. Without merging, the gates judge this run alone.
COVERAGE_PRELUDE = [
  'require "simplecov"',
  'SimpleCov.start do',
  'merging false',
  'enable_coverage :branch',
  'cover "lib/**/*.rb"',
  'skip "lib/cdctl/version.rb"',
  "coverage(:line) { minimum #{MINIMUM_LINE_COVERAGE}; minimum #{MINIMUM_LINE_COVERAGE_BY_FILE}, per: :file }",
  "coverage(:branch) { minimum #{MINIMUM_BRANCH_COVERAGE}; minimum #{MINIMUM_BRANCH_COVERAGE_BY_FILE}, per: :file }",
  'end'
].join('; ')

Minitest::TestTask.create(:test) do |t|
  t.warning = true
  t.test_globs = ['test/**/*_test.rb']
end

Minitest::TestTask.create('test:unit') do |t|
  t.warning = true
  t.test_globs = ['test/unit/**/*_test.rb']
end

Minitest::TestTask.create('test:integration') do |t|
  t.warning = true
  t.test_globs = ['test/integration/**/*_test.rb']
end

Minitest::TestTask.create('test:cov') do |t|
  t.warning = true
  t.test_globs = ['test/unit/**/*_test.rb']
  t.test_prelude = COVERAGE_PRELUDE
end

RuboCop::RakeTask.new

Bundler::Audit::Task.new

desc 'Update the advisory database, then check Gemfile.lock'
task audit: %w[bundle:audit:update bundle:audit:check]

def require_tool(tool)
  abort Tools.missing(tool) unless system(tool, '--version', out: File::NULL, err: File::NULL)
end

namespace :lint do
  desc 'Check spelling with typos, which reads _typos.toml'
  task :spelling do
    require_tool('typos')
    sh 'typos'
  end

  desc 'Audit the workflows with zizmor; GH_TOKEN enables its online audits, CHECK_OFFLINE=1 turns them off'
  task :workflows do
    require_tool('zizmor')
    offline = ENV.fetch('CHECK_OFFLINE', '').empty? ? [] : ['--offline']
    sh 'zizmor', *offline, '.github/workflows'
  end
end

task default: %i[test rubocop]
