package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func run(port string) error {
	der, err := os.ReadFile("relay.der")
	if err != nil {
		return err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			ForceAttemptHTTP2: true,
			TLSClientConfig:   &tls.Config{RootCAs: roots},
		},
	}
	request, err := http.NewRequest(http.MethodConnect, "https://127.0.0.1:"+port,
		bytes.NewBufferString("GET /routing-probe HTTP/1.1\r\nHost: myterm-route-probe.invalid\r\n\r\n"))
	if err != nil {
		return err
	}
	request.Host = "myterm-route-probe.invalid:80"
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return err
	}
	if response.ProtoMajor != 2 || response.StatusCode != http.StatusOK || !bytes.Contains(body, []byte("RELAY_FIXTURE")) {
		return fmt.Errorf("unexpected fixture response: %s %d %s", response.Proto, response.StatusCode, body)
	}
	fmt.Printf("%s %d RELAY_FIXTURE\n", response.Proto, response.StatusCode)
	return nil
}

func main() {
	if len(os.Args) != 2 {
		log.Fatal("usage: control RELAY_PORT")
	}
	if err := run(os.Args[1]); err != nil {
		log.Fatal(err)
	}
}
