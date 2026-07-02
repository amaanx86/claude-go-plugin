---
name: go-testing-patterns
description: Go testing strategies covering unit tests, table-driven tests, mocking, integration tests, benchmarking, goroutine-leak detection, deterministic concurrency testing, and test organization. Focus on correctness and confidence.
user-invocable: true
allowed-tools: Read Edit Write Glob Grep Bash(go:*) Bash(golangci-lint:*) Bash(git:*) Agent
---

**Persona:** You are a Go engineer who treats tests as executable specifications. You constrain behavior, not chase coverage numbers, and you never ship a flaky test.

**Modes:**
- **Write mode** — generating tests for existing or new code. Work through the code under test; build table-driven cases, then enrich with edge and error paths.
- **Review mode** — reviewing a diff's test changes. Check coverage of new behavior, assertion quality, missing `t.Parallel()`, and flakiness patterns (real time, order dependence).
- **Audit mode** — sweeping a suite for gaps: unit coverage, integration isolation and build tags, goroutine leaks and races. Split across parallel sub-agents by concern for large suites.

# Purpose

Guide Go testing decisions: choosing test types, table-driven testing patterns, mocking strategies, test organization, and achieving confidence in correctness without excessive testing overhead.

# When to Use

- Writing unit tests for functions and packages
- Designing integration tests for I/O boundaries
- Mocking external dependencies
- Benchmarking performance-critical code
- Testing concurrent code and goroutine safety
- Organizing test suites for maintainability

<Do_Not_Use_When>
- General Go patterns (use go-patterns skill)
- Building test tools/frameworks (architectural decision)
- End-to-end testing (outside scope of unit/integration tests)
</Do_Not_Use_When>

# Framework: stdlib default, Ginkgo when the project already commits to it

Default to the standard library `testing` package with table-driven tests and
`cmp.Diff` for comparisons. This matches the Google, Uber, and Thanos
conventions this plugin is grounded in, and keeps tests readable to any Go
developer without a DSL to learn.

Before writing tests, detect the framework already in use: check `go.mod` for
`github.com/onsi/ginkgo` and `github.com/onsi/gomega`. Ginkgo/Gomega is the
ecosystem norm for controller-runtime / kubebuilder operators, where `envtest`
suites are scaffolded as Ginkgo `Describe`/`It` blocks. When the project uses
Ginkgo:

- Do not hand-roll BDD guidance or convert existing suites to stdlib. Match the
  suite's existing Ginkgo idioms (`Describe`/`Context`/`It`, `BeforeEach`,
  `Eventually`/`Consistently`, `DescribeTable`).
- Defer to the official `ginkgo:*` skills (the maintainer-authored Ginkgo plugin)
  when they are installed; they are the authoritative, version-tracked source.
  If they are not installed, suggest installing that plugin rather than
  reproducing Ginkgo documentation here.

Do not introduce Ginkgo into a project that does not already use it; stdlib is
the default for new code.

# Workflow

## 1) Test Types & Risk-Based Testing

### Unit tests (low risk)
- **What**: Test pure functions with no I/O
- **How**: `func TestFunctionName(t *testing.T)`
- **When**: Every exported function, business logic
- **Effort**: Low, fast, reliable
- **Example**: Math functions, string parsing, validation logic

### Integration tests (medium risk)
- **What**: Test components together (DB queries, HTTP calls)
- **How**: Setup test database, mock external services
- **When**: API handlers, database operations, service interactions
- **Effort**: Medium, slower, more setup
- **Example**: Saving to DB, making external API calls

### End-to-end tests (high risk)
- **What**: Test entire system with real dependencies
- **How**: Docker containers, test databases, real services
- **When**: Critical paths only (not all scenarios)
- **Effort**: High, very slow, flaky if not careful
- **Example**: Full user journey, deployment verification

### Risk-based strategy
```
High business risk → More tests, especially integration
Medium risk → Unit + sample integration tests
Low risk → Unit tests only (utilities, helpers)
```

## 2) Table-Driven Testing

### Pattern
```go
func TestParse(t *testing.T) {
  t.Parallel()
  tests := []struct {
    name    string
    input   string
    want    Config      // concrete type, not interface{}
    wantErr error       // sentinel to match with errors.Is, or nil
  }{
    {name: "valid input", input: "foo", want: Config{Name: "foo"}},
    {name: "empty input", input: "", wantErr: ErrEmpty},
  }

  for _, tt := range tests {
    t.Run(tt.name, func(t *testing.T) {
      t.Parallel()
      got, err := Parse(tt.input)
      if !errors.Is(err, tt.wantErr) {
        t.Fatalf("Parse(%q) error = %v, want %v", tt.input, err, tt.wantErr)
      }
      if diff := cmp.Diff(tt.want, got); diff != "" {
        t.Errorf("Parse(%q) mismatch (-want +got):\n%s", tt.input, diff)
      }
    })
  }
}
```
Notes:
- Use `github.com/google/go-cmp/cmp` (with `cmpopts` for tolerances or ignoring fields, and `cmp.AllowUnexported` for unexported fields) to compare structs; `==` and `reflect.DeepEqual` give useless failure output. Diff-based messages are Google's house style.
- Match errors with `errors.Is` against a sentinel, not a `wantErr bool`, so you assert *which* error, not just that one occurred.
- On Go < 1.22, redeclare `tt := tt` before `t.Parallel()`; from 1.22 the loop variable is per-iteration and the shim is unnecessary.

### Advantages
- Single test logic, multiple cases
- Easy to add edge cases
- Clear what each case tests
- Parallel-friendly with `t.Run`

### When to use
- Functions with multiple input scenarios
- Edge cases and error conditions
- Parameterized testing

## 3) Mocking & Interfaces

### Interface-based mocking
```go
// Define interface for dependency
type Storage interface {
  Get(ctx context.Context, key string) (string, error)
}

// Implement mock
type MockStorage struct {
  GetFunc func(ctx context.Context, key string) (string, error)
}
func (m *MockStorage) Get(ctx context.Context, key string) (string, error) {
  return m.GetFunc(ctx, key)
}

// Use in test
func TestService(t *testing.T) {
  mock := &MockStorage{
    GetFunc: func(ctx context.Context, key string) (string, error) {
      return "value", nil
    },
  }
  svc := NewService(mock)
  // Test svc
}
```

### Mocking libraries
- **testify/mock**: structured mocking with expectations
- **mockgen** (`go.uber.org/mock`): generate mocks from interfaces

Assertion helpers are a separate category, not mocks: `testify/require`/`assert` and `github.com/matryer/is` give fluent checks, but stdlib `if got != want` plus `cmp.Diff` stays the default here.

### When NOT to mock
- Testing concrete types (use real implementations)
- Testing implementation details (test behavior, not structure)
- Over-mocking (leads to brittle tests)

## 4) Testing Concurrency

### Race detector
```bash
go test -race ./...
```
Detects data races during test execution.

### Patterns
```go
// Test goroutine safety
func TestConcurrentAccess(t *testing.T) {
  var wg sync.WaitGroup
  m := NewMap()

  for i := 0; i < 10; i++ {
    wg.Add(1)
    go func(id int) {
      defer wg.Done()
      m.Set(fmt.Sprintf("key-%d", id), id)
    }(i)
  }

  wg.Wait()
  if m.Len() != 10 {
    t.Errorf("expected 10 items, got %d", m.Len())
  }
}
```

### Context cancellation testing
Use `t.Context()` (Go 1.24+) instead of `context.Background()`; it is cancelled automatically when the test ends, so a hung goroutine cannot outlive the test.
```go
func TestCancellation(t *testing.T) {
  ctx, cancel := context.WithCancel(t.Context())
  done := make(chan error)

  go func() {
    done <- LongRunningOperation(ctx)
  }()

  cancel()

  select {
  case err := <-done:
    if !errors.Is(err, context.Canceled) {
      t.Errorf("expected context.Canceled, got %v", err)
    }
  case <-time.After(time.Second):
    t.Error("operation did not respect cancellation")
  }
}
```

### Goroutine-leak detection with goleak
A test that only asserts "the work finished" will pass while `Stop()`/`Close()` silently leaks the goroutines it was supposed to reap. `go.uber.org/goleak` fails the test if any unexpected goroutine is still running at the end. Add it to any package that spawns goroutines (worker pools, background loops, watchers).
```go
// Package-wide: one TestMain guards every test in the package.
func TestMain(m *testing.M) {
  goleak.VerifyTestMain(m)
}

// Or per-test, when only some tests spawn goroutines:
func TestWorkerPool(t *testing.T) {
  defer goleak.VerifyNone(t)
  // ... start pool, submit work, Stop() ...
}
```
Ignore known library goroutines explicitly (`goleak.IgnoreTopFunction("...")`) rather than dropping the check.

### Deterministic concurrency with testing/synctest (Go 1.25+)
Tests that use real `time.Sleep`/`time.After`/tickers are slow and flaky. `testing/synctest` runs the body in a bubble where synthetic time only advances once every goroutine is blocked, making timeouts and ordering deterministic and instant.
```go
func TestContextTimeout(t *testing.T) {
  synctest.Test(t, func(t *testing.T) {
    ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
    defer cancel()

    time.Sleep(5*time.Second - time.Nanosecond)
    synctest.Wait() // let blocked goroutines settle
    if err := ctx.Err(); err != nil {
      t.Fatalf("before timeout: %v", err)
    }

    time.Sleep(time.Nanosecond)
    synctest.Wait()
    if !errors.Is(ctx.Err(), context.DeadlineExceeded) {
      t.Fatalf("after timeout: got %v, want DeadlineExceeded", ctx.Err())
    }
  })
}
```
Use `synctest.Test` on Go 1.25+. The Go 1.24 experimental `synctest.Run` (behind `GOEXPERIMENT=synctest`) is a compatibility fallback only for modules pinned to 1.24.

## 5) Benchmarking

### Basic benchmark
```go
func BenchmarkParseJSON(b *testing.B) {
  data := []byte(`{"name":"test"}`)
  var out map[string]any

  // Go 1.24+: b.Loop() runs the body b.N times, excludes the setup above
  // it from the timer, and keeps the body from being optimized away.
  for b.Loop() {
    _ = json.Unmarshal(data, &out)
  }
}

// Pre-1.24 form:
//   b.ResetTimer()
//   for i := 0; i < b.N; i++ { ... }
```

### Run benchmarks
```bash
go test -bench=. -benchmem ./...
go test -bench=. -cpu=1,2,4 ./...      # GOMAXPROCS values (flag is -cpu, not -benchcpu)
go test -bench=. -benchtime=10s ./...
go test -bench=. -count=10 ./...       # repeat for benchstat
```

### Best practices
- Benchmark realistic scenarios; store results in a package-level or escaping variable so the compiler cannot dead-code-eliminate the work.
- Use `b.ReportAllocs()` (or the global `-benchmem`) to track allocations.
- Compare with `benchstat`: `go test -bench=. -count=10 | tee new.txt`, then `benchstat old.txt new.txt`. Raw `tee` alone gives you no significance test.
- Profile with `-cpuprofile`, `-memprofile`.

## 6) Test Organization

### Layout
```
myproject/
  internal/
    storage/
      storage.go
      storage_test.go      // unit tests (same package, or storage_test for blackbox)
      integration_test.go  // integration tests, build-tagged
```

### Naming conventions
- `TestFunctionName` for unit tests
- `TestIntegration*` for integration tests
- `BenchmarkFunctionName` for benchmarks
- `Example*` for example tests (show usage)

### Test package name
- `package storage_test` - Blackbox testing (tests public API)
- `package storage` - Whitebox testing (tests internal functions)

## 7) Setup & Teardown

### Helpers register their own cleanup
Call `t.Helper()` so failures point at the caller's line, and `t.Cleanup()` so the helper owns teardown (no `func()` for every caller to remember to defer). Cleanups run in LIFO order, after the test and its subtests.
```go
func newTestDB(t *testing.T) *sql.DB {
  t.Helper()
  db, err := sql.Open("postgres", "postgres://...")
  if err != nil {
    t.Fatalf("open test db: %v", err)
  }
  t.Cleanup(func() { db.Close() })
  return db
}

func TestQuery(t *testing.T) {
  db := newTestDB(t)
  // Test code; teardown is automatic.
}
```

### Inject the clock; never test against the wall
Real time makes tests flaky. Inject `now func() time.Time` (or a fake clock) so time is deterministic (Thanos).
```go
type Service struct {
  now func() time.Time // defaults to time.Now in production
}
```

### TestMain for global setup
```go
func TestMain(m *testing.M) {
  // Setup
  code := m.Run()
  // Teardown
  os.Exit(code)
}
```

# Decision Trees

## What type of test should I write?
- **Pure function, no I/O?** → Unit test
- **Calls database/API?** → Integration test
- **Entire user flow?** → E2E test (sparingly)

## Should I mock this?
- **Dependency is interface?** → Consider mocking
- **Concrete type?** → Use real implementation or integration test
- **External service?** → Mock or use test double

## How much test coverage is enough?
- **Critical path**: 80%+ coverage
- **Business logic**: 70%+ coverage
- **Utilities**: 50%+ coverage
- **Don't chase 100%**: Diminishing returns

# Key Principles

1. **Test behavior, not implementation**: Changes shouldn't break tests
2. **Risk-based testing**: More tests for high-risk code
3. **Table-driven tests**: Scalable, maintainable test cases
4. **Mock external dependencies**: Speed, reliability, isolation
5. **Integration tests at boundaries**: DB, API, external services
6. **Concurrency testing**: Always use race detector
7. **Benchmarks for performance**: Measure before optimizing

# Cross-References

- `go-patterns` — the concurrency and context idioms these tests exercise (goleak targets the leaks that skill warns about).
- `go-microservices` — `httptest` handler tests, gRPC service tests at the boundary.
- Ginkgo plugin (`ginkgo:*`) — when a project already commits to Ginkgo/Gomega (kubebuilder / controller-runtime `envtest`), defer to those skills instead of stdlib patterns here.
