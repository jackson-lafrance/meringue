# frozen_string_literal: true

module ReleaseValidation
  ROOT = File.expand_path("..", __dir__)
  REQUIRED_METADATA = {
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }.freeze

  module_function

  def errors
    spec = Gem::Specification.load(File.join(ROOT, "meringue.gemspec"))
    return ["meringue.gemspec could not be loaded"] unless spec

    errors = []
    licenses = Array(spec.licenses).reject(&:empty?)
    if licenses.empty? || licenses.any? { |license| license.casecmp("Nonstandard").zero? }
      errors << "choose release license terms and replace the gemspec's Nonstandard license value"
    end
    errors << "add a tracked LICENSE file containing the chosen terms" if Dir[File.join(ROOT, "LICENSE*")].empty?

    if spec.authors.empty? || spec.authors.any? { |author| author.match?(/contributors/i) }
      errors << "replace the generic gem author with maintainer-approved public attribution"
    end
    errors << "add a maintainer-approved public contact email to the gemspec" if Array(spec.email).reject(&:empty?).empty?

    REQUIRED_METADATA.each do |key, value|
      errors << "set gem metadata #{key.inspect} to #{value.inspect}" unless spec.metadata[key] == value
    end

    changelog = File.join(ROOT, "CHANGELOG.md")
    if !File.file?(changelog)
      errors << "add CHANGELOG.md"
    else
      release_heading = /^## \[?#{Regexp.escape(spec.version.to_s)}\]? - \d{4}-\d{2}-\d{2}$/
      errors << "add a dated CHANGELOG.md heading for version #{spec.version}" unless File.read(changelog).match?(release_heading)
    end

    errors
  end
end

namespace :release do
  desc "Validate human-controlled metadata required before publication"
  task :validate do
    errors = ReleaseValidation.errors
    abort "Release validation failed:\n- #{errors.join("\n- ")}" unless errors.empty?

    puts "Release metadata is complete."
  end

  task :trusted_publishing_only do
    trusted_tag_job = ENV["GITHUB_ACTIONS"] == "true" &&
      ENV["GITHUB_REF_TYPE"] == "tag" &&
      !ENV["ACTIONS_ID_TOKEN_REQUEST_URL"].to_s.empty? &&
      !ENV["ACTIONS_ID_TOKEN_REQUEST_TOKEN"].to_s.empty?
    abort "Gem publication is allowed only from the OIDC-enabled release tag workflow." unless trusted_tag_job
  end
end

# Make `rake release` fail before tagging or publishing unless both the human
# release gates and the trusted-publishing execution boundary are satisfied.
Rake::Task["release:guard_clean"].enhance(["release:validate", "release:trusted_publishing_only"])
