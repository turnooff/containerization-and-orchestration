# syntax=docker/dockerfile:1

FROM golang:1.27.1-alpine AS build
WORKDIR /src

# Сначала только манифесты модуля — слой с зависимостями кешируется
# и не пересобирается при правке кода.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

# distroless: нет shell и пакетного менеджера, работает non-root (uid 65532).
# Это заодно закрывает правила политики про non-root и read-only rootfs.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/api"]