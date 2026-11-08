#ifndef MYTERM_DIRECTORY_PROBE_H
#define MYTERM_DIRECTORY_PROBE_H
#include <stddef.h>
#include <stdint.h>
typedef struct mt_directory mt_directory;
mt_directory *mt_directory_new(uint8_t *public_key, size_t capacity);
int mt_directory_open(mt_directory *recipient,
    const uint8_t *sender, size_t sender_len, const uint8_t *context, size_t context_len,
    const uint8_t *enc, size_t enc_len, const uint8_t *wrapped, size_t wrapped_len,
    const uint8_t *snapshot, size_t snapshot_len, uint8_t *plaintext, size_t capacity,
    size_t *plaintext_len, uint8_t *key_digest, size_t digest_capacity);
void mt_directory_free(mt_directory *recipient);
int mt_directory_delegate(mt_directory *holder, const uint8_t *recipient_key, size_t recipient_len,
    const uint8_t *context, size_t context_len, uint8_t *enc, size_t enc_capacity, size_t *enc_len,
    uint8_t *wrapped, size_t wrapped_capacity, size_t *wrapped_len);
#endif
