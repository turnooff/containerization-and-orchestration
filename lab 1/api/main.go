package main

// самый ценный комментарий, который нужен, чтобы показать, как работает cashe при сборке образа.

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"sync"
)

var (
	mu     sync.Mutex
	memory [][]byte
)

func main() {
	addr := ":8080"
	if v := os.Getenv("ADDR"); v != "" {
		addr = v
	}

	// /health — просто «жив».
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "ok")
	})

	// /eat?mb=N — выделяем N МБ и держим их в памяти.
	// Пишем в каждый байт, чтобы страницы реально закоммитились
	// и попали в RSS — иначе аллокатор оставит их виртуальными,
	// и лимит памяти не сработает.
	http.HandleFunc("/eat", func(w http.ResponseWriter, r *http.Request) {
		n, err := strconv.Atoi(r.URL.Query().Get("mb"))
		if err != nil || n <= 0 {
			http.Error(w, "mb must be a positive integer", http.StatusBadRequest)
			return
		}
		mu.Lock()
		for i := 0; i < n; i++ {
			b := make([]byte, 1<<20)
			for j := range b {
				b[j] = 1
			}
			memory = append(memory, b)
		}
		total := len(memory)
		mu.Unlock()
		fmt.Fprintf(w, "allocated %d MB, holding %d MB total\n", n, total)
	})

	// /burn — бесконечный цикл, жжёт ядро. Каждый запрос = ещё одна
	// горящая горутина, удобно для проверки CPU-лимита.
	http.HandleFunc("/burn", func(w http.ResponseWriter, r *http.Request) {
		var x uint64
		for {
			x++
		}
	})

	log.Printf("api listening on %s (pid %d, GOMAXPROCS %d)",
		addr, os.Getpid(), runtime.GOMAXPROCS(0))
	log.Fatal(http.ListenAndServe(addr, nil))
}
