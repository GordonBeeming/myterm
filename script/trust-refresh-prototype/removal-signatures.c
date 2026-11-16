/* Throwaway deterministic Ed25519 signer; fixture seeds never leave process memory. */
#include "removal-signatures.h"
#include <openssl/crypto.h>
#include <openssl/curve25519.h>
#include <openssl/sha.h>

int mt_sign_removal(const uint8_t *seed, size_t seed_len,
                    const uint8_t *message, size_t message_len,
                    uint8_t *signature, size_t capacity) {
    if (!seed || seed_len != 32 || !message || !signature || capacity < 64) return 0;
    uint8_t public_key[32], private_key[64];
    ED25519_keypair_from_seed(public_key, private_key, seed);
    int ok = ED25519_sign(signature, message, message_len, private_key);
    OPENSSL_cleanse(private_key, sizeof(private_key));
    return ok;
}

int mt_public_key(const uint8_t *seed, size_t seed_len, uint8_t *public_key, size_t capacity) {
    if (!seed || seed_len != 32 || !public_key || capacity < 32) return 0;
    uint8_t private_key[64];
    ED25519_keypair_from_seed(public_key, private_key, seed);
    OPENSSL_cleanse(private_key, sizeof(private_key));
    return 1;
}

int mt_verify_signature(const uint8_t *public_key, size_t public_key_len,
                        const uint8_t *message, size_t message_len,
                        const uint8_t *signature, size_t signature_len) {
    if (!public_key || public_key_len != 32 || !message || !signature || signature_len != 64) return 0;
    return ED25519_verify(message, message_len, signature, public_key);
}

int mt_digest(const uint8_t *message, size_t message_len, uint8_t *digest, size_t capacity) {
    if (!message || !digest || capacity < SHA256_DIGEST_LENGTH) return 0;
    return SHA256(message, message_len, digest) != NULL;
}

void mt_clear(uint8_t *bytes, size_t len) {
    if (bytes) OPENSSL_cleanse(bytes, len);
}
