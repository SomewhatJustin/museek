package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"museek/internal/museek"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "museek:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return usageError()
	}
	switch args[0] {
	case "server":
		return runServer(args[1:])
	case "scan":
		return runScan(args[1:])
	case "invite":
		return runInvite(args[1:])
	case "share":
		return runGrant(args[1:], true)
	case "unshare":
		return runGrant(args[1:], false)
	case "devices":
		return runDevices(args[1:])
	case "revoke-device":
		return runRevokeDevice(args[1:])
	case "help", "-h", "--help":
		fmt.Println(usageText)
		return nil
	default:
		return usageError()
	}
}

const usageText = `Museek private music server

Usage:
  museek server [--music DIR] [--data DIR] [--listen ADDR] [--public-url URL]
  museek scan [--music DIR] [--data DIR]
  museek invite --recipient NAME --collection NAME [--music DIR] [--data DIR] [--public-url URL]
  museek share --recipient NAME --collection NAME [--data DIR]
  museek unshare --recipient NAME --collection NAME [--data DIR]
  museek devices --recipient NAME [--data DIR]
  museek revoke-device DEVICE_ID [--data DIR]

Environment:
  MUSEEK_MUSIC_DIR, MUSEEK_DATA_DIR, MUSEEK_LISTEN, MUSEEK_PUBLIC_URL
  MUSEEK_TAILNET_LISTEN (disabled unless set; trusted local Serve ingress only)
  MUSEEK_TAILNET_USERS (JSON exact Tailscale login -> existing recipient name)`

func usageError() error { return errors.New("unknown or missing command; run 'museek help'") }

type commonFlags struct {
	music string
	data  string
}

func addCommonFlags(flags *flag.FlagSet) *commonFlags {
	values := &commonFlags{}
	flags.StringVar(&values.music, "music", envOr("MUSEEK_MUSIC_DIR", "./music"), "music directory")
	flags.StringVar(&values.data, "data", envOr("MUSEEK_DATA_DIR", "./data"), "data directory")
	return values
}

func openStoreAndScanner(values *commonFlags) (*museek.Store, *museek.Scanner, error) {
	store, err := museek.OpenStore(values.data)
	if err != nil {
		return nil, nil, err
	}
	scanner, err := museek.NewScanner(store, values.music)
	if err != nil {
		store.Close()
		return nil, nil, err
	}
	return store, scanner, nil
}

func runScan(args []string) error {
	flags := flag.NewFlagSet("scan", flag.ContinueOnError)
	common := addCommonFlags(flags)
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, scanner, err := openStoreAndScanner(common)
	if err != nil {
		return err
	}
	defer store.Close()
	result, err := scanner.Scan(context.Background())
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}

func runInvite(args []string) error {
	flags := flag.NewFlagSet("invite", flag.ContinueOnError)
	common := addCommonFlags(flags)
	var recipient, collection string
	flags.StringVar(&recipient, "recipient", "", "recipient name")
	flags.StringVar(&collection, "collection", "", "collection name")
	publicURL := flags.String("public-url", os.Getenv("MUSEEK_PUBLIC_URL"), "public HTTPS base URL")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(recipient) == "" || strings.TrimSpace(collection) == "" {
		return errors.New("--recipient and --collection are required")
	}
	store, scanner, err := openStoreAndScanner(common)
	if err != nil {
		return err
	}
	defer store.Close()
	if _, err := scanner.Scan(context.Background()); err != nil {
		return err
	}
	code, err := store.CreateInvite(context.Background(), recipient, collection, 24*time.Hour)
	if err != nil {
		return err
	}
	link, err := buildInviteLink(*publicURL, code)
	if err != nil {
		return err
	}
	if link != "" {
		fmt.Printf("Invitation link: %s\n", link)
	}
	fmt.Printf("Pairing code: %s\nExpires in: 24 hours\n", code)
	return nil
}

func buildInviteLink(publicURL, code string) (string, error) {
	publicURL = strings.TrimSpace(publicURL)
	if publicURL == "" {
		return "", nil
	}
	parsed, err := url.Parse(publicURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return "", errors.New("public URL must be an absolute HTTP(S) URL")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/") + "/invite"
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.ForceQuery = false
	parsed.Fragment = url.Values{"code": {strings.TrimSpace(code)}}.Encode()
	parsed.RawFragment = ""
	return parsed.String(), nil
}

func runGrant(args []string, granted bool) error {
	name := "share"
	if !granted {
		name = "unshare"
	}
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	common := addCommonFlags(flags)
	var recipient, collection string
	flags.StringVar(&recipient, "recipient", "", "recipient name")
	flags.StringVar(&collection, "collection", "", "collection name")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(recipient) == "" || strings.TrimSpace(collection) == "" {
		return errors.New("--recipient and --collection are required")
	}
	store, scanner, err := openStoreAndScanner(common)
	if err != nil {
		return err
	}
	defer store.Close()
	if _, err := scanner.Scan(context.Background()); err != nil {
		return err
	}
	return store.SetGrant(context.Background(), recipient, collection, granted)
}

func runDevices(args []string) error {
	flags := flag.NewFlagSet("devices", flag.ContinueOnError)
	data := flags.String("data", envOr("MUSEEK_DATA_DIR", "./data"), "data directory")
	recipient := flags.String("recipient", "", "recipient name")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*recipient) == "" {
		return errors.New("--recipient is required")
	}
	store, err := museek.OpenStore(*data)
	if err != nil {
		return err
	}
	defer store.Close()
	devices, err := store.ListDevices(context.Background(), *recipient)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(devices)
}

func runRevokeDevice(args []string) error {
	flags := flag.NewFlagSet("revoke-device", flag.ContinueOnError)
	data := flags.String("data", envOr("MUSEEK_DATA_DIR", "./data"), "data directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return errors.New("device ID is required")
	}
	store, err := museek.OpenStore(*data)
	if err != nil {
		return err
	}
	defer store.Close()
	return store.RevokeDevice(context.Background(), flags.Arg(0))
}

func runServer(args []string) error {
	flags := flag.NewFlagSet("server", flag.ContinueOnError)
	common := addCommonFlags(flags)
	listen := flags.String("listen", envOr("MUSEEK_LISTEN", ":8080"), "listen address")
	publicURL := flags.String("public-url", os.Getenv("MUSEEK_PUBLIC_URL"), "public HTTPS base URL")
	scanInterval := flags.Duration("scan-interval", time.Minute, "filesystem scan interval")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, scanner, err := openStoreAndScanner(common)
	if err != nil {
		return err
	}
	defer store.Close()
	result, err := scanner.Scan(context.Background())
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	logger.Info("initial scan complete", "collections", result.Collections, "tracks", result.Tracks)
	signer, err := museek.LoadStreamSigner(common.data)
	if err != nil {
		return err
	}
	api, err := museek.NewAPI(store, signer, common.music, *publicURL, logger)
	if err != nil {
		return err
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if *scanInterval > 0 {
		go func() {
			ticker := time.NewTicker(*scanInterval)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					result, err := scanner.Scan(ctx)
					if err != nil && !errors.Is(err, context.Canceled) {
						logger.Error("periodic scan failed", "error", err)
					} else if err == nil {
						logger.Info("periodic scan complete", "collections", result.Collections, "tracks", result.Tracks)
					}
				}
			}
		}()
	}

	server := &http.Server{
		Addr:              *listen,
		Handler:           api.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	servers := []*http.Server{server}
	if address := os.Getenv("MUSEEK_TAILNET_LISTEN"); address != "" {
		handler, err := api.TailnetHandler(os.Getenv("MUSEEK_TAILNET_USERS"))
		if err != nil {
			return fmt.Errorf("tailnet configuration: %w", err)
		}
		servers = append(servers, &http.Server{Addr: address, Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 2 * time.Minute})
	}
	listeners, err := bindServers(servers)
	if err != nil {
		return err
	}
	defer func() {
		for _, listener := range listeners {
			_ = listener.Close()
		}
		for _, srv := range servers {
			_ = srv.Close()
		}
	}()
	errCh := make(chan error, len(servers))
	for i, srv := range servers {
		go func() {
			logger.Info("server listening", "address", listeners[i].Addr().String())
			errCh <- srv.Serve(listeners[i])
		}()
	}
	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		for _, srv := range servers {
			if err := srv.Shutdown(shutdownCtx); err != nil {
				return err
			}
		}
		return nil
	}
	return nil
}

func envOr(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}
