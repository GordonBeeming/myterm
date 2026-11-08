/* Throwaway protocol probe. This composition has not had a security audit. */
#include "bridge.h"
#include <openssl/curve25519.h>
#include <openssl/crypto.h>
#include <openssl/hmac.h>
#include <openssl/sha.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct mt_pake {
    SPAKE2_CTX *ctx;
    int approver;
    int finished;
    uint8_t key[SPAKE2_MAX_KEY_SIZE];
    size_t key_len;
};

static void hex_encode(const uint8_t *in, size_t len, char *out) {
    const char *digits = "0123456789abcdef";
    for (size_t i = 0; i < len; ++i) {
        out[2*i] = digits[in[i] >> 4];
        out[2*i+1] = digits[in[i] & 15];
    }
    out[2*len] = 0;
}

static int digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static int hex_decode(const char *in, uint8_t *out, size_t capacity, size_t *len) {
    size_t n = strlen(in);
    if (n % 2 || n / 2 > capacity) return 0;
    for (size_t i = 0; i < n / 2; ++i) {
        int a = digit(in[2*i]), b = digit(in[2*i+1]);
        if (a < 0 || b < 0) return 0;
        out[i] = (uint8_t)((a << 4) | b);
    }
    *len = n / 2;
    return 1;
}

mt_pake *mt_start(int approver, const char *code, const char *binding, char *message, size_t capacity) {
    if (!code || !binding || !message || capacity < 2 * SPAKE2_MAX_MSG_SIZE + 1 ||
        strlen(code) == 0 || strlen(code) > 128 || strlen(binding) > 4096) return NULL;
    mt_pake *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->approver = approver != 0;
    // The same canonical binding identifies the account, request, roles and public keys.
    size_t n = strlen(binding);
    char *new_id = malloc(n + 5), *approver_id = malloc(n + 10);
    if (!new_id || !approver_id) {
        free(new_id); free(approver_id); free(p); return NULL;
    }
    memcpy(new_id, "new:", 4); memcpy(new_id+4, binding, n+1);
    memcpy(approver_id, "approver:", 9); memcpy(approver_id+9, binding, n+1);
    const char *mine = p->approver ? approver_id : new_id;
    const char *peer = p->approver ? new_id : approver_id;
    p->ctx = SPAKE2_CTX_new(p->approver ? spake2_role_bob : spake2_role_alice,
                          (const uint8_t *)mine, strlen(mine),
                          (const uint8_t *)peer, strlen(peer));
    free(new_id); free(approver_id);
    uint8_t msg[SPAKE2_MAX_MSG_SIZE]; size_t msg_len = 0;
    if (!p->ctx || !SPAKE2_generate_msg(p->ctx, msg, &msg_len, sizeof(msg),
                                       (const uint8_t *)code, strlen(code))) {
        mt_free(p); return NULL;
    }
    hex_encode(msg, msg_len, message);
    return p;
}

static int confirmation(mt_pake *p, int approver, uint8_t *out) {
    const char *label = approver ? "myterm-prototype-v0/approver-confirm" :
                                   "myterm-prototype-v0/new-confirm";
    unsigned int len = 0;
    return HMAC(EVP_sha256(), p->key, p->key_len, (const uint8_t *)label,
                strlen(label), out, &len) != NULL && len == SHA256_DIGEST_LENGTH;
}

int mt_finish(mt_pake *p, const char *peer_message, char *proof, size_t capacity) {
    uint8_t msg[SPAKE2_MAX_MSG_SIZE], mac[SHA256_DIGEST_LENGTH]; size_t len;
    if (!p || !peer_message || !proof || capacity < 2 * SHA256_DIGEST_LENGTH + 1 ||
        p->finished || !hex_decode(peer_message, msg, sizeof(msg), &len)) return 0;
    p->finished = 1;
    if (!SPAKE2_process_msg(p->ctx, p->key, &p->key_len, sizeof(p->key), msg, len) ||
        !confirmation(p, p->approver, mac)) return 0;
    hex_encode(mac, sizeof(mac), proof);
    p->finished = 2;
    return 1;
}

int mt_verify(mt_pake *p, const char *peer_proof) {
    uint8_t received[SHA256_DIGEST_LENGTH], expected[SHA256_DIGEST_LENGTH]; size_t len;
    if (!p || !peer_proof || p->finished != 2 || p->key_len == 0 ||
        !hex_decode(peer_proof, received, sizeof(received), &len) ||
        len != sizeof(received) || !confirmation(p, !p->approver, expected)) return 0;
    return CRYPTO_memcmp(received, expected, sizeof(expected)) == 0;
}

void mt_free(mt_pake *p) {
    if (!p) return;
    SPAKE2_CTX_free(p->ctx);
    OPENSSL_cleanse(p, sizeof(*p));
    free(p);
}
