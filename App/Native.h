#include <stdint.h>
void *ar_sudachi_create(const char *directory);
char *ar_sudachi_tokenize(void *engine, const char *text);
void ar_sudachi_free_string(char *text);
void ar_sudachi_destroy(void *engine);
