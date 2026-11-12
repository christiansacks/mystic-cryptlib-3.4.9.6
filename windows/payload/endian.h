/* endian.h for MinGW cross builds of cryptlib (x86 is little-endian) */
#ifndef CL_MINGW_ENDIAN_H
#define CL_MINGW_ENDIAN_H
#define LITTLE_ENDIAN 1234
#define BIG_ENDIAN 4321
#define BYTE_ORDER LITTLE_ENDIAN
#endif
