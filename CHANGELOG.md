# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the plugin uses
[semantic versioning](https://semver.org).

## [0.1.0] - 2026-07-03

### Added

- `go-senior-builder` agent that loads only the skills a request needs and returns a plan, patch-ready diffs, and verification steps.
- Four skills: `go-patterns`, `go-devops-tools`, `go-microservices`, `go-testing-patterns`, each with a Persona and Build/Review/Audit modes header, a Cross-References section linking siblings and the Ginkgo plugin, and `allowed-tools` frontmatter pre-approving the tools each needs (Read/Edit/Write/Glob/Grep, `go`, `golangci-lint`, `git`, Agent).
- `go-patterns` coverage: goroutines/channels, error handling (`errors.Is`/`errors.As`, wrapping), interfaces, generics (Go 1.18+), context propagation/deadlines/values, package structure, naming, allocation hygiene.
- `go-testing-patterns` coverage: table-driven tests, mocking, concurrency testing with the race detector, `goleak` goroutine-leak detection, deterministic time via `testing/synctest` (Go 1.25+), `t.Context()`, benchmarking, and test organization.
- `go-devops-tools` coverage: CLI framework selection, config management, structured logging, cloud SDKs, output formatting, and `signal.NotifyContext` signal-to-context shutdown.
- `go-microservices` coverage: stdlib `net/http.ServeMux` method+path routing (Go 1.22+) as the default before a framework, HTTP vs gRPC, middleware/interceptors, observability, and graceful shutdown around `signal.NotifyContext` with captured serve/shutdown errors.
- `PostToolUse` hook that runs `gofmt -s` (and `goimports` when present) on Go files after Write/Edit.
- Marketplace manifest so the plugin installs via `/plugin marketplace add amaanx86/claude-go-plugin`.
