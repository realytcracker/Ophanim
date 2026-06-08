//
//  OPHooksSocket.m
//  OphanimCore
//
//  Raw socket + DNS visibility via DYLD_INTERPOSE on connect() and getaddrinfo(). Not interposed
//  by Galgal → safe in both modes. The wrappers only format the address into a stack buffer and
//  enqueue into the allocation-free capture ring (op_ring_emit) - no Swift/alloc on the hot path.
//  The ring's consumer turns records into OPEvents; op_ring_emit self-gates on the .network category.
//

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import "OPRing.h"

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
   _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
   { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static int op_connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    if (op_ring_started() && addr) {   // dormant image (sibling Galgal): transparent thunk, no formatting
        char ip[INET6_ADDRSTRLEN] = {0};
        int port = 0;
        if (addr->sa_family == AF_INET) {
            const struct sockaddr_in *a = (const struct sockaddr_in *)addr;
            inet_ntop(AF_INET, &a->sin_addr, ip, sizeof(ip));
            port = ntohs(a->sin_port);
        } else if (addr->sa_family == AF_INET6) {
            const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)addr;
            inet_ntop(AF_INET6, &a->sin6_addr, ip, sizeof(ip));
            port = ntohs(a->sin6_port);
        }
        if (ip[0]) {
            op_ring_emit(OP_K_SOCK_CONNECT, (uint8_t)addr->sa_family, port, ip, NULL, 0);
        }
    }
    return connect(sockfd, addr, addrlen);
}

static int op_getaddrinfo(const char *node, const char *service,
                          const struct addrinfo *hints, struct addrinfo **res) {
    if (op_ring_started() && node) {
        op_ring_emit(OP_K_SOCK_GETADDRINFO, 0, 0, node, NULL, 0);
    }
    return getaddrinfo(node, service, hints, res);
}

DYLD_INTERPOSE(op_connect, connect)
DYLD_INTERPOSE(op_getaddrinfo, getaddrinfo)
