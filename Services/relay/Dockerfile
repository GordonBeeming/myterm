FROM golang:1.26.6-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/myterm-relay ./cmd/myterm-relay

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build --chown=nonroot:nonroot /out/myterm-relay /app/myterm-relay
USER nonroot:nonroot
EXPOSE 8787
ENTRYPOINT ["/app/myterm-relay"]
CMD ["serve"]
