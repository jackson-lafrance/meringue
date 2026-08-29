# frozen_string_literal: true

source "https://rubygems.org"

gem "base64", ">= 0.2"

group :development do
  gem "minitest", ">= 5.0"
  gem "rake", ">= 13.0"
end

# Bundler evaluates this file, which makes it the only place `bundle install`
# can finish the job it starts. Installing from a clone also writes one small
# launcher to MERINGUE_BIN_DIR (default ~/.local/bin), so the command is
# available from anywhere.
#
# This runs on `bundle install` and nothing else, and never fails the install.
# Set MERINGUE_NO_SHIM=1 to skip it.
if File.basename($PROGRAM_NAME) == "bundle" && ARGV.include?("install")
  require_relative "lib/meringue/shim"
  message = Meringue::Shim.install!(source_dir: __dir__).fetch("message", "")
  # Bundler prints its own summary last, so announcing this first keeps the two
  # from reading as one paragraph.
  $stdout.puts("\n#{message}\n") unless message.empty? || Meringue::Shim.announced!
end
