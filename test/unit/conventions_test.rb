# frozen_string_literal: true

require 'prism'
require 'test_helper'

# Rules no linter knows. The first one is why this tool exists in this shape: it must work on any
# machine that runs the game, so nothing about one particular machine may reach the shipped code.
class ConventionsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SHIPPED = Dir.glob(File.join(ROOT, '{lib,exe}/**/*')).select { File.file?(it) }.freeze
  LIBRARY = Dir.glob(File.join(ROOT, 'lib/**/*.rb')).freeze

  MACHINE_SPECIFIC = {
    'a home directory' => %r{/home/[a-z]|/Users/[a-z]}i,
    'a video output name' => /\b(?:HDMI-A-\d|DP-\d|eDP-\d)\b/,
    'a desktop distribution' => /omarchy/i,
    'a game streaming host' => /sunshine|moonlight|stream-display/i,
    'a helper outside this repository' => %r{/tmp/crimson|CrimsonHUD|crimson-desert-cursor},
    'a fixed display size' => /\b(?:3440|2560|1920)\s*x?\s*(?:1440|1080)?\b/
  }.freeze

  def relative(path) = path.delete_prefix("#{ROOT}/")

  def test_shipped_code_knows_nothing_about_one_machine
    SHIPPED.each do |path|
      text = File.read(path)

      MACHINE_SPECIFIC.each do |what, pattern|
        refute_match pattern, text, "#{relative(path)} names #{what}"
      end
    end
  end

  def test_the_compositor_is_optional_for_everything_but_its_own_driver
    (LIBRARY - [File.join(ROOT, 'lib/cdctl/compositor.rb'), File.join(ROOT, 'lib/cdctl/capture/service.rb'),
                File.join(ROOT, 'lib/cdctl/capabilities.rb')]).each do |path|
      refute_match(/hyprctl|grim\b/, File.read(path), "#{relative(path)} depends on one compositor")
    end
  end

  def test_only_the_shell_wrapper_starts_programs
    (LIBRARY - [File.join(ROOT, 'lib/cdctl/shell.rb')]).each do |path|
      nodes(Prism.parse_file(path).value).each do |node|
        refute spawn?(node), "#{relative(path)}:#{node.location.start_line} starts a program"
      end
    end
  end

  def test_only_the_context_writes_to_the_terminal
    (LIBRARY - [File.join(ROOT, 'lib/cdctl/cli/context.rb')]).each do |path|
      nodes(Prism.parse_file(path).value).each do |node|
        refute stream?(node), "#{relative(path)}:#{node.location.start_line} writes outside the Context"
      end
    end
  end

  def test_shipped_text_is_ascii
    (SHIPPED + Dir.glob(File.join(ROOT, 'test/**/*.rb'))).each do |path|
      assert_predicate File.binread(path).force_encoding(Encoding::UTF_8), :ascii_only?,
                       "#{relative(path)} is not ASCII"
    end
  end

  def test_the_project_prose_has_no_em_dashes
    em_dash = [0x2014].pack('U')

    Dir.glob(File.join(ROOT, '{*.md,docs/*.md}')).each do |path|
      refute_includes File.read(path), em_dash, "#{relative(path)} uses an em dash"
    end
  end

  def test_schemas_are_listed_and_exist
    Cdctl::Schemas::NAMES.each do |name|
      assert_path_exists File.join(ROOT, "lib/cdctl/schemas/#{name}.json")
      assert Cdctl::Schemas.document(name)
    end
  end

  private

  def nodes(node) = [node, *node.compact_child_nodes.flat_map { nodes(it) }]

  def spawn?(node)
    case node
    when Prism::XStringNode, Prism::InterpolatedXStringNode then true
    when Prism::CallNode then node.name == :popen || (kernel_call?(node) && %i[system spawn exec].include?(node.name))
    else constant?(node, :Open3)
    end
  end

  def stream?(node)
    case node
    when Prism::CallNode then kernel_call?(node) && %i[puts print printf putc warn p pp].include?(node.name)
    when Prism::GlobalVariableReadNode, Prism::GlobalVariableWriteNode then %i[$stdout $stderr].include?(node.name)
    else constant?(node, :STDOUT, :STDERR)
    end
  end

  def kernel_call?(call) = call.receiver.nil? || constant?(call.receiver, :Kernel, :Process)

  def constant?(node, *names)
    (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && names.include?(node.name)
  end
end
