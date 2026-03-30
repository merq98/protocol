package reality

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rsa"
	"crypto/x509"
	"encoding/asn1"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/url"
	"strconv"
	"sync"
	"time"

	utls "github.com/refraction-networking/utls"
)

var GlobalTargetCertProfiles sync.Map
var GlobalTargetCertProfileMu sync.Map

const targetCertProfileMaxAge = 6 * time.Hour

type TargetCertProfile struct {
	Certificates                []*x509.Certificate
	RawCertificates             [][]byte
	OCSPStaple                  []byte
	SignedCertificateTimestamps [][]byte
	CapturedAt                  time.Time
}

func targetCertProfileKey(dest, sni string) string {
	return dest + " " + sni
}

func DetectTargetCertificateProfiles(config *Config) {
	type destSNI struct {
		Dest string
		SNI  string
	}
	var pairs []destSNI

	if config.Targets != nil && config.Targets.Len() > 0 {
		config.Targets.mu.RLock()
		for _, t := range config.Targets.targets {
			for sni := range t.ServerNames {
				pairs = append(pairs, destSNI{Dest: t.Dest, SNI: sni})
			}
		}
		config.Targets.mu.RUnlock()
	} else if config.Dest != "" {
		for sni := range config.ServerNames {
			pairs = append(pairs, destSNI{Dest: config.Dest, SNI: sni})
		}
	}

	for _, pair := range pairs {
		key := targetCertProfileKey(pair.Dest, pair.SNI)
		if _, loaded := GlobalTargetCertProfiles.LoadOrStore(key, false); loaded {
			continue
		}

		go func(dest, sni, cacheKey string) {
			profile, err := captureTargetCertificateProfile(config.Type, dest, sni)
			if err != nil {
				GlobalTargetCertProfiles.Delete(cacheKey)
				if config.Show {
					fmt.Printf("REALITY cert camouflage: failed to capture %v/%v: %v\n", dest, sni, err)
				}
				return
			}
			GlobalTargetCertProfiles.Store(cacheKey, profile)
			if config.Show {
				fmt.Printf("REALITY cert camouflage: captured %v/%v (%d certs)\n", dest, sni, len(profile.RawCertificates))
			}
		}(pair.Dest, pair.SNI, key)
	}
}

func captureTargetCertificateProfile(networkType, dest, sni string) (*TargetCertProfile, error) {
	conn, err := net.DialTimeout(networkType, dest, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", dest, err)
	}
	defer conn.Close()

	uConn := utls.UClient(conn, &utls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true,
		NextProtos:         []string{"h2", "http/1.1"},
	}, utls.HelloChrome_Auto)

	uConn.SetDeadline(time.Now().Add(15 * time.Second))
	if err := uConn.Handshake(); err != nil {
		return nil, fmt.Errorf("handshake with %s/%s: %w", dest, sni, err)
	}

	state := uConn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return nil, fmt.Errorf("no peer certificates from %s/%s", dest, sni)
	}

	profile := &TargetCertProfile{
		Certificates:                make([]*x509.Certificate, len(state.PeerCertificates)),
		RawCertificates:             make([][]byte, len(state.PeerCertificates)),
		OCSPStaple:                  append([]byte(nil), state.OCSPResponse...),
		SignedCertificateTimestamps: cloneByteSlices(state.SignedCertificateTimestamps),
		CapturedAt:                  time.Now(),
	}
	copy(profile.Certificates, state.PeerCertificates)
	for i, cert := range state.PeerCertificates {
		profile.RawCertificates[i] = append([]byte(nil), cert.Raw...)
	}

	return profile, nil
}

func getTargetCertificateProfile(dest, sni string) *TargetCertProfile {
	val, ok := GlobalTargetCertProfiles.Load(targetCertProfileKey(dest, sni))
	if !ok {
		return nil
	}
	profile, ok := val.(*TargetCertProfile)
	if !ok {
		return nil
	}
	return profile
}

func ensureTargetCertificateProfile(networkType, dest, sni string, show bool) (*TargetCertProfile, error) {
	if profile := getTargetCertificateProfile(dest, sni); profile != nil && !targetCertProfileExpired(profile) {
		return profile, nil
	}

	cacheKey := targetCertProfileKey(dest, sni)
	muAny, _ := GlobalTargetCertProfileMu.LoadOrStore(cacheKey, &sync.Mutex{})
	mu := muAny.(*sync.Mutex)
	mu.Lock()
	defer func() {
		mu.Unlock()
		GlobalTargetCertProfileMu.Delete(cacheKey)
	}()

	if profile := getTargetCertificateProfile(dest, sni); profile != nil && !targetCertProfileExpired(profile) {
		return profile, nil
	}

	profile, err := captureTargetCertificateProfile(networkType, dest, sni)
	if err != nil {
		return nil, err
	}
	GlobalTargetCertProfiles.Store(cacheKey, profile)
	if show {
		fmt.Printf("REALITY cert camouflage: refreshed %v/%v (%d certs)\n", dest, sni, len(profile.RawCertificates))
	}
	return profile, nil
}

func targetCertProfileExpired(profile *TargetCertProfile) bool {
	if profile == nil {
		return true
	}
	if profile.CapturedAt.IsZero() {
		return false
	}
	return time.Since(profile.CapturedAt) > targetCertProfileMaxAge
}

func buildCamouflageCertificate(profile *TargetCertProfile, r io.Reader) (*Certificate, error) {
	if profile == nil || len(profile.Certificates) == 0 {
		return nil, fmt.Errorf("missing target certificate profile")
	}

	realChain := profile.Certificates
	signers := make([]crypto.Signer, len(realChain))
	templates := make([]*x509.Certificate, len(realChain))

	for i, cert := range realChain {
		signer, err := generateSignerLike(cert.PublicKey, r)
		if err != nil {
			return nil, err
		}
		signers[i] = signer
		templates[i] = cloneCertificateTemplate(cert)
	}

	rootSigner, err := generateSignerLike(realChain[len(realChain)-1].PublicKey, r)
	if err != nil {
		return nil, err
	}
	rootTemplate := fakeRootTemplate(realChain[len(realChain)-1])

	camouflageChain := make([][]byte, len(realChain))
	for i := len(realChain) - 1; i >= 0; i-- {
		parentTemplate := rootTemplate
		parentSigner := rootSigner
		if i+1 < len(realChain) {
			parentTemplate = templates[i+1]
			parentSigner = signers[i+1]
		}

		der, err := x509.CreateCertificate(r, templates[i], parentTemplate, publicKeyFromSigner(signers[i]), parentSigner)
		if err != nil {
			return nil, err
		}
		camouflageChain[i] = der
	}

	leaf, err := x509.ParseCertificate(camouflageChain[0])
	if err != nil {
		return nil, err
	}

	return &Certificate{
		Certificate:                 camouflageChain,
		PrivateKey:                  signers[0],
		OCSPStaple:                  append([]byte(nil), profile.OCSPStaple...),
		SignedCertificateTimestamps: cloneByteSlices(profile.SignedCertificateTimestamps),
		Leaf:                        leaf,
	}, nil
}

func generateSignerLike(publicKey any, r io.Reader) (crypto.Signer, error) {
	switch key := publicKey.(type) {
	case *rsa.PublicKey:
		bits := key.N.BitLen()
		if bits < 2048 {
			bits = 2048
		}
		return rsa.GenerateKey(r, bits)
	case *ecdsa.PublicKey:
		return ecdsa.GenerateKey(key.Curve, r)
	case ed25519.PublicKey:
		_, priv, err := ed25519.GenerateKey(r)
		return priv, err
	default:
		_, priv, err := ed25519.GenerateKey(r)
		return priv, err
	}
}

func publicKeyFromSigner(signer crypto.Signer) crypto.PublicKey {
	return signer.Public()
}

func fakeRootTemplate(real *x509.Certificate) *x509.Certificate {
	serial := cloneBigInt(real.SerialNumber)
	if serial == nil || serial.Sign() == 0 {
		serial = big.NewInt(1)
	}
	return &x509.Certificate{
		SerialNumber:          serial,
		Subject:               real.Issuer,
		NotBefore:             real.NotBefore,
		NotAfter:              real.NotAfter,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            real.MaxPathLen,
		MaxPathLenZero:        real.MaxPathLenZero,
	}
}

func cloneCertificateTemplate(real *x509.Certificate) *x509.Certificate {
	serial := cloneBigInt(real.SerialNumber)
	if serial == nil || serial.Sign() == 0 {
		serial = big.NewInt(1)
	}

	return &x509.Certificate{
		SerialNumber:                serial,
		Subject:                     real.Subject,
		NotBefore:                   real.NotBefore,
		NotAfter:                    real.NotAfter,
		KeyUsage:                    real.KeyUsage,
		ExtKeyUsage:                 append([]x509.ExtKeyUsage(nil), real.ExtKeyUsage...),
		UnknownExtKeyUsage:          cloneOIDs(real.UnknownExtKeyUsage),
		BasicConstraintsValid:       real.BasicConstraintsValid,
		IsCA:                        real.IsCA,
		MaxPathLen:                  real.MaxPathLen,
		MaxPathLenZero:              real.MaxPathLenZero,
		DNSNames:                    append([]string(nil), real.DNSNames...),
		EmailAddresses:              append([]string(nil), real.EmailAddresses...),
		IPAddresses:                 cloneIPs(real.IPAddresses),
		URIs:                        cloneURLs(real.URIs),
		PermittedDNSDomainsCritical: real.PermittedDNSDomainsCritical,
		PermittedDNSDomains:         append([]string(nil), real.PermittedDNSDomains...),
		CRLDistributionPoints:       append([]string(nil), real.CRLDistributionPoints...),
		PolicyIdentifiers:           cloneOIDs(real.PolicyIdentifiers),
		OCSPServer:                  append([]string(nil), real.OCSPServer...),
		IssuingCertificateURL:       append([]string(nil), real.IssuingCertificateURL...),
		SubjectKeyId:                append([]byte(nil), real.SubjectKeyId...),
		AuthorityKeyId:              append([]byte(nil), real.AuthorityKeyId...),
	}
}

func cloneBigInt(v *big.Int) *big.Int {
	if v == nil {
		return nil
	}
	return new(big.Int).Set(v)
}

func cloneOIDs(src []asn1.ObjectIdentifier) []asn1.ObjectIdentifier {
	if src == nil {
		return nil
	}
	out := make([]asn1.ObjectIdentifier, len(src))
	for i, oid := range src {
		out[i] = append(asn1.ObjectIdentifier(nil), oid...)
	}
	return out
}

func cloneIPs(src []net.IP) []net.IP {
	if src == nil {
		return nil
	}
	out := make([]net.IP, len(src))
	for i, ip := range src {
		out[i] = append(net.IP(nil), ip...)
	}
	return out
}

func cloneURLs(src []*url.URL) []*url.URL {
	if src == nil {
		return nil
	}
	out := make([]*url.URL, len(src))
	for i, u := range src {
		if u == nil {
			continue
		}
		v := *u
		out[i] = &v
	}
	return out
}

func cloneByteSlices(src [][]byte) [][]byte {
	if src == nil {
		return nil
	}
	out := make([][]byte, len(src))
	for i, b := range src {
		out[i] = append([]byte(nil), b...)
	}
	return out
}

func certProfileStatus(profile *TargetCertProfile) string {
	if profile == nil {
		return "missing"
	}
	return strconv.Itoa(len(profile.RawCertificates))
}
