# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
$LOAD_PATH.unshift(__dir__)

require "minitest/autorun"
require "fileutils"
require "json"
require "set"
require "tmpdir"
require "meringue"
