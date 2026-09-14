package attest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/binary"
	"math/big"
	"testing"
	"time"

	"github.com/fxamacker/cbor/v2"
)

type fixture struct {
	object, challenge, publicKey []byte
	keyID                        string
	privateKey                   *ecdsa.PrivateKey
	roots                        *x509.CertPool
	appID                        string
}

func TestAppAttestVerificationAndAssertionReplay(t *testing.T) {
	f := newFixture(t)
	v := newVerifier(f.roots, f.appID, "production")
	verified, err := v.VerifyAttestation(f.object, f.challenge, f.keyID)
	if err != nil {
		t.Fatal(err)
	}
	if len(verified.PublicKey) != 65 {
		t.Fatal("missing verified key")
	}
	client := []byte("activation proof")
	assertion := makeAssertion(t, f, client, 1)
	counter, err := v.VerifyAssertion(assertion, client, verified.PublicKey, 0)
	if err != nil || counter != 1 {
		t.Fatalf("assertion: counter=%d err=%v", counter, err)
	}
	if _, err = v.VerifyAssertion(assertion, client, verified.PublicKey, 1); err == nil {
		t.Fatal("replayed assertion counter accepted")
	}
}
func TestAppAttestAcceptsOlderAttestationWithoutDistributionExtensions(t *testing.T) {
	f := newFixtureWith(t, fixtureOptions{omitExtensions: true})
	if _, err := newVerifier(f.roots, f.appID, "production").VerifyAttestation(f.object, f.challenge, f.keyID); err != nil {
		t.Fatal(err)
	}
}

func TestAppAttestRejectsWrongAppCertificateAndChallenge(t *testing.T) {
	f := newFixture(t)
	if _, err := newVerifier(f.roots, "OTHER."+f.appID, "production").VerifyAttestation(f.object, f.challenge, f.keyID); err == nil {
		t.Fatal("wrong app accepted")
	}
	if _, err := newVerifier(f.roots, f.appID, "production").VerifyAttestation(f.object, []byte("wrong challenge"), f.keyID); err == nil {
		t.Fatal("wrong challenge accepted")
	}
	otherRoots := x509.NewCertPool()
	other := newFixture(t)
	for _, cert := range other.roots.Subjects() {
		_ = cert
	}
	_ = other
	if _, err := newVerifier(otherRoots, f.appID, "production").VerifyAttestation(f.object, f.challenge, f.keyID); err == nil {
		t.Fatal("untrusted certificate accepted")
	}
}

func TestAppAttestRejectsCOSEAndDistributionMetadataMismatch(t *testing.T) {
	for _, test := range []struct {
		name    string
		options fixtureOptions
	}{{"COSE key", fixtureOptions{category: 2, bundle: "1", tamperCOSE: true}}, {"production category", fixtureOptions{category: 3, bundle: "1"}}, {"empty bundle", fixtureOptions{category: 2, bundle: ""}}} {
		t.Run(test.name, func(t *testing.T) {
			f := newFixtureWith(t, test.options)
			if _, err := newVerifier(f.roots, f.appID, "production").VerifyAttestation(f.object, f.challenge, f.keyID); err == nil {
				t.Fatal("invalid attestation accepted")
			}
		})
	}
}

func TestAssertionValidatesOptionalDistributionMetadata(t *testing.T) {
	f := newFixture(t)
	v := newVerifier(f.roots, f.appID, "production")
	client := []byte("client")
	valid := makeAssertionWithExtensions(t, f, client, 1, []byte{4, 0, 0, 0}, "2")
	if _, err := v.VerifyAssertion(valid, client, f.publicKey, 0); err != nil {
		t.Fatal(err)
	}
	invalid := makeAssertionWithExtensions(t, f, client, 2, []byte{3, 0, 0, 0}, "2")
	if _, err := v.VerifyAssertion(invalid, client, f.publicKey, 1); err == nil {
		t.Fatal("invalid assertion category accepted")
	}
}

func TestKeyIDUsesAppleStandardPaddedBase64(t *testing.T) {
	value := "inGjK2JbaAEhAsYwCns2zTyZDzsJ3OKx3Q2nnxk+mkY="
	decoded, err := decodeKeyID(value)
	if err != nil || len(decoded) != 32 {
		t.Fatalf("Apple key ID rejected: %v", err)
	}
	if _, err := decodeKeyID("inGjK2JbaAEhAsYwCns2zTyZDzsJ3OKx3Q2nnxk-mkY"); err == nil {
		t.Fatal("base64url key ID accepted")
	}
}

type fixtureOptions struct {
	category                   any
	bundle                     any
	tamperCOSE, omitExtensions bool
}

func newFixture(t *testing.T) fixture {
	return newFixtureWith(t, fixtureOptions{category: []byte{2, 0, 0, 0}, bundle: "1"})
}
func newFixtureWith(t *testing.T, options fixtureOptions) fixture {
	t.Helper()
	now := time.Now()
	rootKey := key(t)
	rootTemplate := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test App Attest Root"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	rootDER := createCert(t, rootTemplate, rootTemplate, &rootKey.PublicKey, rootKey)
	rootCert, _ := x509.ParseCertificate(rootDER)
	intermediateKey := key(t)
	intermediateTemplate := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "Intermediate"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	intermediateDER := createCert(t, intermediateTemplate, rootCert, &intermediateKey.PublicKey, rootKey)
	intermediate, _ := x509.ParseCertificate(intermediateDER)
	attestedKey := key(t)
	encodedKey := elliptic.Marshal(elliptic.P256(), attestedKey.X, attestedKey.Y)
	keyHash := sha256.Sum256(encodedKey)
	appID := "TEAMID.com.example.myterm"
	appHash := sha256.Sum256([]byte(appID))
	challenge := []byte("generated one use server challenge")
	authData := append([]byte(nil), appHash[:]...)
	flags := byte(0xc0)
	if options.omitExtensions {
		flags = 0x40
	}
	authData = append(authData, flags, 0, 0, 0, 0)
	authData = append(authData, append([]byte("appattest"), make([]byte, 7)...)...)
	length := make([]byte, 2)
	binary.BigEndian.PutUint16(length, 32)
	authData = append(authData, length...)
	authData = append(authData, keyHash[:]...)
	coseKey := attestedKey
	if options.tamperCOSE {
		coseKey = key(t)
	}
	x := coseKey.X.FillBytes(make([]byte, 32))
	y := coseKey.Y.FillBytes(make([]byte, 32))
	cose, err := cbor.Marshal(map[int]any{1: 2, 3: -7, -1: 1, -2: x, -3: y})
	if err != nil {
		t.Fatal(err)
	}
	authData = append(authData, cose...)
	if !options.omitExtensions {
		extensions, err := cbor.Marshal(map[string]any{"apple_validation_category_01": options.category, "apple_bundle_version_01": options.bundle})
		if err != nil {
			t.Fatal(err)
		}
		authData = append(authData, extensions...)
	}
	challengeHash := sha256.Sum256(challenge)
	combined := append(append([]byte(nil), authData...), challengeHash[:]...)
	nonce := sha256.Sum256(combined)
	extensionValue, err := asn1.Marshal(struct {
		Nonce []byte `asn1:"tag:1,explicit"`
	}{nonce[:]})
	if err != nil {
		t.Fatal(err)
	}
	leafTemplate := &x509.Certificate{SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "Credential"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtraExtensions: []pkix.Extension{{Id: nonceOID, Value: extensionValue}}}
	leafDER := createCert(t, leafTemplate, intermediate, &attestedKey.PublicKey, intermediateKey)
	object, err := cbor.Marshal(map[string]any{"fmt": "apple-appattest", "attStmt": map[string]any{"x5c": [][]byte{leafDER, intermediateDER}, "receipt": []byte("fixture receipt")}, "authData": authData})
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(rootCert)
	return fixture{object: object, challenge: challenge, publicKey: encodedKey, keyID: base64.StdEncoding.EncodeToString(keyHash[:]), privateKey: attestedKey, roots: roots, appID: appID}
}
func makeAssertion(t *testing.T, f fixture, client []byte, counter uint32) []byte {
	return makeAssertionWithExtensions(t, f, client, counter, nil, "")
}
func makeAssertionWithExtensions(t *testing.T, f fixture, client []byte, counter uint32, category []byte, bundle string) []byte {
	t.Helper()
	appHash := sha256.Sum256([]byte(f.appID))
	auth := append([]byte(nil), appHash[:]...)
	flags := byte(0)
	if category != nil {
		flags = 0x80
	}
	auth = append(auth, flags)
	count := make([]byte, 4)
	binary.BigEndian.PutUint32(count, counter)
	auth = append(auth, count...)
	if category != nil {
		extensions, err := cbor.Marshal(map[string]any{"apple_validation_category_01": category, "apple_bundle_version_01": bundle})
		if err != nil {
			t.Fatal(err)
		}
		auth = append(auth, extensions...)
	}
	clientHash := sha256.Sum256(client)
	combined := append(append([]byte(nil), auth...), clientHash[:]...)
	digest := sha256.Sum256(combined)
	signature, err := ecdsa.SignASN1(rand.Reader, f.privateKey, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	result, err := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if err != nil {
		t.Fatal(err)
	}
	return result
}
func key(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	value, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return value
}
func createCert(t *testing.T, template, parent *x509.Certificate, public any, signer any) []byte {
	t.Helper()
	encoded, err := x509.CreateCertificate(rand.Reader, template, parent, public, signer)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}
