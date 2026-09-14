package attest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/fxamacker/cbor/v2"
)

//go:embed apple_app_attestation_root.pem
var appleRootPEM []byte

var nonceOID = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}

type Verifier struct {
	roots       *x509.CertPool
	appID       string
	environment string
	now         func() time.Time
}
type Attestation struct {
	PublicKey []byte
	Receipt   []byte
	Counter   uint32
}
type attestationObject struct {
	Format    string `cbor:"fmt"`
	Statement struct {
		Certificates [][]byte `cbor:"x5c"`
		Receipt      []byte   `cbor:"receipt"`
	} `cbor:"attStmt"`
	AuthData []byte `cbor:"authData"`
}
type assertionObject struct {
	Signature []byte `cbor:"signature"`
	AuthData  []byte `cbor:"authenticatorData"`
}

func New(teamID, bundleID, environment string) (*Verifier, error) {
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(appleRootPEM) {
		return nil, errors.New("embedded Apple App Attestation root is invalid")
	}
	return newVerifier(roots, teamID+"."+bundleID, environment), nil
}

func newVerifier(roots *x509.CertPool, appID, environment string) *Verifier {
	return &Verifier{roots: roots, appID: appID, environment: environment, now: time.Now}
}

func (v *Verifier) VerifyAttestation(objectBytes, challenge []byte, keyID string) (Attestation, error) {
	var object attestationObject
	if err := cbor.Unmarshal(objectBytes, &object); err != nil {
		return Attestation{}, fmt.Errorf("decode attestation: %w", err)
	}
	if object.Format != "apple-appattest" || len(object.Statement.Certificates) < 2 {
		return Attestation{}, errors.New("invalid App Attest statement")
	}
	if len(object.Statement.Receipt) == 0 {
		return Attestation{}, errors.New("App Attest receipt is missing")
	}
	leaf, err := x509.ParseCertificate(object.Statement.Certificates[0])
	if err != nil {
		return Attestation{}, err
	}
	intermediates := x509.NewCertPool()
	for _, encoded := range object.Statement.Certificates[1:] {
		cert, err := x509.ParseCertificate(encoded)
		if err != nil {
			return Attestation{}, err
		}
		intermediates.AddCert(cert)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: v.roots, Intermediates: intermediates, CurrentTime: v.now(), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); err != nil {
		return Attestation{}, fmt.Errorf("verify Apple chain: %w", err)
	}
	parsed, err := parseAttestedAuthData(object.AuthData)
	if err != nil {
		return Attestation{}, err
	}
	challengeHash := sha256.Sum256(challenge)
	composite := append(append([]byte(nil), object.AuthData...), challengeHash[:]...)
	nonce := sha256.Sum256(composite)
	var certificateNonce []byte
	for _, extension := range leaf.Extensions {
		if extension.Id.Equal(nonceOID) {
			var wrapper struct {
				Nonce []byte `asn1:"tag:1,explicit"`
			}
			if _, err := asn1.Unmarshal(extension.Value, &wrapper); err != nil {
				return Attestation{}, fmt.Errorf("decode nonce extension: %w", err)
			}
			certificateNonce = wrapper.Nonce
		}
	}
	if !bytes.Equal(certificateNonce, nonce[:]) {
		return Attestation{}, errors.New("attestation nonce mismatch")
	}
	publicKey, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || publicKey.Curve != elliptic.P256() {
		return Attestation{}, errors.New("credential certificate key is not P-256")
	}
	encodedKey := elliptic.Marshal(elliptic.P256(), publicKey.X, publicKey.Y)
	keyHash := sha256.Sum256(encodedKey)
	providedKeyID, err := decodeKeyID(keyID)
	if err != nil || !bytes.Equal(providedKeyID, keyHash[:]) {
		return Attestation{}, errors.New("App Attest key identifier mismatch")
	}
	appHash := sha256.Sum256([]byte(v.appID))
	if !bytes.Equal(parsed.rpIDHash, appHash[:]) {
		return Attestation{}, errors.New("App Attest app identifier mismatch")
	}
	if parsed.counter != 0 {
		return Attestation{}, errors.New("initial App Attest counter is not zero")
	}
	expectedAAGUID := append([]byte("appattest"), make([]byte, 7)...)
	if v.environment == "development" {
		expectedAAGUID = []byte("appattestdevelop")
	}
	if !bytes.Equal(parsed.aaguid, expectedAAGUID) {
		return Attestation{}, errors.New("App Attest environment mismatch")
	}
	if !bytes.Equal(parsed.credentialID, keyHash[:]) {
		return Attestation{}, errors.New("App Attest credential identifier mismatch")
	}
	if !bytes.Equal(parsed.publicKey, encodedKey) {
		return Attestation{}, errors.New("App Attest COSE key mismatch")
	}
	if err := v.validateExtensions(parsed.extensions); err != nil {
		return Attestation{}, err
	}
	return Attestation{PublicKey: encodedKey, Receipt: append([]byte(nil), object.Statement.Receipt...), Counter: 0}, nil
}

func (v *Verifier) VerifyAssertion(assertion, clientData, publicKeyBytes []byte, previousCounter uint32) (uint32, error) {
	var object assertionObject
	if err := cbor.Unmarshal(assertion, &object); err != nil {
		return 0, fmt.Errorf("decode assertion: %w", err)
	}
	if len(object.AuthData) < 37 {
		return 0, errors.New("invalid assertion authenticator data")
	}
	appHash := sha256.Sum256([]byte(v.appID))
	if !bytes.Equal(object.AuthData[:32], appHash[:]) {
		return 0, errors.New("assertion app identifier mismatch")
	}
	counter := binary.BigEndian.Uint32(object.AuthData[33:37])
	if counter <= previousCounter || counter == 0 {
		return 0, errors.New("assertion counter replay")
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), publicKeyBytes)
	if x == nil {
		return 0, errors.New("invalid stored App Attest key")
	}
	clientHash := sha256.Sum256(clientData)
	composite := append(append([]byte(nil), object.AuthData...), clientHash[:]...)
	digest := sha256.Sum256(composite)
	if !ecdsa.VerifyASN1(&ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, digest[:], object.Signature) {
		return 0, errors.New("invalid App Attest assertion signature")
	}
	var extensions map[string]any
	if object.AuthData[32]&0x80 != 0 {
		if len(object.AuthData) == 37 {
			return 0, errors.New("assertion extensions missing")
		}
		if err := cbor.Unmarshal(object.AuthData[37:], &extensions); err != nil {
			return 0, fmt.Errorf("decode assertion extensions: %w", err)
		}
	} else if len(object.AuthData) != 37 {
		return 0, errors.New("unexpected assertion authenticator data")
	}
	if err := v.validateExtensions(extensions); err != nil {
		return 0, err
	}
	return counter, nil
}

type parsedAuthData struct {
	rpIDHash, aaguid, credentialID []byte
	counter                        uint32
	publicKey                      []byte
	extensions                     map[string]any
}

func parseAttestedAuthData(data []byte) (parsedAuthData, error) {
	if len(data) < 55 || data[32]&0x40 == 0 {
		return parsedAuthData{}, errors.New("invalid attested authenticator data")
	}
	length := int(binary.BigEndian.Uint16(data[53:55]))
	if length != 32 || len(data) < 55+length {
		return parsedAuthData{}, errors.New("invalid App Attest credential identifier")
	}
	remaining := data[55+length:]
	var cose map[int64]any
	rest, err := cbor.UnmarshalFirst(remaining, &cose)
	if err != nil {
		return parsedAuthData{}, fmt.Errorf("decode App Attest COSE key: %w", err)
	}
	if integer(cose[1]) != 2 || integer(cose[3]) != -7 || integer(cose[-1]) != 1 {
		return parsedAuthData{}, errors.New("unsupported App Attest COSE key")
	}
	x, xok := cose[-2].([]byte)
	y, yok := cose[-3].([]byte)
	if !xok || !yok || len(x) != 32 || len(y) != 32 {
		return parsedAuthData{}, errors.New("invalid App Attest COSE coordinates")
	}
	publicKey := append([]byte{4}, append(append([]byte(nil), x...), y...)...)
	if px, _ := elliptic.Unmarshal(elliptic.P256(), publicKey); px == nil {
		return parsedAuthData{}, errors.New("App Attest COSE key is not P-256")
	}
	var extensions map[string]any
	if data[32]&0x80 != 0 {
		if len(rest) == 0 {
			return parsedAuthData{}, errors.New("App Attest extensions missing")
		}
		if err := cbor.Unmarshal(rest, &extensions); err != nil {
			return parsedAuthData{}, fmt.Errorf("decode App Attest extensions: %w", err)
		}
	} else if len(rest) != 0 {
		return parsedAuthData{}, errors.New("unexpected App Attest authenticator data")
	}
	return parsedAuthData{rpIDHash: append([]byte(nil), data[:32]...), counter: binary.BigEndian.Uint32(data[33:37]), aaguid: append([]byte(nil), data[37:53]...), credentialID: append([]byte(nil), data[55:55+length]...), publicKey: publicKey, extensions: extensions}, nil
}

func decodeKeyID(value string) ([]byte, error) {
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) != 32 {
		return nil, errors.New("App Attest key identifier is not standard Base64 SHA-256")
	}
	return decoded, nil
}
func integer(value any) int64 {
	switch value := value.(type) {
	case int64:
		return value
	case uint64:
		if value <= 1<<63-1 {
			return int64(value)
		}
	case int:
		return int64(value)
	case uint32:
		return int64(value)
	}
	return 1<<63 - 1
}
func (v *Verifier) validateExtensions(values map[string]any) error {
	if len(values) == 0 {
		return nil
	}
	if raw, ok := values["apple_validation_category_01"]; ok {
		var category uint32
		switch value := raw.(type) {
		case []byte:
			if len(value) != 4 {
				return errors.New("invalid App Attest validation category")
			}
			category = binary.LittleEndian.Uint32(value)
		case uint64:
			if value > 1<<32-1 {
				return errors.New("invalid App Attest validation category")
			}
			category = uint32(value)
		default:
			return errors.New("invalid App Attest validation category")
		}
		if (v.environment == "development" && category != 3) || (v.environment == "production" && category != 2 && category != 4) {
			return errors.New("App Attest validation category is not allowed")
		}
	}
	if raw, ok := values["apple_bundle_version_01"]; ok {
		version, ok := raw.(string)
		if !ok || len(version) > 128 || strings.TrimSpace(version) == "" {
			return errors.New("invalid App Attest bundle version")
		}
	}
	return nil
}
