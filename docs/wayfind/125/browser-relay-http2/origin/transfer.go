package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"time"
)

const transferSize = 8 * 1024 * 1024

func handleOrigin(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/transfer":
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprint(w, `<!doctype html><title>TRANSFER_FIXTURE</title><input id="file" type="file">
<script>
document.getElementById('file').addEventListener('change', async (event) => {
  const body = new FormData();
  body.append('fixture', event.target.files[0]);
  try {
    const response = await fetch('/upload' + location.search, {method: 'POST', body});
    window.fixtureTransfer = {status: response.status, ...(await response.json())};
  } catch (error) { window.fixtureTransfer = {error: String(error)}; }
});
</script>`)
	case "/upload":
		handleUpload(w, r)
	case "/download":
		handleDownload(w, r)
	default:
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprint(w, "<!doctype html><title>ORIGIN_TLS_FIXTURE</title>")
	}
}

func handleUpload(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, transferSize+64*1024)
	reader, err := r.MultipartReader()
	if err != nil {
		http.Error(w, "expected fixture multipart request", http.StatusBadRequest)
		return
	}
	part, err := reader.NextPart()
	if err != nil || part.FormName() != "fixture" {
		http.Error(w, "expected fixture file", http.StatusBadRequest)
		return
	}
	hash := sha256.New()
	size, err := io.Copy(hash, part)
	if err != nil {
		http.Error(w, "fixture read failed", http.StatusBadRequest)
		return
	}
	mode := r.URL.Query().Get("mode")
	digest := fmt.Sprintf("%x", hash.Sum(nil))
	log.Printf("upload %s received %d bytes sha256=%s", mode, size, digest)
	w.Header().Set("Content-Type", "application/json")
	if mode == "reject" {
		w.WriteHeader(http.StatusUnprocessableEntity)
	}
	if err := json.NewEncoder(w).Encode(map[string]any{"bytes": size, "sha256": digest}); err != nil {
		log.Print(err)
	}
}

func handleDownload(w http.ResponseWriter, r *http.Request) {
	mode := r.URL.Query().Get("mode")
	log.Printf("download %s requested", mode)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename=fixture.bin")
	w.Header().Set("Content-Length", strconv.Itoa(transferSize))
	chunk := bytes.Repeat([]byte{0x5a}, 32*1024)
	for sent := 0; sent < transferSize; sent += len(chunk) {
		if _, err := w.Write(chunk); err != nil {
			log.Printf("download %s ended: %v", mode, err)
			return
		}
		if mode == "broken" {
			if err := http.NewResponseController(w).Flush(); err != nil {
				log.Print(err)
			}
			return
		}
		if mode == "cancel" {
			if err := http.NewResponseController(w).Flush(); err != nil {
				log.Print(err)
				return
			}
			time.Sleep(15 * time.Millisecond)
		}
	}
	log.Printf("download %s sent %d bytes", mode, transferSize)
}
