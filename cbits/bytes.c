#include "hs_bytes.h"

int hs_memcmp(char *a, 
            size_t aoff,
            char *b, 
            size_t boff,
            size_t n) {
    a += aoff;
    b += boff;
    return memcmp(a, b, n);
}

size_t hs_memchr(char *a, 
            size_t aoff,
            char b, 
            size_t n) {
    a += aoff;
    return (char*)memchr(a, b, n) - a;
}


int is_byte_array_pinned(unsigned char* p){
    return Bdescr((StgPtr)p)->flags & (BF_PINNED | BF_LARGE);
}
