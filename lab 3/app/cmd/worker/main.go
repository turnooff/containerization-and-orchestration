package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"lab3/internal/db"
	"lab3/internal/health"
)

// claimBatch одним запросом забирает пачку заказов и помечает их обработанными.
// FOR UPDATE SKIP LOCKED — чтобы несколько реплик worker'а не хватались за одни
// и те же строки и не блокировали друг друга.
const claimBatch = `
WITH batch AS (
    SELECT id
    FROM orders
    WHERE status = 'new'
    ORDER BY id
    FOR UPDATE SKIP LOCKED
    LIMIT $1
)
UPDATE orders o
SET status = 'processed', processed_at = now()
FROM batch
WHERE o.id = batch.id
RETURNING o.id`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := db.Connect(ctx, db.DSN())
	if err != nil {
		log.Fatalf("worker: %v", err)
	}
	defer pool.Close()

	// Схему создаёт api. Если worker стартовал раньше — запросы будут падать,
	// это нормально: цикл просто повторит попытку на следующем тике.
	interval := getenvDuration("POLL_INTERVAL", 2*time.Second)
	batchSize := getenvInt("BATCH_SIZE", 20)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", health.Handler())

	addr := ":" + getenv("PORT", "8080")
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		log.Printf("worker: health on %s", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("worker: health server: %v", err)
		}
	}()

	log.Printf("worker: polling every %s, batch=%d", interval, batchSize)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Print("worker: shutting down")
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			_ = srv.Shutdown(shutdownCtx)
			cancel()
			return
		case <-ticker.C:
		}

		n, err := processBatch(ctx, pool, batchSize)
		if err != nil {
			if ctx.Err() != nil {
				continue // выйдем в начале следующей итерации
			}
			log.Printf("worker: %v", err)
			continue
		}
		if n > 0 {
			log.Printf("worker: processed %d order(s)", n)
		}
	}
}

func processBatch(ctx context.Context, pool *pgxpool.Pool, limit int) (int, error) {
	rows, err := pool.Query(ctx, claimBatch, limit)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	processed := 0
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return processed, err
		}
		processed++
	}
	return processed, rows.Err()
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getenvDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

func getenvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
