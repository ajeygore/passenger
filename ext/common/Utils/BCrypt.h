/*
 * Copyright 1997 Niels Provos <provos@physnet.uni-hamburg.de>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. All advertising materials mentioning features or use of this software
 *    must display the following acknowledgement:
 *      This product includes software developed by Niels Provos.
 * 4. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Modified by <hongli@phusion.nl> on 2009-10-24:
 *
 *   - Wrapped into C++ namespace.
 *   - Changed some types (e.g. u_int8_t to uint8_t as defined in stdint.h)
 *     for easier compilation.
 *   - Moved some macros to the .c file.
 */

#ifndef _PASSENGER_BCRYPT_H_
#define _PASSENGER_BCRYPT_H_

#include <stdint.h>

#define BCRYPT_MAXSALT 16	/* Precomputation is just so nice */
#define BCRYPT_SALT_OUTPUT_SIZE  (7 + (BCRYPT_MAXSALT * 4 + 2) / 3 + 1)
#define BCRYPT_OUTPUT_SIZE 128

/*
 * Given a logarithmic cost parameter, generates a salt for use with bcrypt().
 *
 * output: the computed salt will be stored here. This buffer must be
 *         at least BCRYPT_SALT_OUTPUT_SIZE bytes. The result will be
 *         null-terminated.
 * log_rounds: the logarithmic cost.
 * rseed: a seed of BCRYPT_MAXSALT bytes. Should be obtained from a
 *        cryptographically secure random source.
 * Returns: output
 */
char *bcrypt_gensalt(char *output, unsigned int log_rounds, uint8_t *rseed);

/*
 * Given a secret and a salt, generates a salted hash (which you can then store safely).
 *
 * output: the computed salted hash will be stored here. This buffer must
 *         be at least BCRYPT_OUTPUT_SIZE bytes, and will become null-terminated.
 * key: A null-terminated secret.
 * salt: The salt, as generated by bcrypt_gensalt().
 * Returns: output on success, NULL on error.
 */
char *bcrypt(char *output, const char *key, const char *salt);

#endif /* _PASSENGER_BCRYPT_H_ */
