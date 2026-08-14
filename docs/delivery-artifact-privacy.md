# Delivery artifact privacy

Delivery artifacts represent the product change, not the orchestration that produced it. This applies to generated and worker-supplied branch names, worktree names, commit subjects/bodies/trailers, tags, pull request titles and bodies, release notes, and any comparable externally visible text.

## Allowed source

Derive names and prose only from the human product task title and requested change. A short opaque hash or numeric collision suffix may provide uniqueness. It must not encode or display an orchestration identity.

For example, a product task titled `P5-I2-W3 Fix signup validation` produces a branch shaped like:

```text
fix-signup-validation-a1b2c3d4
```

The issue id is stripped before slugging. New branches have no product-branded allocator prefix. Existing legacy branches remain recognizable by workspace lifecycle code solely so upgrades can safely reuse or clean their worktrees; compatibility must never become a new-name generation path.

## Prohibited content

Never put any of the following in a delivery artifact:

- Meringue branding used as an automation signature, including a `meringue/` branch prefix;
- project, issue, worker, head, queue, agent, or session identifiers;
- formatting variants such as `P5-I2-W3`, `p5_i2_w3`, `P5/I2/W3`, or `P5 I2 W3`;
- Pi or another harness/provider identity used to say who performed the work;
- AI confidence scores (`Confidence: 0.92`, `AI confidence 92%`, and variants);
- AI-authorship/co-authorship trailers or statements such as “worked on by agent …”, “agents involved …”, or descriptions of which agents contributed;
- managed workspace paths or internal session context in a PR body.

A product may legitimately discuss agents or the Meringue application as its subject. Even then, artifact names should state the product behavior (for example `protect-delivery-metadata`) rather than signing the artifact with automation branding or identity.

## Enforcement points

`Meringue::DeliveryArtifactPolicy` centralizes title cleanup, slug generation, supplied delivery-text cleanup, and recognition of allocator-owned branches. Workspace allocation and harness session labels use it directly. Worker system guidance applies the same policy to commits, PRs, and other artifacts that workers create through repository tools.

Before pushing or opening/updating a PR, workers must inspect:

1. the current branch name;
2. commit author, committer, subjects, bodies, and trailers;
3. the complete rendered PR title and body;
4. any release note or generated external text included in the change.

Unsafe generated or supplied values are rewritten from the product task. They are not copied with a disclaimer.

## Pull request descriptions

A PR body explains product behavior, implementation, and verification. It must not include managed worktree paths, worker/session ids, confidence scores, AI disclosure boilerplate, or an agent roster. Testing commands should start from a normal checkout, for example:

```sh
bundle exec rake test
```

The PR title is a normal human task title. The body may mention this application's product name only when necessary to explain the product behavior; it must never use branding to identify the author or automation that delivered the change.
