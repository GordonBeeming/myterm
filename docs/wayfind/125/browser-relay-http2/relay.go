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

// Feed HTTP/2 to net/http after TLS. The Apple relay client can send the mandatory
// HTTP/2 connection preface without negotiating h2 through ALPN.
type relayListener struct{ net.Listener }
type relayConnection struct{ net.Conn }

func (listener relayListener) Accept() (net.Conn, error) {
	connection, err := listener.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return relayConnection{connection}, nil
}

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
	issuer := cert
	signingKey := key
	if len(os.Args) == 2 && os.Args[1] == "--issue-root" {
		signingKey, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return err
		}
		issuer = &x509.Certificate{
			SerialNumber:          big.NewInt(2),
			Subject:               pkix.Name{CommonName: "MyTerm disposable relay root"},
			KeyUsage:              x509.KeyUsageCertSign,
			BasicConstraintsValid: true,
			IsCA:                  true,
			NotBefore:             cert.NotBefore,
			NotAfter:              cert.NotAfter,
		}
		root, err := x509.CreateCertificate(rand.Reader, issuer, issuer, &signingKey.PublicKey, signingKey)
		if err != nil {
			return err
		}
		if err := os.WriteFile("root.der", root, 0600); err != nil {
			return err
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, issuer, &key.PublicKey, signingKey)
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
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		NextProtos:   []string{"h2"},
	}
	protocols := &http.Protocols{}
	protocols.SetUnencryptedHTTP2(true)
	server := &http.Server{
		Protocols:         protocols,
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
			if _, err := fmt.Fprintf(w, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\n\r\n%s", len(body), body); err != nil {
				log.Print(err)
				return
			}
			if err := http.NewResponseController(w).Flush(); err != nil {
				log.Print(err)
				return
			}
			log.Printf("Sent fixture response to %s", r.Host)
			// A CONNECT client can leave its send side open while it reads the response.
			select {
			case <-r.Context().Done():
			case <-time.After(2 * time.Second):
			}
		}),
	}
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	return server.Serve(relayListener{tls.NewListener(listener, tlsConfig)})
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
