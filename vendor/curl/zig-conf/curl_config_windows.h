#ifndef HEADER_CURL_CONFIG_ZIGBUILD_WINDOWS_H
#define HEADER_CURL_CONFIG_ZIGBUILD_WINDOWS_H
/***************************************************************************
 *                                  _   _ ____  _
 *  Project                     ___| | | |  _ \| |
 *                             / __| | | | |_) | |
 *                            | (__| |_| |  _ <| |___
 *                             \___|\___/|_| \_\_____|
 *
 * Copyright (C) Daniel Stenberg, <daniel@haxx.se>, et al.
 *
 * This software is licensed as described in the file COPYING, which
 * you should have received as part of this distribution. The terms
 * are also available at https://curl.se/docs/copyright.html.
 *
 * You may opt to use, copy, modify, merge, publish, distribute and/or sell
 * copies of the Software, and permit persons to whom the Software is
 * furnished to do so, under the terms of the COPYING file.
 *
 * This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
 * KIND, either express or implied.
 *
 * SPDX-License-Identifier: curl
 *
 ***************************************************************************/

/* ================================================================ */
/* Platform-specific curl config for Windows (Zig cross-compile)    */
/* ================================================================ */

/* Build mode */
#define BUILDING_LIBCURL 1
#define CURL_STATICLIB 1

/* TLS backend: Windows Schannel */
#define USE_SCHANNEL 1
#define USE_WIN32_CRYPTO 1

/* ---------------------------------------------------------------- */
/* Disable unused protocols                                         */
/* ---------------------------------------------------------------- */
#define CURL_DISABLE_LDAP 1
#define CURL_DISABLE_LDAPS 1
#define CURL_DISABLE_RTMP 1
#define CURL_DISABLE_MQTT 1

/* Explicitly NOT disabled (left enabled):
 *   DICT, FTP, FILE, GOPHER, IMAP, POP3, SMTP, TELNET, TFTP, RTSP
 */

/* Disable optional features we don't need */
/* #undef USE_NGHTTP2 */
/* #undef HAVE_BROTLI */
/* #undef HAVE_ZSTD */
/* #undef USE_LIBSSH */
/* #undef USE_LIBSSH2 */
/* #undef USE_QUICHE */
/* #undef USE_NGTCP2 */
/* #undef USE_LIBIDN2 */
/* #undef USE_LIBPSL */
/* #undef USE_UNIX_SOCKETS */

/* ---------------------------------------------------------------- */
/* Windows headers                                                  */
/* ---------------------------------------------------------------- */
#define HAVE_WINSOCK2_H 1
#define HAVE_WS2TCPIP_H 1
#define HAVE_WINDOWS_H 1
#define HAVE_WINCRYPT_H 1

/* ---------------------------------------------------------------- */
/* Standard C headers                                               */
/* ---------------------------------------------------------------- */
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_STRING_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STDIO_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_FCNTL_H 1
#define HAVE_IO_H 1
#define HAVE_LOCALE_H 1

/* ---------------------------------------------------------------- */
/* Functions                                                        */
/* ---------------------------------------------------------------- */
#define HAVE_STRCASECMP 1
#define HAVE_STRDUP 1
#define HAVE_STRTOLL 1
#define HAVE_SNPRINTF 1
#define HAVE_SOCKET 1
#define HAVE_SELECT 1
#define HAVE_RECV 1
#define HAVE_SEND 1
#define HAVE_GETADDRINFO 1
#define HAVE_FREEADDRINFO 1
#define HAVE_INET_PTON 1
#define HAVE_INET_NTOP 1
#define HAVE_GETENV 1
#define HAVE_SETLOCALE 1
#define HAVE_LONGLONG 1
#define HAVE_BOOL_T 1

/* ---------------------------------------------------------------- */
/* Type sizes (Win64 / LLP64 model)                                 */
/* ---------------------------------------------------------------- */
#define SIZEOF_INT 4
#define SIZEOF_LONG 4
#define SIZEOF_OFF_T 4
#define SIZEOF_SIZE_T 8
#define SIZEOF_TIME_T 8
#define SIZEOF_CURL_OFF_T 8
#define SIZEOF_CURL_SOCKET_T 8

/* ---------------------------------------------------------------- */
/* Misc / networking                                                */
/* ---------------------------------------------------------------- */
#define USE_IPV6 1
#define USE_THREADS_WIN32 1

#endif /* HEADER_CURL_CONFIG_ZIGBUILD_WINDOWS_H */
