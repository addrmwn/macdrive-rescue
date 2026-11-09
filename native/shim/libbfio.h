/* Shim minimal: header publik libfsapfs/libfshfs menyertakan <libbfio.h>
 * yang biasanya digenerate oleh build system libyal. Karena kita menautkan
 * libbfio secara statis (HAVE_LOCAL_LIBBFIO), cukup sediakan tipe opaque-nya.
 */
#ifndef _SHIM_LIBBFIO_H
#define _SHIM_LIBBFIO_H

#include <stdint.h>

typedef intptr_t libbfio_handle_t;

#endif /* _SHIM_LIBBFIO_H */