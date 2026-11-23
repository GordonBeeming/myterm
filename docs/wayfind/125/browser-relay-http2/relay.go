package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"flag"
	"fmt"
	"html"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/quic-go/quic-go/http3"
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

func makeTestCertificate(issueRoot bool) (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
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
	if issueRoot {
		signingKey, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return tls.Certificate{}, err
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
			return tls.Certificate{}, err
		}
		if err := os.WriteFile("root.der", root, 0600); err != nil {
			return tls.Certificate{}, err
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, issuer, &key.PublicKey, signingKey)
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := os.WriteFile("relay.der", der, 0600); err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}

func run(issueRoot, useHTTP3 bool, certificateFile, keyFile, label string) error {
	var certificate tls.Certificate
	var err error
	if certificateFile == "" && keyFile == "" {
		certificate, err = makeTestCertificate(issueRoot)
	} else {
		certificate, err = tls.LoadX509KeyPair(certificateFile, keyFile)
	}
	if err != nil {
		return err
	}
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{certificate},
		NextProtos:   []string{"h2"},
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s %s", r.Proto, r.Method, r.Host)
		if r.Method == http.MethodConnect && r.Proto == "connect-udp" {
			http.Error(w, "UDP forwarding is absent from the fixture", http.StatusNotImplemented)
			return
		}
		if r.Method != http.MethodConnect || r.ProtoMajor < 2 {
			http.Error(w, "HTTP/2 or HTTP/3 CONNECT required", http.StatusMethodNotAllowed)
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
		body := "<!doctype html><title>" + html.EscapeString(label) + "</title>"
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
	})
	if useHTTP3 {
		listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			return err
		}
		defer listener.Close()
		server := &http3.Server{TLSConfig: http3.ConfigureTLSConfig(tlsConfig), Handler: handler, EnableDatagrams: true}
		fmt.Println(listener.LocalAddr().(*net.UDPAddr).Port)
		return server.Serve(listener)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer listener.Close()
	protocols := &http.Protocols{}
	protocols.SetUnencryptedHTTP2(true)
	server := &http.Server{
		Protocols:         protocols,
		ReadHeaderTimeout: 5 * time.Second,
		Handler:           handler,
	}
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	return server.Serve(relayListener{tls.NewListener(listener, tlsConfig)})
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	issueRoot := flag.Bool("issue-root", false, "issue a disposable TLS root for the simulator")
	useHTTP3 := flag.Bool("http3", false, "serve the fixture over HTTP/3")
	certificate := flag.String("cert", "", "optional PEM certificate chain for default-trust experiments")
	key := flag.String("key", "", "optional PEM key for a local fixture")
	label := flag.String("label", "RELAY_FIXTURE", "title identifying the responding fixture")
	flag.Parse()
	if err := run(*issueRoot, *useHTTP3, *certificate, *key, *label); err != nil {
		log.Fatal(err)
	}
}
