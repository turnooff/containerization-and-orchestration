package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"lab3/internal/db"
	"lab3/internal/health"
)

type Order struct {
	ID          int64      `json:"id"`
	Customer    string     `json:"customer"`
	Item        string     `json:"item"`
	Status      string     `json:"status"`
	CreatedAt   time.Time  `json:"created_at"`
	ProcessedAt *time.Time `json:"processed_at,omitempty"`
}

type API struct {
	pool *pgxpool.Pool
}

var (
	httpRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "shop",
		Subsystem: "api",
		Name:      "http_requests_total",
		Help:      "HTTP requests by path, method, status code",
	}, []string{"path", "method", "status"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "shop",
		Subsystem: "api",
		Name:      "http_request_duration_seconds",
		Help:      "HTTP request duration in seconds",
		Buckets:   []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
	}, []string{"path", "method"})
)

// responseWriter перехватывает HTTP-статус, чтобы записать его в метрику.
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)

		dur := time.Since(start).Seconds()
		path := r.URL.Path
		httpRequestsTotal.WithLabelValues(path, r.Method, strconv.Itoa(rw.status)).Inc()
		httpRequestDuration.WithLabelValues(path, r.Method).Observe(dur)
	})
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := db.Connect(ctx, db.DSN())
	if err != nil {
		log.Fatalf("api: %v", err)
	}
	defer pool.Close()

	if err := db.EnsureSchema(ctx, pool); err != nil {
		log.Fatalf("api: %v", err)
	}

	api := &API{pool: pool}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", health.Handler())
	mux.HandleFunc("POST /order", api.createOrder)
	mux.HandleFunc("GET /orders", api.listOrders)
	mux.Handle("GET /metrics", promhttp.Handler())
	mux.HandleFunc("GET /fail", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusInternalServerError, "test error")
	})
	mux.HandleFunc("GET /slow", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(800 * time.Millisecond)
		writeJSON(w, http.StatusOK, map[string]string{"status": "slow ok"})
	})

	addr := ":" + getenv("PORT", "8080")
	srv := &http.Server{
		Addr:              addr,
		Handler:           metricsMiddleware(logRequests(mux)),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("api: listening on %s", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("api: %v", err)
		}
	}()

	<-ctx.Done()
	log.Print("api: draining (5s for endpoints propagation)")
	// kube-proxy успевает обновить iptables и убрать нас из Endpoints,
	// прежде чем мы закроем listener. Это закрывает гонку на SIGTERM,
	// из-за которой часть in-flight запросов получала connection refused.
	time.Sleep(5 * time.Second)
	log.Print("api: shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}

func (a *API) createOrder(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Customer string `json:"customer"`
		Item     string `json:"item"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.Customer == "" || req.Item == "" {
		writeError(w, http.StatusBadRequest, "fields 'customer' and 'item' are required")
		return
	}

	var o Order
	err := a.pool.QueryRow(r.Context(),
		`INSERT INTO orders (customer, item)
		 VALUES ($1, $2)
		 RETURNING id, customer, item, status, created_at, processed_at`,
		req.Customer, req.Item,
	).Scan(&o.ID, &o.Customer, &o.Item, &o.Status, &o.CreatedAt, &o.ProcessedAt)
	if err != nil {
		log.Printf("api: insert order: %v", err)
		writeError(w, http.StatusInternalServerError, "cannot create order")
		return
	}

	writeJSON(w, http.StatusCreated, o)
}

func (a *API) listOrders(w http.ResponseWriter, r *http.Request) {
	rows, err := a.pool.Query(r.Context(),
		`SELECT id, customer, item, status, created_at, processed_at
		 FROM orders
		 ORDER BY id DESC
		 LIMIT 100`)
	if err != nil {
		log.Printf("api: select orders: %v", err)
		writeError(w, http.StatusInternalServerError, "cannot read orders")
		return
	}
	defer rows.Close()

	orders := make([]Order, 0, 16)
	for rows.Next() {
		var o Order
		if err := rows.Scan(&o.ID, &o.Customer, &o.Item, &o.Status, &o.CreatedAt, &o.ProcessedAt); err != nil {
			log.Printf("api: scan order: %v", err)
			writeError(w, http.StatusInternalServerError, "cannot read orders")
			return
		}
		orders = append(orders, o)
	}
	if err := rows.Err(); err != nil {
		log.Printf("api: iterate orders: %v", err)
		writeError(w, http.StatusInternalServerError, "cannot read orders")
		return
	}

	writeJSON(w, http.StatusOK, orders)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("api: encode response: %v", err)
	}
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
