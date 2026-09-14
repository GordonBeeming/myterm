package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gordonbeeming/myterm/relay/internal/config"
	"github.com/gordonbeeming/myterm/relay/internal/httpapi"
	"github.com/gordonbeeming/myterm/relay/internal/store"
	"github.com/gordonbeeming/myterm/relay/internal/transport"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		slog.Error("relay stopped", "error", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx := context.Background()
	storage, err := store.Open(ctx, cfg.DatabasePath)
	if err != nil {
		return err
	}
	defer storage.Close()

	if len(args) > 0 {
		switch args[0] {
		case "bootstrap-owner":
			return bootstrapOwner(ctx, cfg, storage, args[1:])
		case "add-passkey":
			return ownerEnrollment(ctx, cfg, storage, "add", args[1:])
		case "recover-owner":
			return ownerEnrollment(ctx, cfg, storage, "recover", args[1:])
		case "serve":
		default:
			return fmt.Errorf("unknown command %q; use serve, bootstrap-owner, add-passkey, or recover-owner", args[0])
		}
	}
	if len(args) > 1 {
		return errors.New("serve accepts no arguments")
	}
	return serve(cfg, storage)
}

func ownerEnrollment(ctx context.Context, cfg config.Config, storage *store.Store, purpose string, args []string) error {
	flags := flag.NewFlagSet(purpose, flag.ContinueOnError)
	expires := flags.Duration("expires", 15*time.Minute, "how long the one-time passkey URL remains valid")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("passkey command accepts no positional arguments")
	}
	if *expires < time.Minute || *expires > time.Hour {
		return errors.New("expires must be from 1 minute through 1 hour")
	}
	token, err := store.NewToken(32)
	if err != nil {
		return err
	}
	if err := storage.CreateOwnerEnrollmentToken(ctx, token, purpose, time.Now().Add(*expires)); err != nil {
		return err
	}
	registrationURL := *cfg.PublicURL
	registrationURL.Path = "/auth/register"
	registrationURL.Fragment = "enrollment_token=" + token
	action := "add a passkey"
	if purpose == "recover" {
		action = "replace all owner passkeys and revoke every device session"
	}
	fmt.Printf("Paste this one-time URL into MyTerm to %s:\n", action)
	fmt.Println(registrationURL.String())
	fmt.Printf("MyTerm adds PKCE parameters before opening the system browser. The URL expires in %s and is shown once.\n", expires.String())
	return nil
}

func bootstrapOwner(ctx context.Context, cfg config.Config, storage *store.Store, args []string) error {
	flags := flag.NewFlagSet("bootstrap-owner", flag.ContinueOnError)
	expires := flags.Duration("expires", 15*time.Minute, "how long the one-time registration URL remains valid")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("bootstrap-owner accepts no positional arguments")
	}
	if *expires < time.Minute || *expires > time.Hour {
		return errors.New("expires must be from 1 minute through 1 hour")
	}
	token, err := store.NewToken(32)
	if err != nil {
		return err
	}
	if err := storage.CreateBootstrapToken(ctx, token, time.Now().Add(*expires)); err != nil {
		return err
	}
	registrationURL := *cfg.PublicURL
	registrationURL.Path = "/auth/register"
	registrationURL.Fragment = "bootstrap_token=" + token
	fmt.Println("Paste this one-time bootstrap URL into MyTerm on the device that will own the relay:")
	fmt.Println(registrationURL.String())
	fmt.Printf("MyTerm adds PKCE parameters before opening the system browser. The URL expires in %s and is shown once.\n", expires.String())
	return nil
}

func serve(cfg config.Config, storage *store.Store) error {
	if err := storage.PruneExpired(context.Background(), time.Now()); err != nil {
		return fmt.Errorf("prune expired relay state: %w", err)
	}
	hub := transport.New(cfg)
	api, err := httpapi.New(cfg, storage, hub)
	if err != nil {
		return err
	}
	server := &http.Server{
		Addr:              cfg.ListenAddress,
		Handler:           api.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       75 * time.Second,
		MaxHeaderBytes:    32 << 10,
	}
	stopCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	serveErrors := make(chan error, 1)
	go pruneLoop(stopCtx, storage)
	go func() {
		slog.Info("relay listening", "address", cfg.ListenAddress, "public_origin", cfg.PublicURL.String())
		serveErrors <- server.ListenAndServe()
	}()
	select {
	case err := <-serveErrors:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-stopCtx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return server.Shutdown(shutdownCtx)
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
			if err := storage.PruneExpired(ctx, now); err != nil && !errors.Is(err, context.Canceled) {
				slog.Error("could not prune expired relay state", "error_type", fmt.Sprintf("%T", err))
			}
		}
	}
}
