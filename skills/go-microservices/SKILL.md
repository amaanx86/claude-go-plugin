---
name: go-microservices
description: Building microservices, HTTP APIs, gRPC services, and distributed systems in Go. Covers service patterns, stdlib net/http routing, middleware, error handling, observability, and graceful shutdown.
user-invocable: true
allowed-tools: Read Edit Write Glob Grep Bash(go:*) Bash(golangci-lint:*) Bash(git:*) Agent
---

**Persona:** You are a backend engineer building services that must stay up. Every network call has a timeout, every handler an error contract, and every process drains cleanly on shutdown. You reach for a framework only when the stdlib genuinely falls short.

**Modes:**
- **Build mode** — implementing a new endpoint or service. Define the contract (status codes, error body) first, then handler, middleware, observability.
- **Review mode** — reviewing a diff. Check context timeouts, error-to-status mapping, response-write ordering, middleware ordering, and shutdown handling.
- **Audit mode** — sweeping a service for reliability gaps (missing timeouts, unbounded fan-out, no graceful shutdown, leaking DB errors as 404). Parallelize by concern.

# Purpose

Guide microservices and API development in Go: choosing between HTTP and gRPC, service patterns, middleware design, distributed tracing, and building reliable services.

# When to Use

- Building REST/HTTP APIs
- Building gRPC services
- Designing service interfaces and contracts
- Implementing middleware and interceptors
- Adding observability (tracing, metrics)
- Handling service-to-service communication

<Do_Not_Use_When>
- General Go patterns (use go-patterns skill)
- CLI tools (use go-devops-tools skill)
- Testing services (use go-testing-patterns skill)
</Do_Not_Use_When>

# Workflow

## 1) HTTP vs gRPC Decision

### HTTP/REST
- **Best for**: Browser clients, public APIs, simple integrations
- **Strengths**: Ubiquitous, easy debugging, wide tool support
- **Tradeoffs**: Higher latency, larger payloads, text-based
- **Frameworks**: Gin, Echo, Chi, Fiber

### gRPC
- **Best for**: High-performance inter-service communication
- **Strengths**: Binary protocol, low latency, streaming, code generation
- **Tradeoffs**: Not browser-friendly, requires `.proto` definitions
- **Use when**: Internal APIs, real-time data, large payloads

### Comparison table
| Aspect | HTTP/REST | gRPC |
|--------|-----------|------|
| Latency | Higher | Lower |
| Payload | Larger (JSON) | Smaller (binary) |
| Streaming | Possible | Native |
| Browser | Yes | No (gRPC-web) |
| Debugging | Easy (curl) | Tools needed |

## 2) HTTP API Design

### Start with stdlib net/http (Go 1.22+)
Since Go 1.22, `http.ServeMux` routes on method and path wildcards, which covers most services without a framework. Default here; a framework is a dependency you should be able to justify.
```go
mux := http.NewServeMux()
mux.HandleFunc("GET /users/{id}", handleGetUser)
mux.HandleFunc("POST /users", handleCreateUser)

func handleGetUser(w http.ResponseWriter, r *http.Request) {
  id := r.PathValue("id") // path wildcard, no framework needed
  // ...
}
```
Method-prefixed patterns (`"GET /users/{id}"`) return 405 for the wrong method automatically, and the more specific pattern wins on conflicts. Middleware is a plain `func(http.Handler) http.Handler` chain (see section 4). Reach for a framework when you genuinely need what it adds, not by default.

### Framework selection (when stdlib is not enough)
- **Chi**: Composable, `net/http`-compatible, thinnest step up (route groups, middleware stacks). Preferred when you outgrow `ServeMux` but want to stay close to the stdlib.
- **Gin**: Fast, minimal, mature; large ecosystem.
- **Echo**: Clean API, batteries-included middleware.
- **Fiber**: Express-like, high performance, but built on `fasthttp` (not `net/http`), so stdlib middleware and `http.Handler` do not compose. Choose deliberately.

### Handler pattern
Set `Content-Type` before `WriteHeader`, and encode into a buffer so a marshal failure does not corrupt an already-committed 200 response.
```go
func handleGetUser(w http.ResponseWriter, r *http.Request) {
  userID := chi.URLParam(r, "userID")
  user, err := getUserByID(r.Context(), userID)
  if errors.Is(err, ErrNotFound) {
    respondError(w, http.StatusNotFound, "not_found")
    return
  }
  if err != nil {
    respondError(w, http.StatusInternalServerError, "internal")
    return
  }
  respondJSON(w, http.StatusOK, user)
}

func respondJSON(w http.ResponseWriter, status int, v any) {
  body, err := json.Marshal(v)
  if err != nil {
    http.Error(w, `{"code":"internal"}`, http.StatusInternalServerError)
    return
  }
  w.Header().Set("Content-Type", "application/json")
  w.WriteHeader(status)
  _, _ = w.Write(body)
}
```

### Error responses
```go
type ErrorResponse struct {
  Code    string         `json:"code"`
  Message string         `json:"message"`
  Details map[string]any `json:"details,omitempty"`
}

func respondError(w http.ResponseWriter, code int, apiErr string) {
  // Reuse respondJSON so the buffer-first rule above applies here too.
  respondJSON(w, code, ErrorResponse{
    Code:    apiErr,
    Message: http.StatusText(code),
  })
}
```

### Status codes
- `200 OK`: Success
- `201 Created`: Resource created
- `204 No Content`: Success, no body
- `400 Bad Request`: Invalid input
- `401 Unauthorized`: Missing auth
- `403 Forbidden`: Auth insufficient
- `404 Not Found`: Resource missing
- `409 Conflict`: State conflict
- `500 Internal Server Error`: Server error

## 3) gRPC Services

### Service definition
```protobuf
service UserService {
  rpc GetUser(GetUserRequest) returns (User);
  rpc ListUsers(ListUsersRequest) returns (stream User);
  rpc CreateUser(User) returns (User);
}
```

### Implementation
```go
func (s *Server) GetUser(ctx context.Context, req *pb.GetUserRequest) (*pb.User, error) {
  user, err := s.db.GetUser(ctx, req.UserId)
  if errors.Is(err, ErrNotFound) {
    return nil, status.Error(codes.NotFound, "user not found")
  }
  if err != nil {
    // Do not leak a DB outage to callers as "not found"; distinguish it.
    return nil, status.Error(codes.Internal, "get user")
  }
  return &pb.User{Id: user.ID, Name: user.Name}, nil
}
```

### Error handling
```go
// Return gRPC status errors
return nil, status.Errorf(codes.InvalidArgument, "invalid user id: %s", req.UserId)
return nil, status.Errorf(codes.Internal, "database error")
```

## 4) Middleware & Interceptors

### HTTP middleware
```go
func loggingMiddleware(next http.Handler) http.Handler {
  return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    slog.InfoContext(r.Context(), "request", "method", r.Method, "path", r.URL.Path)
    next.ServeHTTP(w, r)
  })
}

func authMiddleware(next http.Handler) http.Handler {
  return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    if !isAuthenticated(r) {
      http.Error(w, "unauthorized", http.StatusUnauthorized)
      return
    }
    next.ServeHTTP(w, r)
  })
}
```

### gRPC interceptors
```go
func unaryInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
  slog.InfoContext(ctx, "grpc call", "method", info.FullMethod)
  return handler(ctx, req)
}

grpc.NewServer(grpc.UnaryInterceptor(unaryInterceptor))
```

### Chain middleware
```go
// HTTP
router.Use(loggingMiddleware, authMiddleware, recoveryMiddleware)

// gRPC
grpc.NewServer(
  grpc.UnaryInterceptor(chainUnary(logInterceptor, authInterceptor)),
  grpc.StreamInterceptor(chainStream(logInterceptor, authInterceptor)),
)
```

## 5) Service Patterns

### Health checks
```go
type HealthChecker interface {
  Check(ctx context.Context) error
}

// HTTP (net/http; adapt to your router of choice)
func handleHealth(w http.ResponseWriter, r *http.Request) {
  if err := healthChecker.Check(r.Context()); err != nil {
    respondJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unhealthy"})
    return
  }
  respondJSON(w, http.StatusOK, map[string]string{"status": "healthy"})
}
```

### Graceful shutdown
Use `signal.NotifyContext` so SIGINT/SIGTERM cancel a context, then `Shutdown` to drain in-flight requests. Capture both the serve error and the shutdown error; dropping them hides a failed drain.
```go
ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
defer stop()

server := &http.Server{Addr: ":8080", Handler: handler}

go func() {
  if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
    slog.Error("listen", "err", err)
    stop() // unblock main so we exit non-zero
  }
}()

<-ctx.Done() // signal received (or ListenAndServe failed and called stop)

shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
defer cancel()
if err := server.Shutdown(shutdownCtx); err != nil {
  slog.Error("graceful shutdown failed, forcing close", "err", err)
  _ = server.Close()
}
```
`Shutdown` stops accepting new connections and waits for active handlers up to the deadline; past it, `Close` forces the remaining connections shut.

### Request/response validation
```go
type CreateUserRequest struct {
  Name  string `json:"name" validate:"required,min=3"`
  Email string `json:"email" validate:"required,email"`
}

// Validate before processing
if err := validate.Struct(req); err != nil {
  respondError(w, http.StatusBadRequest, "validation_error")
  return
}
```

## 6) Observability

### Structured logging
Default to stdlib `log/slog`. Carry a request-scoped logger on the context so every line in a request shares trace/request IDs; timestamps are added by the handler, do not log them by hand.
```go
slog.InfoContext(ctx, "user logged in",
  "user_id", userID,
  "action", "login",
)
```

### Distributed tracing
```go
import "go.opentelemetry.io/otel/trace"

ctx, span := tracer.Start(ctx, "ProcessUser")
defer span.End()
span.SetAttributes(attribute.String("user_id", userID))
```

### Metrics
```go
import "github.com/prometheus/client_golang/prometheus"

requestsTotal := prometheus.NewCounterVec(
  prometheus.CounterOpts{Name: "http_requests_total"},
  []string{"method", "status"},
)
```

## 7) Service-to-Service Communication

### Patterns
- **Synchronous**: Direct HTTP/gRPC calls
- **Asynchronous**: Message queues (RabbitMQ, Kafka)
- **Event-driven**: Pub/sub (NATS, Redis)

### Resilience
- **Retries**: Exponential backoff, max retries
- **Circuit breaker**: Fail fast if service down
- **Timeouts**: All calls must have timeouts
- **Bulkheads**: Limit concurrent calls per service

### Implementation
```go
// Timeout
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()
result, err := client.CallRemoteService(ctx)

// Retry with exponential backoff + jitter, respecting context.
// time.Sleep ignores cancellation; select on ctx.Done() instead.
var err error
for attempt := 0; attempt < maxRetries; attempt++ {
  if err = callService(ctx); err == nil {
    break
  }
  if !isRetryable(err) { // do not retry 4xx / non-transient errors
    break
  }
  backoff := time.Duration(1<<attempt) * baseDelay
  // rand.Int63n panics on a non-positive argument, so guard the half-window.
  var jitter time.Duration
  if half := int64(backoff / 2); half > 0 {
    jitter = time.Duration(rand.Int63n(half))
  }
  select {
  case <-time.After(backoff + jitter):
  case <-ctx.Done():
    return ctx.Err()
  }
}
// Loop exits on success (err == nil), a non-retryable error, or exhausted
// attempts. Return the final error so it is never silently dropped.
if err != nil {
  return fmt.Errorf("call service: %w", err)
}
return nil
```

# Decision Trees

## Should I use HTTP or gRPC?
- **Public API, browsers, simple?** → HTTP/REST
- **Internal, high performance, streaming?** → gRPC
- **Both?** → gRPC + gRPC-web gateway

## Which HTTP framework?
- **Fast + simple?** → Gin
- **Clean API?** → Echo
- **Composable?** → Chi
- **Express-like?** → Fiber

## How do I handle errors?
- **HTTP**: Return appropriate status codes + error response body
- **gRPC**: Return `status.Error` with codes (Unavailable, InvalidArgument, etc.)

# Key Principles

1. **Always use context**: Timeouts, cancellation, propagation
2. **Middleware/interceptors**: Cross-cutting concerns (logging, auth, tracing)
3. **Graceful shutdown**: Clean connection draining
4. **Health checks**: Readiness and liveness probes
5. **Observability**: Logs, traces, metrics by default
6. **Error as value**: Handle errors explicitly
7. **Resiliency**: Timeouts, retries, circuit breakers

# Cross-References

- `go-patterns` — the error-handling (`errors.Is`/`errors.As`), context, and concurrency idioms these handlers rely on.
- `go-devops-tools` — `signal.NotifyContext` shutdown, structured logging with `slog`, config precedence shared with services.
- `go-testing-patterns` — `httptest` handler tests, gRPC service tests, mocking dependencies behind interfaces.
