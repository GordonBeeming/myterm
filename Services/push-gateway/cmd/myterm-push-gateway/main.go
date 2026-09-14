package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gordonbeeming/myterm/push-gateway/internal/apns"
	"github.com/gordonbeeming/myterm/push-gateway/internal/config"
	"github.com/gordonbeeming/myterm/push-gateway/internal/httpapi"
	"github.com/gordonbeeming/myterm/push-gateway/internal/store"
)

func main() {
	if err := run(); err != nil {
		slog.Error("push gateway stopped", "error", err)
		os.Exit(1)
	}
}
func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	storage, err := store.Open(context.Background(), cfg.DatabasePath)
	if err != nil {
		return err
	}
	defer storage.Close()
	if err := storage.Prune(context.Background(), time.Now()); err != nil {
		return err
	}
	sender, err := apns.New(cfg)
	if err != nil {
		return err
	}
	api, err := httpapi.New(cfg, storage, sender)
	if err != nil {
		return err
	}
	server := &http.Server{Addr: cfg.ListenAddress, Handler: api.Handler(), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 75 * time.Second, MaxHeaderBytes: 32 << 10}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	errorsCh := make(chan error, 1)
	go pruneLoop(ctx, storage)
	go func() {
		slog.Info("push gateway listening", "address", cfg.ListenAddress, "public_origin", cfg.PublicURL.String())
		errorsCh <- server.ListenAndServe()
	}()
	select {
	case err := <-errorsCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return server.Shutdown(shutdown)
	}
}

func pruneLoop(ctx context.Context, storage *store.Store) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			if err := storage.Prune(ctx, now); err != nil && !errors.Is(err, context.Canceled) {
				slog.Error("push gateway prune failed", "error", err)
			}
		}
	}
}
