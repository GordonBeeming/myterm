#include <stddef.h>
#include <stdint.h>
int mt_sign_removal(const uint8_t *seed, size_t seed_len,
                    const uint8_t *message, size_t message_len,
                    uint8_t *signature, size_t capacity);
int mt_public_key(const uint8_t *seed, size_t seed_len, uint8_t *public_key, size_t capacity);
int mt_verify_signature(const uint8_t *public_key, size_t public_key_len,
                        const uint8_t *message, size_t message_len,
                        const uint8_t *signature, size_t signature_len);
int mt_digest(const uint8_t *message, size_t message_len, uint8_t *digest, size_t capacity);
void mt_clear(uint8_t *bytes, size_t len);
