#ifndef HEADER_CURL_CONFIG_ZIGBUILD_LINUX_H
#define HEADER_CURL_CONFIG_ZIGBUILD_LINUX_H
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
/* Platform-specific curl config for Linux/FreeBSD (Zig build)      */
/* ================================================================ */

/* Build mode */
#define BUILDING_LIBCURL 1
#define CURL_STATICLIB 1

/* TLS backend: OpenSSL (dynamic-linked) */
#define USE_OPENSSL 1

/* Compression */
#define HAVE_LIBZ 1

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

/* ---------------------------------------------------------------- */
/* POSIX headers                                                    */
/* ---------------------------------------------------------------- */
#define HAVE_SYS_SOCKET_H 1
#define HAVE_NETDB_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_UNISTD_H 1
#define HAVE_FCNTL_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_NETINET_TCP_H 1
#define HAVE_NET_IF_H 1
#define HAVE_POLL_H 1
#define HAVE_SYS_POLL_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_UN_H 1
#define HAVE_PWD_H 1
#define HAVE_PTHREAD_H 1
#define HAVE_SIGNAL_H 1
#define HAVE_SIGACTION 1
#define HAVE_TERMIOS_H 1
#define HAVE_IFADDRS_H 1
#define HAVE_DIRENT_H 1
#define HAVE_LOCALE_H 1
#define HAVE_LIBGEN_H 1

/* ---------------------------------------------------------------- */
/* Standard C headers                                               */
/* ---------------------------------------------------------------- */
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDATOMIC_H 1

/* ---------------------------------------------------------------- */
/* Functions                                                        */
/* ---------------------------------------------------------------- */
#define HAVE_STRCASECMP 1
#define HAVE_STRDUP 1
#define HAVE_STRTOLL 1
#define HAVE_STRTOK_R 1
#define HAVE_SNPRINTF 1

/* Socket/network functions */
#define HAVE_SOCKET 1
#define HAVE_SOCKETPAIR 1
#define HAVE_SELECT 1
#define HAVE_POLL 1
#define HAVE_RECV 1
#define HAVE_SEND 1
#define HAVE_SENDMSG 1
#define HAVE_GETADDRINFO 1
#define HAVE_FREEADDRINFO 1
#define HAVE_GETHOSTNAME 1
#define HAVE_GETPEERNAME 1
#define HAVE_GETSOCKNAME 1
#define HAVE_INET_PTON 1
#define HAVE_INET_NTOP 1

/* Signal/process functions */
#define HAVE_ALARM 1
#define HAVE_SIGINTERRUPT 1
#define HAVE_SIGSETJMP 1
#define HAVE_PIPE 1
#define HAVE_GETENV 1

/* File/IO functions */
#define HAVE_FTRUNCATE 1
#define HAVE_FSEEKO 1
#define HAVE_SETLOCALE 1

/* Time functions */
#define HAVE_GMTIME_R 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_CLOCK_GETTIME_MONOTONIC 1

/* Filesystem/user functions */
#define HAVE_REALPATH 1
#define HAVE_FNMATCH 1
#define HAVE_BASENAME 1
#define HAVE_GETPWUID 1
#define HAVE_GETPWUID_R 1
#define HAVE_GETEUID 1
#define HAVE_GETPPID 1
#define HAVE_GETRLIMIT 1
#define HAVE_SETRLIMIT 1
#define HAVE_SCHED_YIELD 1

/* Network interface functions */
#define HAVE_IF_NAMETOINDEX 1
#define HAVE_GETIFADDRS 1
#define HAVE_GETADDRINFO_THREADSAFE 1

/* Directory functions */
#define HAVE_OPENDIR 1

/* fcntl/ioctl features */
#define HAVE_FCNTL 1
#define HAVE_FCNTL_O_NONBLOCK 1
#define HAVE_IOCTL_FIONBIO 1
#define HAVE_IOCTL_SIOCGIFADDR 1
#define HAVE_MSG_NOSIGNAL 1

/* Error handling */
#define HAVE_POSIX_STRERROR_R 1
#define HAVE_STRERROR_R 1

/* Misc capabilities */
#define HAVE_WRITABLE_ARGV 1
#define HAVE_ATOMIC 1
#define HAVE_LONGLONG 1
#define HAVE_BOOL_T 1

/* ---------------------------------------------------------------- */
/* Type sizes                                                       */
/* ---------------------------------------------------------------- */
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_OFF_T 8
#define SIZEOF_SIZE_T 8
#define SIZEOF_TIME_T 8
#define SIZEOF_CURL_OFF_T 8
#define SIZEOF_CURL_SOCKET_T 4

/* ---------------------------------------------------------------- */
/* Misc / networking                                                */
/* ---------------------------------------------------------------- */
#define USE_IPV6 1
#define USE_THREADS_POSIX 1
#define USE_UNIX_SOCKETS 1

#define HAVE_SA_FAMILY_T 1
#define HAVE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_STRUCT_TIMEVAL 1
#define HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID 1
#define HAVE_SUSECONDS_T 1
#define HAVE_DECL_FSEEKO 1

#define CURL_EXTERN_SYMBOL __attribute__((__visibility__("default")))

#endif /* HEADER_CURL_CONFIG_ZIGBUILD_LINUX_H */
