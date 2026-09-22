package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

var (
	requests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Total HTTP requests",
	}, []string{"method", "path", "status"})

	errorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_errors_total",
		Help: "Total HTTP 5xx responses",
	}, []string{"method", "path"})

	duration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request duration in seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})
)

// logJSON пишет структурированный лог в stdout, добавляя trace_id текущего спана.
func logJSON(ctx context.Context, level, msg string, extra map[string]any) {
	entry := map[string]any{
		"ts":    time.Now().UTC().Format(time.RFC3339Nano),
		"level": level,
		"msg":   msg,
	}
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		entry["trace_id"] = sc.TraceID().String()
		entry["span_id"] = sc.SpanID().String()
	}
	for k, v := range extra {
		entry[k] = v
	}
	b, _ := json.Marshal(entry)
	fmt.Fprintln(os.Stdout, string(b))
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	logJSON(r.Context(), "info", "health ok", nil)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func handleFail(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	span := trace.SpanFromContext(ctx)
	span.SetStatus(codes.Error, "simulated failure")
	span.SetAttributes() // no-op, оставлено для наглядности
	logJSON(ctx, "error", "simulated failure", map[string]any{"code": 500})
	http.Error(w, "internal error", http.StatusInternalServerError)
}

func handleSlow(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tracer := otel.Tracer("api")
	_, span := tracer.Start(ctx, "slow-op")
	defer span.End()

	d := time.Duration(1000+rand.Intn(2000)) * time.Millisecond
	time.Sleep(d)
	span.SetAttributes()
	logJSON(ctx, "info", "slow op finished", map[string]any{"duration_ms": d.Milliseconds()})

	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("done\n"))
}

func handleLoad(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tracer := otel.Tracer("api")
	_, span := tracer.Start(ctx, "load-op")
	defer span.End()

	base := os.Getenv("SELF_URL")
	if base == "" {
		base = "http://localhost:8080"
	}
	n := 20
	client := &http.Client{Timeout: 10 * time.Second}
	for i := 0; i < n; i++ {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+"/health", nil)
		resp, err := client.Do(req)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
		}
	}
	logJSON(ctx, "info", "load fired", map[string]any{"count": n, "target": base})

	w.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprintf(w, "fired %d requests to %s\n", n, base)
}

// statusRecorder — маленький враппер, чтобы знать код ответа для метрик.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// metricsMiddleware считает RED: rate/errors/duration для всех путей, кроме /metrics.
func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/metrics" {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		elapsed := time.Since(start).Seconds()

		path := r.URL.Path
		requests.WithLabelValues(r.Method, path, fmt.Sprintf("%d", rec.status)).Inc()
		duration.WithLabelValues(r.Method, path).Observe(elapsed)
		if rec.status >= 500 {
			errorsTotal.WithLabelValues(r.Method, path).Inc()
		}
	})
}

func initTracer(ctx context.Context) (*sdktrace.TracerProvider, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		endpoint = "jaeger-collector.observability.svc.cluster.local:4317"
	}
	exp, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(endpoint),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(resource.Default()), // service.name берётся из OTEL_SERVICE_NAME
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	return tp, nil
}

func main() {
	ctx := context.Background()
	tp, err := initTracer(ctx)
	if err != nil {
		log.Printf("tracer init failed (will run without traces): %v", err)
	} else {
		defer func() { _ = tp.Shutdown(context.Background()) }()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/fail", handleFail)
	mux.HandleFunc("/slow", handleSlow)
	mux.HandleFunc("/load", handleLoad)
	mux.Handle("/metrics", promhttp.Handler())

	// otelhttp создаёт корневой спан на каждый входящий запрос и кладёт его в context.
	handler := metricsMiddleware(otelhttp.NewHandler(mux, "http.server"))

	addr := ":8080"
	log.Printf("listening on %s", addr)
	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatal(err)
	}
}
