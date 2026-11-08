/* Throwaway TLS 1.3 probe. Endpoint key pins come from trusted test fixtures. */
#include "channel.h"
#include <openssl/bio.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct mt_tls { SSL_CTX *context; SSL *ssl; uint8_t peer[32]; size_t updates_sent; size_t updates_received; };
static pthread_once_t index_once = PTHREAD_ONCE_INIT;
static int context_index = -1;
static void make_index(void) { context_index = SSL_get_ex_new_index(0, NULL, NULL, NULL, NULL); }
static void observe_message(int write, int version, int content_type, const void *buffer,
                            size_t len, SSL *ssl, void *arg) {
    (void)ssl;
    mt_tls *tls = arg;
    if (version == TLS1_3_VERSION && content_type == SSL3_RT_HANDSHAKE && len >= 5 &&
        ((const uint8_t *)buffer)[0] == SSL3_MT_KEY_UPDATE) {
        if (write) tls->updates_sent++; else tls->updates_received++;
    }
}

static enum ssl_verify_result_t verify_pin(SSL *ssl, uint8_t *alert) {
    mt_tls *tls = SSL_get_ex_data(ssl, context_index);
    STACK_OF(X509) *chain = SSL_get_peer_full_cert_chain(ssl);
    if (!tls || !chain || sk_X509_num(chain) < 1) return ssl_verify_invalid;
    X509 *certificate = sk_X509_value(chain, 0);
    EVP_PKEY *key = X509_get_pubkey(certificate);
    uint8_t raw[32]; size_t len = sizeof(raw);
    int valid = key && EVP_PKEY_id(key) == EVP_PKEY_ED25519 &&
        EVP_PKEY_get_raw_public_key(key, raw, &len) && len == sizeof(raw) &&
        CRYPTO_memcmp(raw, tls->peer, sizeof(raw)) == 0 &&
        X509_cmp_current_time(X509_get0_notBefore(certificate)) < 0 &&
        X509_cmp_current_time(X509_get0_notAfter(certificate)) > 0;
    EVP_PKEY_free(key);
    if (!valid) *alert = SSL_AD_BAD_CERTIFICATE;
    return valid ? ssl_verify_ok : ssl_verify_invalid;
}

mt_tls *mt_tls_new(int server, const uint8_t *seed, size_t seed_len,
                   const uint8_t *peer_key, size_t peer_len) {
    if (!seed || seed_len != 32 || !peer_key || peer_len != 32 ||
        pthread_once(&index_once, make_index) != 0 || context_index < 0) return NULL;
    mt_tls *tls = calloc(1, sizeof(*tls));
    if (!tls) return NULL;
    memcpy(tls->peer, peer_key, sizeof(tls->peer));
    EVP_PKEY *identity = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, seed, seed_len);
    X509 *certificate = X509_new();
    tls->context = SSL_CTX_new(TLS_method());
    if (!identity || !certificate || !tls->context ||
        !X509_set_version(certificate, 2) || !ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1) ||
        !X509_gmtime_adj(X509_getm_notBefore(certificate), -60) ||
        !X509_gmtime_adj(X509_getm_notAfter(certificate), 3600) ||
        !X509_set_pubkey(certificate, identity)) goto fail;
    X509_NAME *name = X509_get_subject_name(certificate);
    if (!name || !X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
        (const uint8_t *)"MyTerm disposable endpoint", -1, -1, 0) ||
        !X509_set_issuer_name(certificate, name) || !X509_sign(certificate, identity, NULL) ||
        !SSL_CTX_use_certificate(tls->context, certificate) ||
        !SSL_CTX_use_PrivateKey(tls->context, identity) ||
        !SSL_CTX_check_private_key(tls->context) ||
        !SSL_CTX_set_min_proto_version(tls->context, TLS1_3_VERSION) ||
        !SSL_CTX_set_max_proto_version(tls->context, TLS1_3_VERSION) ||
        !SSL_CTX_set_num_tickets(tls->context, 0)) goto fail;
    SSL_CTX_set_options(tls->context, SSL_OP_NO_TICKET);
    SSL_CTX_set_session_cache_mode(tls->context, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_early_data_enabled(tls->context, 0);
    const uint16_t identity_algorithm = SSL_SIGN_ED25519;
    if (!SSL_CTX_set_signing_algorithm_prefs(tls->context, &identity_algorithm, 1) ||
        !SSL_CTX_set_verify_algorithm_prefs(tls->context, &identity_algorithm, 1)) goto fail;
    SSL_CTX_set_custom_verify(tls->context, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, verify_pin);
    SSL_CTX_set_msg_callback(tls->context, observe_message);
    SSL_CTX_set_msg_callback_arg(tls->context, tls);
    tls->ssl = SSL_new(tls->context);
    if (!tls->ssl || !SSL_set_ex_data(tls->ssl, context_index, tls)) goto fail;
    BIO *incoming = BIO_new(BIO_s_mem()), *outgoing = BIO_new(BIO_s_mem());
    if (!incoming || !outgoing) { BIO_free(incoming); BIO_free(outgoing); goto fail; }
    BIO_set_mem_eof_return(incoming, -1);
    SSL_set_bio(tls->ssl, incoming, outgoing);
    if (server) SSL_set_accept_state(tls->ssl); else SSL_set_connect_state(tls->ssl);
    EVP_PKEY_free(identity); X509_free(certificate);
    return tls;
fail:
    EVP_PKEY_free(identity); X509_free(certificate); mt_tls_free(tls); return NULL;
}

static int waiting(SSL *ssl, int result) {
    int error = SSL_get_error(ssl, result);
    return error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE;
}

const char *mt_tls_last_error(void) { return ERR_reason_error_string(ERR_peek_last_error()); }
size_t mt_tls_updates_sent(mt_tls *tls) { return tls ? tls->updates_sent : 0; }
size_t mt_tls_updates_received(mt_tls *tls) { return tls ? tls->updates_received : 0; }

int mt_tls_pump(mt_tls *tls, const uint8_t *input, size_t input_len,
                uint8_t *ciphertext, size_t cipher_capacity, size_t *cipher_len,
                uint8_t *plaintext, size_t plain_capacity, size_t *plain_len) {
    if (!tls || !ciphertext || !plaintext || !cipher_len || !plain_len ||
        input_len > 1024*1024 || (input_len && !input)) return 0;
    *cipher_len = 0; *plain_len = 0;
    if (input_len && BIO_write(SSL_get_rbio(tls->ssl), input, (int)input_len) != (int)input_len) return 0;
    ERR_clear_error();
    if (!SSL_is_init_finished(tls->ssl)) {
        int result = SSL_do_handshake(tls->ssl);
        if (result != 1 && !waiting(tls->ssl, result)) return 0;
    }
    if (SSL_is_init_finished(tls->ssl)) {
        for (;;) {
            uint8_t buffer[16384];
            ERR_clear_error();
            int result = SSL_read(tls->ssl, buffer, sizeof(buffer));
            if (result > 0) {
                if ((size_t)result > plain_capacity - *plain_len) return 0;
                memcpy(plaintext + *plain_len, buffer, (size_t)result);
                *plain_len += (size_t)result;
            } else {
                if (!waiting(tls->ssl, result)) return 0;
                break;
            }
        }
    }
    size_t pending = BIO_ctrl_pending(SSL_get_wbio(tls->ssl));
    if (pending > cipher_capacity || pending > 1024*1024) return 0;
    if (pending) {
        int result = BIO_read(SSL_get_wbio(tls->ssl), ciphertext, (int)pending);
        if (result <= 0 || (size_t)result != pending) return 0;
        *cipher_len = pending;
    }
    return 1;
}

int mt_tls_open(mt_tls *tls) {
    return tls && SSL_is_init_finished(tls->ssl) && SSL_version(tls->ssl) == TLS1_3_VERSION &&
        !SSL_session_reused(tls->ssl);
}
int mt_tls_write(mt_tls *tls, const uint8_t *input, size_t input_len) {
    if (!mt_tls_open(tls) || !input || input_len == 0 || input_len > 65536) return 0;
    ERR_clear_error();
    return SSL_write(tls->ssl, input, (int)input_len) == (int)input_len;
}
int mt_tls_update(mt_tls *tls) {
    return mt_tls_open(tls) && SSL_key_update(tls->ssl, SSL_KEY_UPDATE_REQUESTED);
}
int mt_tls_fingerprint(mt_tls *tls, uint8_t *output, size_t capacity) {
    if (!mt_tls_open(tls) || !output || capacity < SHA256_DIGEST_LENGTH) return 0;
    uint8_t observation[32];
    const char *label = "EXPORTER-myterm-prototype-observation";
    if (!SSL_export_keying_material(tls->ssl, observation, sizeof(observation),
                                    label, strlen(label), NULL, 0, 0)) return 0;
    int ok = SHA256(observation, sizeof(observation), output) != NULL;
    OPENSSL_cleanse(observation, sizeof(observation));
    return ok;
}
void mt_tls_free(mt_tls *tls) {
    if (!tls) return;
    SSL_free(tls->ssl); SSL_CTX_free(tls->context);
    OPENSSL_cleanse(tls, sizeof(*tls)); free(tls);
}
