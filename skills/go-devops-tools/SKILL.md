---
name: go-devops-tools
description: Building CLI tools, DevOps utilities, cloud integrations, and infrastructure automation in Go. Covers framework selection, flag parsing, configuration, output formatting, signal handling, and deployment patterns.
user-invocable: true
allowed-tools: Read Edit Write Glob Grep Bash(go:*) Bash(golangci-lint:*) Bash(git:*) Agent
---

**Persona:** You are a platform engineer shipping single-binary tools that run in CI and on operators' laptops. You favor the stdlib and a minimal dependency set, and you make failure modes and dry-runs explicit.

**Modes:**
- **Build mode** — writing a new tool or subcommand. Pick the lightest framework that fits, wire config precedence, handle signals for clean shutdown.
- **Review mode** — reviewing a diff. Check exit codes, error output to stderr, context/signal propagation, and that secrets come from the environment, not flags or code.
- **Audit mode** — sweeping a tool for operational gaps (no graceful shutdown, unstructured logs, hardcoded config, missing dry-run). Parallelize by concern for large codebases.

# Purpose

Guide DevOps and infrastructure tool development in Go: choosing between CLI frameworks, building deployment helpers, cloud integrations, and production-grade command-line applications.

# When to Use

- Building CLI tools for infrastructure automation
- Creating deployment utilities or admin scripts
- Integrating with cloud providers (AWS, GCP, Azure)
- Building observability tools (monitoring, logging)
- Writing infrastructure-as-code helpers
- Developing container orchestration tools

<Do_Not_Use_When>
- Building HTTP/REST APIs (use go-microservices skill)
- Building gRPC services (use go-microservices skill)
- General Go patterns (use go-patterns skill)
- Writing tests (use go-testing-patterns skill)
</Do_Not_Use_When>

# Workflow

## 1) CLI Framework Selection

### Cobra
- **Best for**: Complex CLIs with subcommands, plugins, completions
- **Strengths**: Rich command structure, auto-generated help, shell completion
- **Use when**: Building a multi-command tool (like `kubectl`, `docker`, `helm`)
- **Example**: `terraform`, `hugo`

### urfave/cli (v3)
- **Best for**: simple to mid-complexity CLIs, fast startup
- **Strengths**: lightweight, quick to build, good documentation
- **Use when**: building simpler tools, rapid iteration
- **Version**: use v3 (current stable, context-aware `Action` signatures); v2 is legacy
- **Example**: `drone`, `snapcraft`'s tooling

### Flag package (stdlib)
- **Best for**: Simple scripts, minimal dependencies
- **Strengths**: No external deps, part of stdlib
- **Use when**: Quick one-off tools, strict dependency constraints
- **Example**: Internal scripts, prototypes

### Comparison table
| Framework | Complexity | Subcommands | Help Gen | Plugins | Size |
|-----------|-----------|------------|----------|---------|------|
| Cobra | High | Yes | Auto | Yes | Large |
| Urfave | Medium | Yes | Semi | No | Medium |
| Flag | Simple | No | Manual | No | Tiny |

## 2) Configuration Management

### Approaches
- **Environment variables**: Simple, cloud-native, good for CI/CD
- **Config files**: YAML/TOML for complex setups
- **Flags**: Runtime overrides, explicit control
- **Defaults**: Sensible defaults reduce configuration burden

### Best practices
```go
// Load config in priority order: defaults → file → env → flags
config := loadDefaults()
config.mergeFromFile("config.yaml")
config.mergeFromEnv()
config.mergeFromFlags()
```

### Popular libraries
- **Viper**: Config file management (YAML, TOML, JSON)
- **Go-env**: Simple struct-based env parsing
- **Pflag**: Enhanced flag parsing (POSIX compliant)

## 3) Logging & Observability

### Logging strategy
- **Structured logging**: Key-value pairs, easier to parse
- **Levels**: DEBUG, INFO, WARN, ERROR (not all outputs)
- **Output**: Stdout for normal, stderr for errors
- **Format**: JSON for machines, human-readable for humans

### Libraries (in order of preference)
- **`log/slog`** (stdlib, Go 1.21+): the default. No dependency, structured, pluggable handlers. Reach for it first.
- **zap**: use only when profiling shows `slog` allocation is a real hot path; it is faster but adds a dependency and API surface.
- **logrus**: legacy only. It is in maintenance mode (no new features) and the ecosystem has moved to `slog`; do not start new tools on it.

### Best practices
```go
// Not: log.Printf("processed: %s", item)   // unstructured, unparseable
// Yes: slog.Info("processed item", "item", item, "duration", d)
```
Keep messages lowercase, use short consistent key names, and log to stderr so stdout stays reserved for the tool's actual output (Thanos logging conventions apply equally to CLIs).

## 4) Cloud Provider Integration

### AWS SDK (aws-sdk-go-v2)
- Use context for cancellation and timeouts
- Use middleware for retries, logging
- Implement backoff strategies for rate limits
- Example: S3 upload, EC2 management, DynamoDB queries

### Kubernetes Client
- Use `client-go` for programmatic access
- RESTful operations on Kubernetes resources
- Watch operations for event-driven automation
- Example: Custom operators, controllers, admin tools

### Other providers
- **GCP**: `cloud.google.com/go`
- **Azure**: `github.com/Azure/azure-sdk-for-go`
- **Terraform**: `github.com/hashicorp/terraform-exec` for programmatic Terraform

## 5) Output Formatting

### Text output
```go
// Simple: fmt.Println
// Formatted: fmt.Printf
// Templated: text/template
```

### Structured output
- **JSON**: `encoding/json`, use `json` tags for field mapping
- **YAML**: Popular in Kubernetes/DevOps tools
- **CSV**: `encoding/csv` for data export
- **Tables**: `text/tabwriter` or `github.com/olekukonko/tablewriter`

## 6) Deployment Patterns

### Single binary distribution
- Compile for target OS/arch: `GOOS=linux GOARCH=amd64 go build`
- Use `GoReleaser` for multi-platform builds and releases
- Sign binaries for verification

### Container deployment
- Minimal images: Use Alpine or scratch base
- Multi-stage builds to reduce image size
- Mount secrets from environment, not code

### Version management
- Embed version in binary: `-ldflags "-X main.Version=v1.0.0"`
- Use semantic versioning
- Keep changelog for upgrades

## 7) Common Patterns

### Dry-run mode
```go
if dryRun {
  slog.Info("dry run: would execute command")
  return nil
}
```

### Interactive confirmation
```go
fmt.Printf("Continue? (y/n): ")
scanner := bufio.NewScanner(os.Stdin)
if !scanner.Scan() || scanner.Text() != "y" {
  return errors.New("cancelled")
}
```

### Signal handling
Prefer `signal.NotifyContext` (Go 1.16+): it folds SIGINT/SIGTERM into context cancellation, so the same `ctx` you already thread through the tool drives shutdown. No manual channel or goroutine.
```go
ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
defer stop() // restores default signal handling; a second Ctrl-C then hard-kills

if err := run(ctx); err != nil {
  slog.Error("run failed", "err", err)
  os.Exit(1)
}
```
`run(ctx)` and everything it calls must honor `ctx.Done()`. Reach for the raw `signal.Notify` channel only when you need the specific signal value (e.g. `SIGHUP` to reload config without exiting).

# Decision Tree

## Which CLI framework should I use?
- **Complex, many subcommands?** → Cobra
- **Simple tool, fast startup?** → Urfave/CLI
- **Minimal deps, quick script?** → Flag package

## How should I handle configuration?
- **Simple settings?** → Environment variables
- **Complex config?** → Config file + env overrides
- **Runtime control?** → Flags

## How should I output results?
- **Human-readable?** → Text/table format
- **Parsing by scripts?** → JSON/YAML
- **Data export?** → CSV

# Key Principles

1. **Cloud-native**: Environment variables, stateless, no local state
2. **Minimal dependencies**: Justify external packages
3. **Graceful shutdown**: Handle signals, cancel contexts
4. **Fast startup**: Keep initialization lightweight
5. **Clear output**: Users should understand what happened

# Cross-References

- `go-patterns` — context propagation and cancellation that `signal.NotifyContext` feeds, error-handling idioms for exit paths.
- `go-microservices` — the same `NotifyContext` shutdown pattern applied to long-running HTTP/gRPC servers.
- `go-testing-patterns` — testing CLIs (golden files, `os/exec` integration tests) and mocking cloud SDK clients behind interfaces.
