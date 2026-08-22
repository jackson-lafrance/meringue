# Releasing and distribution

RubyGems is the primary distribution channel. Each RubyGems publication is accompanied by a GitHub Release containing the exact `.gem` and a SHA-256 checksum. A maintainer-owned Homebrew tap is the recommended optional Homebrew channel after the first release; Homebrew core is deferred.

## Release gates

A release must not be tagged or published until all of these are true:

1. The maintainer has chosen actual license terms, added a `LICENSE` file, and replaced `Nonstandard` in `meringue.gemspec` with the matching SPDX identifier. If the project is not distributed under an open-source license, correct the README and do not pursue Homebrew.
2. The maintainer has approved the public author and contact email in the gemspec. Do not infer a private address from local Git configuration.
3. `Meringue::VERSION` is an intentionally selected, unpublished version—not merely the current placeholder—and `CHANGELOG.md` has a heading such as `## 0.1.0 - 2026-08-22` for that exact version.
4. The release commit is merged into `main`. Never tag or publish feature-branch contents.
5. CI is green for Ruby 3.1 and the current stable Ruby, and package verification passes.
6. The exact gem name and version are still absent from RubyGems.org immediately before tagging.

The local checks are:

```bash
bundle install
bundle exec rake test
bundle exec rake package:verify
bundle exec rake release:validate
```

`package:verify` strictly builds the gem, checks its metadata and intentional manifest, installs it without dependency or network resolution into a temporary gem home, and smoke-tests `--version`, `--help`, and `demo-state`. `release:validate` is also a prerequisite of Bundler's `release:guard_clean`. A second guard refuses `rake release` outside the OIDC-enabled GitHub tag job, so neither local credentials nor feature-branch execution can bypass the supported release boundary.

Inspect the release artifact before proceeding:

```bash
gem specification pkg/meringue-*.gem
ruby -rrubygems/package -e 'puts Gem::Package.new(Dir["pkg/meringue-*.gem"].fetch(0)).contents'
shasum -a 256 pkg/meringue-*.gem
```

## One-time trusted-publisher setup

Publishing uses RubyGems Trusted Publishing. Do not add a long-lived RubyGems API key to the repository.

1. Create or confirm the maintainer's RubyGems.org account, verify its email, require MFA for both UI and API access, and retain recovery codes securely.
2. In the GitHub repository settings, create an environment named `release`. Required reviewers are recommended.
3. After `.github/workflows/release.yml` is merged, create a [pending trusted publisher](https://rubygems.org/profile/oidc/pending_trusted_publishers) with:
   - Gem name: `meringue`
   - Repository owner: `jackson-lafrance`
   - Repository: `meringue`
   - Workflow filename: `release.yml`
   - Environment: `release`
   - Reusable-workflow owner and repository: blank

The workflow grants `id-token: write` only to the release job. RubyGems exchanges the GitHub OIDC identity for a short-lived, gem-scoped credential; no publication secret is stored in GitHub.

## Publishing a release

After the release preparation is reviewed and merged, update a normal checkout of `main`, rerun the release gates, and recheck RubyGems:

```bash
git switch main
git pull --ff-only origin main
version="$(ruby -Ilib -rmeringue/version -e 'print Meringue::VERSION')"
curl --fail-with-body "https://rubygems.org/api/v1/versions/meringue.json"
```

A `404` is expected before the first publication. For later releases, inspect the returned versions and stop if `$version` already exists. Published RubyGem versions are immutable and must never be replaced.

With explicit publication authorization, create one annotated tag from that exact `main` commit and push only the tag:

```bash
git tag -a "v$version" -m "Version $version"
git push origin "v$version"
```

`.github/workflows/release.yml` then:

1. proves the tag commit is already contained in `origin/main`;
2. proves `v<version>` matches `Meringue::VERSION`;
3. runs release validation, the full test suite, and package verification;
4. publishes once to RubyGems through OIDC; and
5. creates the corresponding GitHub Release with the gem and `SHA256SUMS`.

The old GitHub Packages publication path is intentionally removed. It duplicated RubyGems and gave public users a worse authenticated installation path.

After publication, verify from a clean temporary gem home before announcing the release:

```bash
tmp="$(mktemp -d)"
GEM_HOME="$tmp" GEM_PATH="$tmp" gem install meringue --no-document
GEM_HOME="$tmp" GEM_PATH="$tmp" "$tmp/bin/meringue" --version
GEM_HOME="$tmp" GEM_PATH="$tmp" "$tmp/bin/meringue" --help
rm -rf "$tmp"
```

Update the README's pre-release notice to make `gem install meringue` and `gem update meringue` the normal install/update path as part of the first release preparation.

### Partial-failure recovery

Before retrying a failed release run, query RubyGems first. If the version exists, publication succeeded even if checksum or GitHub Release creation failed later. Do not rerun a gem push for that version. Download the immutable public gem, verify it against the locally retained artifact, generate its checksum, and create the missing GitHub Release manually:

```bash
version="$(ruby -Ilib -rmeringue/version -e 'print Meringue::VERSION')"
curl --fail --location "https://rubygems.org/downloads/meringue-$version.gem" -o "meringue-$version.gem"
shasum -a 256 "meringue-$version.gem" > SHA256SUMS
gh release create "v$version" "meringue-$version.gem" SHA256SUMS --generate-notes --verify-tag
```

## Homebrew strategy

### Maintainer tap: recommended after the first release

A tap gives users `brew install jackson-lafrance/tap/meringue` without waiting for Homebrew core eligibility. Creating `jackson-lafrance/homebrew-tap` is a separate remote-repository action and requires explicit authorization; this repository does not create or impersonate that tap.

After authorization and after an immutable release exists:

1. Create `jackson-lafrance/homebrew-tap` using Homebrew's standard `homebrew-tap` layout.
2. Put the formula at `Formula/meringue.rb`.
3. Pin the release archive and every Ruby gem resource by SHA-256.
4. Depend on Homebrew's `ruby`, install resources with dependency resolution disabled, and wrap the executable with `GEM_HOME` pointing at `libexec`.
5. Test the formula from source on supported macOS and Linux runners.

Use this shape, replacing all release-controlled placeholders with values from the published release:

```ruby
class Meringue < Formula
  desc "Terminal-first control plane for multi-agent development"
  homepage "https://github.com/jackson-lafrance/meringue"
  url "https://github.com/jackson-lafrance/meringue/archive/refs/tags/v<VERSION>.tar.gz"
  sha256 "<RELEASE_ARCHIVE_SHA256>"
  license "<SPDX-LICENSE>"

  depends_on "ruby"

  resource "base64" do
    url "https://rubygems.org/gems/base64-0.3.0.gem"
    sha256 "27337aeabad6ffae05c265c450490628ef3ebd4b67be58257393227588f5a97b"
  end

  def install
    ENV["GEM_HOME"] = libexec
    resources.each do |resource|
      system Formula["ruby"].opt_bin/"gem", "install", resource.cached_download,
             "--ignore-dependencies", "--no-document", "--install-dir", libexec
    end
    system Formula["ruby"].opt_bin/"gem", "build", "meringue.gemspec"
    system Formula["ruby"].opt_bin/"gem", "install", "meringue-#{version}.gem",
           "--ignore-dependencies", "--no-document", "--install-dir", libexec
    bin.install libexec/"bin/meringue"
    bin.env_script_all_files(libexec/"bin", GEM_HOME: ENV["GEM_HOME"])
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/meringue --version").strip
    assert_match "Usage:", shell_output("#{bin}/meringue --help")
    assert_match '"projects"', shell_output("#{bin}/meringue demo-state")
  end
end
```

At release time, recheck the latest compatible `base64` version and checksum rather than updating the resource blindly. Validate with:

```bash
brew audit --strict --online jackson-lafrance/tap/meringue
brew install --build-from-source jackson-lafrance/tap/meringue
brew test jackson-lafrance/tap/meringue
```

Cross-repository formula updates should remain manual initially. Automating them later requires a fine-grained token or GitHub App authorized only for the tap; the source repository's default `GITHUB_TOKEN` cannot write to an unrelated repository.

### Homebrew core: defer

Do not submit to Homebrew core yet. Core requires a compatible open-source license, stable tagged releases, successful supported-platform builds/tests, reproducible dependencies, and demonstrated public interest. Reconsider it only after those requirements and Homebrew's then-current notability policy are satisfied. A cask is not appropriate for this Ruby CLI.
