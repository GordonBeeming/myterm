#ifndef MYTERM_CHANNEL_PROBE_H
#define MYTERM_CHANNEL_PROBE_H
#include <stddef.h>
#include <stdint.h>
typedef struct mt_tls mt_tls;
mt_tls *mt_tls_new(int server, const uint8_t *seed, size_t seed_len,
                   const uint8_t *peer_key, size_t peer_len);
int mt_tls_pump(mt_tls *tls, const uint8_t *input, size_t input_len,
                uint8_t *ciphertext, size_t cipher_capacity, size_t *cipher_len,
                uint8_t *plaintext, size_t plain_capacity, size_t *plain_len);
int mt_tls_write(mt_tls *tls, const uint8_t *input, size_t input_len);
int mt_tls_update(mt_tls *tls);
int mt_tls_open(mt_tls *tls);
int mt_tls_fingerprint(mt_tls *tls, uint8_t *output, size_t capacity);
void mt_tls_free(mt_tls *tls);
const char *mt_tls_last_error(void);
size_t mt_tls_updates_sent(mt_tls *tls);
size_t mt_tls_updates_received(mt_tls *tls);
#endif
