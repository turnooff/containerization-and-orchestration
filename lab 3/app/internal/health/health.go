package health

import (
	"net/http"
	"os"
	"strings"
)

// Failing сообщает, взведён ли рубильник HEALTH_FAIL.
// Нужен, чтобы в лабе можно было «сломать» новый под и посмотреть,
// как Deployment не сможет завершить rollout.
func Failing() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("HEALTH_FAIL"))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

// Handler отдаёт 200 "ok" и 503, если HEALTH_FAIL=true.
// На него вешаются и readiness, и liveness.
func Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		if Failing() {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte("fail\n"))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	}
}
