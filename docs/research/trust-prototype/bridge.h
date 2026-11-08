#ifndef MYTERM_TRUST_PROTOTYPE_BRIDGE_H
#define MYTERM_TRUST_PROTOTYPE_BRIDGE_H
#include <stddef.h>

typedef struct mt_pake mt_pake;
mt_pake *mt_start(int approver, const char *code, const char *binding, char *message, size_t capacity);
int mt_finish(mt_pake *pake, const char *peer_message, char *proof, size_t capacity);
int mt_verify(mt_pake *pake, const char *peer_proof);
void mt_free(mt_pake *pake);

#endif
