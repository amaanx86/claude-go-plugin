---
name: go-patterns
description: Go development fundamentals covering goroutines, channels, error handling, interfaces, generics, struct composition, concurrency patterns, context, and idiomatic Go style. Teaches thinking, not copying.
user-invocable: true
allowed-tools: Read Edit Write Glob Grep Bash(go:*) Bash(golangci-lint:*) Bash(git:*) Agent
---

**Persona:** You are a Go engineer who writes for the next reader. You reach for the simplest construct that models the problem and treat readability as the primary constraint.

**Modes:**
- **Build mode** — writing new Go. Apply the idioms below as you go; keep diffs minimal and patch-friendly.
- **Review mode** — reviewing a diff. Focus on the changed lines: error handling, concurrency safety, interface placement, allocation, naming.
- **Audit mode** — sweeping an existing package for pattern violations (goroutine leaks, junk-drawer packages, stuttering names, package-level mutable state). Split across parallel sub-agents by concern when the surface is large.

# Purpose

Guide Go development decisions: leveraging goroutines and channels, idiomatic error handling, interface design, struct composition, concurrency patterns, and Go's philosophy. Focus on decision-making principles rather than cookbook recipes.

# When to Use

- Starting a new Go project and choosing architecture
- Working with goroutines and channels
- Implementing error handling strategies
- Designing interfaces and abstractions
- Building reusable packages and libraries
- Leveraging Go's concurrency model
- Following Go idioms and best practices

<Do_Not_Use_When>
- Building CLI tools (use go-devops-tools skill)
- Building microservices or HTTP APIs (use go-microservices skill)
- Building gRPC services (use go-microservices skill)
- Writing tests (use go-testing-patterns skill)
</Do_Not_Use_When>

# Workflow

## 1) Goroutines & Concurrency Patterns

### When to use goroutines
- **Background tasks**: Fire-and-forget work (logging, cleanup)
- **Parallel processing**: CPU-bound or I/O-bound operations
- **Event handling**: Responsive systems with independent tasks
- **Server handlers**: Each request in its own goroutine

### Common patterns
- **Worker pool**: Fixed number of goroutines processing work from a channel
- **Fan-out/fan-in**: Distribute work, collect results
- **Throttle**: Limit concurrent operations with semaphore (buffered channel)
- **Timeout**: Use `context.WithTimeout()` for deadline enforcement

### Anti-patterns to avoid
- Unbounded goroutine creation (can exhaust memory)
- Missing goroutine cancellation (goroutine leaks)
- Assuming goroutine startup order
- Race conditions (concurrent map/slice access without synchronization)

## 2) Channels & Synchronization

### Channel types
- **Unbuffered**: Synchronous, sender blocks until receiver ready
- **Buffered**: Asynchronous up to capacity, then blocks
- **Directional**: `chan<- T` (send only), `<-chan T` (receive only)

### Patterns
- **Pipeline**: Chain processing stages via channels
- **Multiplexing**: Merge multiple channels with `select`
- **Broadcast**: Fan-out results to multiple consumers
- **Backpressure**: Throttle producers with buffering

### When NOT to use channels
- Simple synchronization: use `sync.WaitGroup` or `sync.Mutex`
- One-time signaling: use `context.Context` or `chan struct{}`
- Message passing with response: consider return values or callbacks first

## 3) Error Handling

### Go's error philosophy
- Errors are values: `if err != nil { return err }`
- Explicit over implicit: handle each error decision.
- Handle an error only **once**: log it, or wrap and return it, but not both. Logging then returning duplicates the report up the stack (Uber).

### Error strings
- Lowercase, no trailing punctuation, so they read well when wrapped: `"open config: %w"`, not `"Failed to open config."` (Google Go Style: error strings are not capitalized and do not end with punctuation).
- Do not prefix with `failed to` / `error while` / `unable to`. Those phrases stack into `failed to X: failed to Y: failed to Z` once wrapped. State what you were doing: `errors.Wrap(err, "read block index")` (Thanos).

### Wrap vs obscure
- `fmt.Errorf("read index: %w", err)` exposes the wrapped error so callers can match it with `errors.Is` / `errors.As`. This is the default (Uber).
- Use `%v` only when you deliberately want to break the chain and hide the underlying error from callers (an implementation detail you do not want to become part of your API contract).

### Inspecting errors (never type-assert a wrapped error)
- Match a sentinel: `if errors.Is(err, ErrNotFound)`, not `err == ErrNotFound` (breaks the moment it is wrapped).
- Extract a typed error: `var perr *PathError; if errors.As(err, &perr)`, not `err.(*PathError)`.

### Patterns
- **Early return**: fail fast, handle the error case first, avoid nested `else` (Uber, Thanos).
- **Sentinel errors**: `var ErrNotFound = errors.New("not found")` for a static, matchable condition.
- **Custom error types**: implement `error` when the caller must match a *dynamic* message; a plain `fmt.Errorf` suffices when the caller does not need to match it (Uber).
- **Deferred close errors**: a `Close()` that flushes can fail; capture it instead of dropping it. `defer runutil.CloseWithErrCapture(&err, f, "close file")` (Thanos), or a named-return `defer func() { err = errors.Join(err, f.Close()) }()`.
- **Explicit ignore**: if you truly discard an error, say so: `_ = w.Flush()`. Never silently drop it.

## 4) Interfaces & Composition

### Interface design
- **Small interfaces**: 1-3 methods (e.g., `io.Reader`, `io.Writer`). Thanos: "expose at max 1-3 methods if possible."
- **Define at the consumer, not the producer**: the package that *uses* an abstraction declares the interface it needs; the implementing package returns a concrete type. Do not pre-declare an interface that has one implementation.
- **Composition over inheritance**: embed structs, not inherit.
- **Accept interfaces, return structs**: flexible inputs, concrete outputs.
- **Verify compliance at compile time**: `var _ http.Handler = (*Handler)(nil)` fails to build the instant the type stops satisfying the interface (Uber).
- **Prefer `any` over `interface{}`**: since Go 1.18 `any` is the alias; `gofmt` and gopls rewrite to it. Reach for generics before an untyped `any` when the shape is known.

### Common interfaces
- `io.Reader` / `io.Writer`: Fundamental I/O abstraction
- `error`: Single method `Error() string`
- `fmt.Stringer`: `String() string` for custom printing
- `context.Context`: Cancellation, deadlines, values

### Generics (Go 1.18+)
- Reach for a type parameter only when you would otherwise write the *same* body for several concrete types (a container, or an algorithm over a comparable/ordered element). If the bodies differ per type, you want an interface, not a generic.
- Constrain with the narrowest set the body actually needs. Use `comparable` for map keys and `==`, and `golang.org/x/exp/constraints` (or a hand-written union like `~int | ~float64`) for ordered arithmetic. Do not default to `any` and then type-assert inside; that defeats the point.
- Prefer the stdlib generic helpers over rolling your own: `slices` (`Sort`, `Contains`, `IndexFunc`, `SortFunc`), `maps` (`Keys`, `Values`, `Clone`), and `cmp` (`Ordered`, `Compare`, `Or`).
- Do not parameterize a function whose only type argument appears once and could be an interface. "Just use an interface" is the right answer more often than generics newcomers expect (Google, Go team guidance).

## 5) Package Structure & Imports

### Package design
- **Single responsibility**: one package, one clear purpose.
- **Name describes contents**: `package http`, `package storage`. Lowercase, no underscores or dashes; the `package foo` line matches its directory name (Kubernetes).
- **No junk-drawer packages**: avoid `util`, `common`, `helpers`, `model`, `base`, `misc`. They attract unrelated code and force callers to rename on import (Google). Name the package for what it does: `retry`, `iprange`, `tokenbucket`.
- **Avoid stutter**: the package qualifies the name, so `storage.Interface`, not `storage.StorageInterface`; `chunk.NewReader`, not `chunk.NewChunkReader` (Kubernetes, Google).
- **Exported vs unexported**: `PascalCase` exported, `camelCase` unexported.
- **Avoid circular dependencies**: break cycles with a consumer-side interface.
- **No package-level mutable state**: Thanos bans globals other than `const` and forbids `init()`; pass dependencies explicitly instead.

### Layout
Tests live next to the code they exercise as `*_test.go`; there is no top-level `tests/` directory. `pkg/` is optional and often unnecessary for an application; put reusable, importable libraries under it only when you actually publish them, and give them real names (not `utils`/`types`).
```
myproject/
  go.mod
  cmd/
    app/
      main.go          // thin entrypoint; wire dependencies, call into internal
  internal/            // not importable by other modules
    config/
    storage/
      storage.go
      storage_test.go
    service/
```

## 6) Concurrency Patterns Deep Dive

### Worker Pool
```go
// Distribute work to N workers
workers := 4
jobs := make(chan Job)
results := make(chan Result)

for i := 0; i < workers; i++ {
  go worker(jobs, results)
}
```

### Throttle + error propagation (errgroup)
Prefer `errgroup.Group` with `SetLimit` over a hand-rolled semaphore: it bounds concurrency, propagates the first error, and cancels the shared context. Go 1.22+ scopes the loop variable per iteration, so no `item := item` shim is needed.
```go
g, ctx := errgroup.WithContext(ctx)
g.SetLimit(5) // at most 5 in flight
for _, item := range items {
  g.Go(func() error {
    return process(ctx, item)
  })
}
if err := g.Wait(); err != nil {
  return fmt.Errorf("process items: %w", err)
}
```
A raw buffered channel (`make(chan struct{}, 5)`, acquire on send, release on receive) is fine when you do not need error aggregation.

### Context Cancellation
```go
// Every goroutine must respect ctx.Done()
go func(ctx context.Context) {
  select {
  case <-ctx.Done():
    return
  case result := <-ch:
    process(result)
  }
}(ctx)
```

### Context: propagation, deadlines, values
- `context.Context` is the first parameter of any function that does I/O, blocks, or spawns work, named `ctx`. Never store it in a struct; thread it through calls.
- Derive, do not mint: pass the incoming `ctx` down and wrap it (`context.WithTimeout`, `WithCancel`, `WithDeadline`). Reserve `context.Background()` for `main`, tests, and top-level init; use `t.Context()` inside tests (Go 1.24+).
- Always call the returned `cancel`, even on the timeout path: `ctx, cancel := context.WithTimeout(ctx, d); defer cancel()`. Leaking a cancel func leaks the timer and its goroutine (`go vet`'s `lostcancel` catches the obvious cases).
- `context.WithValue` is for request-scoped data that crosses API boundaries (request ID, auth principal, trace span), keyed by an unexported package-local type to avoid collisions. It is not a substitute for explicit function parameters; do not pass optional config through it.

## 7) Naming & Idioms (Google + Uber + k8s)

- **MixedCaps, never underscores**: `maxRetries`, `ErrNotFound`, `HTTPClient`. Underscores appear only in `*_test.go` function names.
- **Initialisms keep case**: `userID`, `apiURL`, `parseJSON`, `HTTPServer` (not `UserId`, `ApiUrl`).
- **No `Get` prefix on getters**: `u.Name()`, not `u.GetName()` (Google). `Get` is reserved for cases where the domain literally says get (HTTP GET).
- **Receiver names**: one or two letters, an abbreviation of the type, identical on every method of that type. `func (s *Server)`, never `func (this *Server)` or `func (self *Server)`; omit the name if unused.
- **`context.Context` is the first parameter**, named `ctx`; do not store it in a struct.
- **No naked returns** with named result parameters. Name results only to document intent or to set them in a deferred close; still `return x, err` explicitly (Uber, Thanos).
- **Avoid shadowing**, especially `err`. Scope short-lived errors in the `if`: `if err := do(); err != nil { ... }` (Thanos).
- **Do not panic** in library or request-handling code; return an error. Panic only for truly unrecoverable startup invariants, and `recover` at goroutine boundaries if a dependency may panic (Uber, Thanos).

## 8) Allocation Hygiene

- Give `make` a capacity hint when you know the size: `make([]T, 0, len(src))`, `make(map[string]struct{}, len(src))`. Avoids repeated grow-and-copy (Uber, Thanos).
- Reuse a backing array in hot loops with `s = s[:0]` instead of reallocating `s = nil` / `[]T{}` each iteration (Thanos).
- Measure before optimizing; see the benchmarking section of the go-testing-patterns skill.

# Decision Trees

## Should I use goroutines?
- **Yes** if: Independent work, I/O-bound, need parallelism
- **No** if: Sequential processing, simple sync logic, overhead not justified

## Should I use channels?
- **Yes** if: Passing values between goroutines, pipeline stages, synchronization
- **No** if: Simple sync (use `sync.Mutex`), variable sharing in single goroutine

## Should I define an interface?
- **Yes** if: Multiple implementations, need abstraction, reduce coupling
- **No** if: Single concrete type, interface not called by other packages

# Key Principles

1. **Errors are values**: Don't panic; return errors explicitly.
2. **Composition > Inheritance**: Embed types; don't inherit hierarchies.
3. **Interfaces for abstraction**: Not data hiding; enable different implementations.
4. **Concurrency primitives**: goroutines + channels + `context` model most patterns.
5. **Idiomatic Go**: Follow language conventions; readability is paramount.

# Cross-References

- `go-testing-patterns` — race detector, goleak for the goroutine leaks flagged above, benchmarking allocation-hygiene claims.
- `go-devops-tools` — CLI structure, `signal.NotifyContext` for the cancellation patterns here.
- `go-microservices` — how these concurrency/context/error idioms apply to HTTP and gRPC handlers.
