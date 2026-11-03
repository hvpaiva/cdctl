# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'cdctl'

Warning[:deprecated] = true

require 'minitest/autorun'

Dir[File.expand_path('support/*.rb', __dir__)].each { require it }
