# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# A malformed setting is the user's typo, not a kernel failure. `SaveConfiguration` must reject it
# with the per-field message the settings UI renders, which only works when every exception on the
# validation path is one `Schema.validate_changes` actually rescues. An unmatched quote used to reach
# a `rescue Shellwords::ParseError` clause naming a constant that does not exist, so the command
# failed with `uninitialized constant` instead of rejecting.
class KernelCoreSaveConfigurationRejectionTest < Minitest::Test
  include KernelCoreSupport

  def test_unmatched_quote_in_a_command_setting_is_rejected_with_a_field_error
    config_path = File.join(tmp_root, "config.toml")
    File.write(config_path, "")

    result = apply_command(
      "SaveConfiguration",
      "base_fingerprint" => Meringue::Config::Store.fingerprint(config_path),
      "changes" => { "harnesses.pi.command" => "pi --tools \"read" }
    )

    assert_rejected(result)
    assert_includes result.to_h.fetch("result").fetch("field_errors").fetch("harnesses.pi.command"), "Unmatched quote"
    assert_equal "", File.read(config_path), "a rejected save must leave the config file untouched"
  end
end
