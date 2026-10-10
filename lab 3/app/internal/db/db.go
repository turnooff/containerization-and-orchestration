package db

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// DSN собирает строку подключения: DATABASE_URL имеет приоритет,
// иначе собираем из стандартных PG*-переменных (их же понимает psql).
func DSN() string {
	if v := os.Getenv("DATABASE_URL"); v != "" {
		return v
	}
	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(getenv("PGUSER", "postgres"), getenv("PGPASSWORD", "")),
		Host:   net.JoinHostPort(getenv("PGHOST", "localhost"), getenv("PGPORT", "5432")),
		Path:   "/" + getenv("PGDATABASE", "shop"),
	}
	q := url.Values{}
	q.Set("sslmode", getenv("PGSSLMODE", "disable"))
	u.RawQuery = q.Encode()
	return u.String()
}

// Connect подключается к БД и ждёт её готовности: под приложения вполне может
// подняться раньше, чем БД начнёт принимать соединения. Вместо мгновенного
// падения — ретраи с дедлайном.
func Connect(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.MaxConns = 8
	cfg.MaxConnLifetime = time.Hour

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}

	deadline := time.Now().Add(2 * time.Minute)
	for {
		pingCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = pool.Ping(pingCtx)
		cancel()
		if err == nil {
			return pool, nil
		}
		if time.Now().After(deadline) {
			pool.Close()
			return nil, fmt.Errorf("database is not reachable: %w", err)
		}
		select {
		case <-ctx.Done():
			pool.Close()
			return nil, ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

// migrations идемпотентны, поэтому их безопасно гонять на каждом старте api.
var migrations = []string{
	`CREATE TABLE IF NOT EXISTS orders (
		id           BIGSERIAL PRIMARY KEY,
		customer     TEXT        NOT NULL,
		item         TEXT        NOT NULL,
		status       TEXT        NOT NULL DEFAULT 'new',
		created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
		processed_at TIMESTAMPTZ
	)`,
	`CREATE INDEX IF NOT EXISTS orders_status_idx ON orders (status)`,
}

// EnsureSchema создаёт таблицы, если их ещё нет.
// Вызывает только api: параллельный CREATE TABLE IF NOT EXISTS из нескольких
// реплик в редких случаях даёт ошибку гонки, поэтому «владелец схемы» один.
func EnsureSchema(ctx context.Context, pool *pgxpool.Pool) error {
	for _, stmt := range migrations {
		if _, err := pool.Exec(ctx, stmt); err != nil {
			return fmt.Errorf("migration failed: %w", err)
		}
	}
	return nil
}
