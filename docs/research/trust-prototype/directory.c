/* Throwaway authenticated HPKE/AES-GCM interop; membership pins are fixtures. */
#include "directory.h"
#include <openssl/aead.h>
#include <openssl/crypto.h>
#include <openssl/hpke.h>
#include <openssl/sha.h>
#include <stdlib.h>
#include <string.h>
struct mt_directory { EVP_HPKE_KEY *key; uint8_t public_key[65]; uint8_t directory_key[32];
    uint8_t key_context[512]; size_t key_context_len; int has_directory_key; };
mt_directory *mt_directory_new(uint8_t *public_key, size_t capacity) {
    if (!public_key || capacity < 65) return NULL;
    mt_directory *recipient = calloc(1, sizeof(*recipient));
    if (!recipient) return NULL;
    recipient->key = EVP_HPKE_KEY_new(); size_t len = 0;
    if (!recipient->key || !EVP_HPKE_KEY_generate(recipient->key, EVP_hpke_p256_hkdf_sha256()) ||
        !EVP_HPKE_KEY_public_key(recipient->key, recipient->public_key, &len, sizeof(recipient->public_key)) || len != 65) {
        mt_directory_free(recipient); return NULL;
    }
    memcpy(public_key, recipient->public_key, 65); return recipient;
}
int mt_directory_open(mt_directory *recipient,
    const uint8_t *sender, size_t sender_len, const uint8_t *context, size_t context_len,
    const uint8_t *enc, size_t enc_len, const uint8_t *wrapped, size_t wrapped_len,
    const uint8_t *snapshot, size_t snapshot_len, uint8_t *plaintext, size_t capacity,
    size_t *plaintext_len, uint8_t *key_digest, size_t digest_capacity) {
    if (!recipient || !sender || sender_len != 65 || !context || context_len > 512 ||
        !enc || enc_len != 65 || !wrapped || wrapped_len != 48 || !snapshot ||
        snapshot_len < 28 || snapshot_len > 4096 || !plaintext || capacity < snapshot_len ||
        !plaintext_len || !key_digest || digest_capacity < 32) return 0;
    *plaintext_len = 0;
    uint8_t info[643]; memcpy(info, context, context_len); info[context_len] = '|';
    const char *digits = "0123456789abcdef";
    for (size_t i = 0; i < 65; ++i) {
        info[context_len+1+2*i] = (uint8_t)digits[recipient->public_key[i] >> 4];
        info[context_len+2+2*i] = (uint8_t)digits[recipient->public_key[i] & 15];
    }
    size_t info_len = context_len + 131;
    uint8_t key[48] = {0}; size_t key_len = 0; int ok = 0;
    EVP_HPKE_CTX *hpke = EVP_HPKE_CTX_new(); EVP_AEAD_CTX *aead = NULL;
    if (!hpke || !EVP_HPKE_CTX_setup_auth_recipient(hpke, recipient->key,
        EVP_hpke_hkdf_sha256(), EVP_hpke_aes_256_gcm(), enc, enc_len, info, info_len, sender, sender_len) ||
        !EVP_HPKE_CTX_open(hpke, key, &key_len, sizeof(key), wrapped, wrapped_len, info, info_len) || key_len != 32) goto done;
    aead = EVP_AEAD_CTX_new(EVP_aead_aes_256_gcm(), key, key_len, EVP_AEAD_DEFAULT_TAG_LENGTH);
    if (!aead || !EVP_AEAD_CTX_open(aead, plaintext, plaintext_len, capacity,
        snapshot, 12, snapshot+12, snapshot_len-12, context, context_len)) goto done;
    if (!SHA256(key, key_len, key_digest)) goto done;
    memcpy(recipient->directory_key, key, 32); recipient->has_directory_key = 1;
    memcpy(recipient->key_context, context, context_len); recipient->key_context_len = context_len;
    ok = 1;
done:
    OPENSSL_cleanse(key, sizeof(key)); EVP_AEAD_CTX_free(aead); EVP_HPKE_CTX_free(hpke);
    if (!ok) { OPENSSL_cleanse(plaintext, capacity); *plaintext_len = 0; }
    return ok;
}
int mt_directory_delegate(mt_directory *holder, const uint8_t *recipient_key, size_t recipient_len,
    const uint8_t *context, size_t context_len, uint8_t *enc, size_t enc_capacity, size_t *enc_len,
    uint8_t *wrapped, size_t wrapped_capacity, size_t *wrapped_len) {
    if (!holder || !holder->has_directory_key || !recipient_key || recipient_len != 65 ||
        !context || context_len > 512 || !enc || enc_capacity < 65 || !enc_len ||
        !wrapped || wrapped_capacity < 48 || !wrapped_len || context_len != holder->key_context_len ||
        CRYPTO_memcmp(context, holder->key_context, context_len) != 0) return 0;
    uint8_t info[643]; memcpy(info, context, context_len); info[context_len] = '|';
    const char *digits = "0123456789abcdef";
    for (size_t i=0; i<65; ++i) {
        info[context_len+1+2*i] = (uint8_t)digits[recipient_key[i] >> 4];
        info[context_len+2+2*i] = (uint8_t)digits[recipient_key[i] & 15];
    }
    size_t len = context_len + 131;
    EVP_HPKE_CTX *hpke = EVP_HPKE_CTX_new();
    int ok = hpke && EVP_HPKE_CTX_setup_auth_sender(hpke, enc, enc_len, enc_capacity,
        holder->key, EVP_hpke_hkdf_sha256(), EVP_hpke_aes_256_gcm(), recipient_key, recipient_len, info, len) &&
        EVP_HPKE_CTX_seal(hpke, wrapped, wrapped_len, wrapped_capacity, holder->directory_key, 32, info, len);
    EVP_HPKE_CTX_free(hpke); return ok;
}
void mt_directory_free(mt_directory *recipient) {
    if (!recipient) return;
    EVP_HPKE_KEY_free(recipient->key); OPENSSL_cleanse(recipient, sizeof(*recipient)); free(recipient);
}
