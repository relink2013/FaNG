/* -*-  mode:c; tab-width:8; c-basic-offset:8; indent-tabs-mode:nil;  -*- */
/*
   Copyright (C) 2019 by Ronnie Sahlberg <ronniesahlberg@gmail.com>

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU Lesser General Public License as published by
   the Free Software Foundation; either version 2.1 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public License
   along with this program; if not, see <http://www.gnu.org/licenses/>.
*/
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#ifdef HAVE_STDINT_H
#include <stdint.h>
#endif

#ifdef HAVE_ARPA_INET_H
#include <arpa/inet.h>
#endif 

#include <stdio.h>
#include <string.h>

#include "compat.h"

#include "portable-endian.h"
#include "aes.h"

static void aes_ccm_generate_b0(unsigned char *nonce, size_t nlen,
                                size_t alen, size_t plen, size_t mlen,
                                unsigned char *buf)
{
        uint32_t len;

        memset(buf, 0, 16);
        if (alen) {
                buf[0] |= 0x40;                   /* Adata */
        }
        buf[0] |= (((mlen - 2) / 2) << 3) & 0x38; /* M' */
        buf[0] |= (15 - nlen - 1) & 0x07;         /* L' */

        len = htobe32((uint32_t)plen);
        memcpy(&buf[12], &len, 4);
        memcpy(&buf[1], nonce, nlen);
}

static inline void bxory(unsigned char *b, unsigned char *y, size_t num)
{
        int i;

        for(i = 0; i < (int)num; i++) {
                b[i] = b[i] ^ y[i];
        }
}

static void ccm_generate_T(unsigned char *key,
                           unsigned char *nonce, size_t nlen,
                           unsigned char *aad, size_t alen,
                           unsigned char *p, size_t plen,
                           unsigned char *m, size_t mlen)
{
        unsigned char b[16] _U_, y[16]_U_;
        uint16_t l;

        aes_ccm_generate_b0(nonce, nlen, alen, plen, mlen, &b[0]);
        AES128_ECB_encrypt(b, key, y);

        /* Create Aad */
        if (alen) {
                /* First block */
                memset(b, 0, 16);
                l = htobe16((uint16_t)alen);
                memcpy(b, &l, 2);

                l = (alen > 14) ? 14 : (uint16_t)alen;
                memcpy(&b[2], aad, l);
                aad  += l;
                alen -= l;

                bxory(b, y, 16);
                AES128_ECB_encrypt(b, key, y);

                while (alen) {
                        memset(b, 0, 16);
                        l = (alen > 16) ? 16 : (uint16_t)alen;
                        memcpy(b, aad, l);
                        aad  += l;
                        alen -= l;

                        bxory(b, y, 16);
                        AES128_ECB_encrypt(b, key, y);
                }
        }

        /* Create Payload */
        while (plen) {
                memset(b, 0, 16);
                l = (plen > 16) ? 16 : (uint16_t)plen;
                memcpy(b, p, l);
                p    += l;
                plen -= l;

                bxory(b, y, 16);
                AES128_ECB_encrypt(b, key, y);
        }

        memcpy(m, y, mlen);
}

static void ccm_generate_s(unsigned char *key, unsigned char *nonce, size_t nlen,
                           size_t plen, int i, unsigned char *s)
{
        uint32_t l;

        memset(s, 0, 16);
        s[0] |= (15 - nlen - 1) & 0x07;

        l = htobe32(i);
        memcpy(&s[12], &l, 4);

        memcpy(&s[1], nonce, nlen);

        AES128_ECB_encrypt(s, key, s);
}

static void aes_ccm_crypt(unsigned char *key,
                          unsigned char *nonce, size_t nlen,
                          unsigned char *p, size_t plen)
{
        int j;
        size_t l;
        unsigned char s[16] _U_;

        j = 0;
        while (plen) {
                l = (plen > 16) ? 16 : plen;
                ccm_generate_s(key, nonce, nlen, plen, j + 1, &s[0]);
                bxory(&p[j * 16], &s[0], l);

                j++;
                plen -= l;
        }
}

#if defined(__APPLE__) && !defined(FANG_CCM_GENERIC)
/* FaNG patch: bulk AES-CCM with CommonCrypto (hardware AES). The generic code below runs one AES block at
 * a time, and on Apple each block created and released a CommonCrypto context, which capped every
 * encrypted SMB connection at a few tens of MB/s. Here the payload goes through one CTR pass and one CBC
 * pass (the CBC-MAC), fed in pieces so no copy of the payload is needed. Same output, byte for byte. */
#include <CommonCrypto/CommonCrypto.h>

static int ccm_ctr(unsigned char *key, unsigned char *nonce, size_t nlen, unsigned char *p, size_t plen)
{
        unsigned char counter[16];
        CCCryptorRef c = NULL;
        size_t moved = 0;
        uint32_t one = htobe32(1);
        int ok;

        if (plen == 0) {
                return 0;
        }
        memset(counter, 0, 16);
        counter[0] = (15 - nlen - 1) & 0x07;
        memcpy(&counter[1], nonce, nlen);
        memcpy(&counter[12], &one, 4);
        if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, counter, key, 16,
                                    NULL, 0, 0, kCCModeOptionCTR_BE, &c) != kCCSuccess) {
                return -1;
        }
        ok = CCCryptorUpdate(c, p, plen, p, plen, &moved) == kCCSuccess && moved == plen;
        CCCryptorRelease(c);
        return ok ? 0 : -1;
}

/* The CBC-MAC of B0, the formatted additional data and the zero-padded payload: the last CBC block. */
static int ccm_mac(unsigned char *key, unsigned char *nonce, size_t nlen, unsigned char *aad, size_t alen,
                   unsigned char *p, size_t plen, size_t mlen, unsigned char *y)
{
        unsigned char head[16 + 2 + 64 + 16];
        unsigned char scratch[65536];
        unsigned char zero_iv[16];
        CCCryptorRef c = NULL;
        size_t hlen = 16, moved = 0, done = 0, rest;
        uint16_t l;
        int ok = 1;

        if (alen > 64) {
                return -1; /* SMB's additional data is the 32-byte transform header. */
        }
        aes_ccm_generate_b0(nonce, nlen, alen, plen, mlen, head);
        if (alen) {
                l = htobe16((uint16_t)alen);
                memcpy(&head[16], &l, 2);
                memcpy(&head[18], aad, alen);
                hlen = 16 + (2 + alen + 15) / 16 * 16;
                memset(&head[18 + alen], 0, hlen - 18 - alen);
        }
        memset(zero_iv, 0, 16);
        if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeCBC, kCCAlgorithmAES, ccNoPadding, zero_iv, key, 16,
                                    NULL, 0, 0, 0, &c) != kCCSuccess) {
                return -1;
        }
        ok = CCCryptorUpdate(c, head, hlen, scratch, sizeof(scratch), &moved) == kCCSuccess;
        if (ok) {
                memcpy(y, &scratch[moved - 16], 16);
        }
        while (ok && plen - done >= 16) {
                size_t n = plen - done;
                if (n > sizeof(scratch)) {
                        n = sizeof(scratch);
                }
                n -= n % 16;
                ok = CCCryptorUpdate(c, p + done, n, scratch, sizeof(scratch), &moved) == kCCSuccess && moved == n;
                if (ok) {
                        memcpy(y, &scratch[n - 16], 16);
                }
                done += n;
        }
        rest = plen - done;
        if (ok && rest) {
                unsigned char last[16];
                memset(last, 0, 16);
                memcpy(last, p + done, rest);
                ok = CCCryptorUpdate(c, last, 16, scratch, sizeof(scratch), &moved) == kCCSuccess && moved == 16;
                if (ok) {
                        memcpy(y, scratch, 16);
                }
        }
        CCCryptorRelease(c);
        return ok ? 0 : -1;
}

void aes128ccm_encrypt(unsigned char *key,
                       unsigned char *nonce, size_t nlen,
                       unsigned char *aad, size_t alen,
                       unsigned char *p, size_t plen,
                       unsigned char *m, size_t mlen)
{
        unsigned char s[16] _U_, y[16];

        if (ccm_mac(key, nonce, nlen, aad, alen, p, plen, mlen, y) != 0) {
                ccm_generate_T(key, nonce, nlen, aad, alen, p, plen, y, mlen);
        }
        memcpy(m, y, mlen);
        ccm_generate_s(key, nonce, nlen, plen, 0, &s[0]);
        bxory(m, &s[0], mlen);

        if (ccm_ctr(key, nonce, nlen, p, plen) != 0) {
                aes_ccm_crypt(key, nonce, nlen, p, plen);
        }
}

int aes128ccm_decrypt(unsigned char *key,
                      unsigned char *nonce, size_t nlen,
                      unsigned char *aad, size_t alen,
                      unsigned char *p, size_t plen,
                      unsigned char *m, size_t mlen)
{
        unsigned char s[16] _U_;
        unsigned char tmp[16];

        if (ccm_ctr(key, nonce, nlen, p, plen) != 0) {
                aes_ccm_crypt(key, nonce, nlen, p, plen);
        }
        if (ccm_mac(key, nonce, nlen, aad, alen, p, plen, mlen, tmp) != 0) {
                ccm_generate_T(key, nonce, nlen, aad, alen, p, plen, tmp, mlen);
        }
        ccm_generate_s(key, nonce, nlen, plen, 0, &s[0]);
        bxory(tmp, &s[0], mlen);

        return memcmp(tmp, m, mlen);
}

#else
void aes128ccm_encrypt(unsigned char *key,
                       unsigned char *nonce, size_t nlen,
                       unsigned char *aad, size_t alen,
                       unsigned char *p, size_t plen,
                       unsigned char *m, size_t mlen)
{
        unsigned char s[16] _U_;

        ccm_generate_T(key, nonce, nlen, aad, alen, p, plen, m, mlen);
        ccm_generate_s(key, nonce, nlen, plen, 0, &s[0]);
        bxory(m, &s[0], mlen);

        aes_ccm_crypt(key, nonce, nlen, p, plen);
}

int aes128ccm_decrypt(unsigned char *key,
                      unsigned char *nonce, size_t nlen,
                      unsigned char *aad, size_t alen,
                      unsigned char *p, size_t plen,
                      unsigned char *m, size_t mlen)
{
        unsigned char s[16] _U_;
        unsigned char tmp[16];

        aes_ccm_crypt(key, nonce, nlen, p, plen);

        ccm_generate_T(key, nonce, nlen, aad, alen, p, plen, tmp, mlen);
        ccm_generate_s(key, nonce, nlen, plen, 0, &s[0]);
        bxory(tmp, &s[0], mlen);

        return memcmp(tmp, m, mlen);
}

#endif
