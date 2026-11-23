package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"time"
)

func run() error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	cert := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "MyTerm disposable WebKit relay fixture"},
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(time.Hour),
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer listener.Close()
	if err := os.WriteFile("relay.der", der, 0600); err != nil {
		return err
	}
	server := &http.Server{
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}},
		ReadHeaderTimeout: 5 * time.Second,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			log.Printf("%s %s %s", r.Proto, r.Method, r.Host)
			if r.Method != http.MethodConnect || r.ProtoMajor != 2 {
				http.Error(w, "HTTP/2 CONNECT required", http.StatusMethodNotAllowed)
				return
			}
			w.WriteHeader(http.StatusOK)
			if err := http.NewResponseController(w).Flush(); err != nil {
				log.Print(err)
				return
			}
			reader := bufio.NewReader(r.Body)
			line, err := reader.ReadString('\n')
			if err != nil {
				log.Print(err)
				return
			}
			log.Printf("Tunnel request %q", line)
			for line != "\r\n" {
				line, err = reader.ReadString('\n')
				if err != nil {
					log.Print(err)
					return
				}
			}
			body := "<!doctype html><title>RELAY_FIXTURE</title>"
			if _, err := fmt.Fprintf(w, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body); err != nil {
				log.Print(err)
			}
		}),
	}
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	return server.ServeTLS(listener, "", "")
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
