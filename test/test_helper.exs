# Tiers are selected by tag, so a bare `mix test` must not silently run a
# subset and report success. Every test carries exactly one tier tag; an
# untagged test is a test nobody decided the cost of.
ExUnit.start(capture_log: true)
