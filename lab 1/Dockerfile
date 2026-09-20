FROM golang:1.27
WORKDIR /src
COPY api/ .
RUN CGO_ENABLED=0 go build -o /api .
CMD ["/api"]