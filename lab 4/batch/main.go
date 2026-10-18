package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	workers, err := envInt("CPU_WORKERS", 1, 1, 1024)
	if err != nil {
		return err
	}
	memoryMiB, err := envInt("MEMORY_MIB", 64, 1, int(^uint(0)>>1)/(1024*1024))
	if err != nil {
		return err
	}
	port, err := envInt("PORT", 8080, 1, 65535)
	if err != nil {
		return err
	}

	listener, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return err
	}
	defer listener.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Записываем в каждую страницу: одного резервирования адресов недостаточно
	// для реального потребления памяти. Буфер остаётся жив до остановки процесса.
	memory := make([]byte, memoryMiB*1024*1024)
	for i := range memory {
		memory[i] = byte(i%251 + 1)
	}

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			burnCPU(ctx)
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				// Регулярно трогаем страницы, удерживая рабочий набор в памяти.
				for i := 0; i < len(memory); i += os.Getpagesize() {
					memory[i]++
				}
				runtime.KeepAlive(memory)
			}
		}
	}()

	mux := http.NewServeMux()
	health := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	}
	mux.HandleFunc("GET /health", health)
	mux.HandleFunc("GET /ready", health)
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	serverErr := make(chan error, 1)
	go func() { serverErr <- server.Serve(listener) }()
	log.Printf("batch: CPU_WORKERS=%d MEMORY_MIB=%d PORT=%d; load started", workers, memoryMiB, port)

	select {
	case <-ctx.Done():
	case err = <-serverErr:
	}
	stop()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	shutdownErr := server.Shutdown(shutdownCtx)
	wg.Wait()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	log.Print("batch: stopped")
	return shutdownErr
}

func burnCPU(ctx context.Context) {
	var data [4096]byte
	for {
		select {
		case <-ctx.Done():
			return
		default:
			for i := 0; i < 256; i++ {
				digest := sha256.Sum256(data[:])
				copy(data[:], digest[:])
			}
		}
	}
}

func envInt(name string, fallback, min, max int) (int, error) {
	value, exists := os.LookupEnv(name)
	if !exists {
		return fallback, nil
	}
	n, err := strconv.Atoi(value)
	if err != nil || n < min || n > max {
		return 0, fmt.Errorf("%s must be an integer in [%d, %d], got %q", name, min, max, value)
	}
	return n, nil
}
