/**
 * @file pqc_server_threaded.c
 * @brief A multi-threaded hybrid TLS server designed for high-concurrency (HPS) benchmarking.
 * 
 * This server uses POSIX threads (pthreads) to handle multiple simultaneous TLS 
 * connections. It is optimized for measuring Handshakes Per Second (HPS) using 
 * tools like `openssl s_time`. It supports both classical and Post-Quantum 
 * algorithms via OpenSSL 3.5.0's native PQC support.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <pthread.h>
#include <getopt.h>

#define PORT 4433

/**
 * @brief Thread arguments structure to pass data to the client handler thread.
 */
typedef struct {
    int client_sock; ///< The accepted client socket descriptor.
    SSL_CTX *ctx;    ///< Pointer to the shared SSL context.
} thread_args_t;

/**
 * @brief Configures the SSL context with certificates, keys, and supported signature algorithms.
 * @param ctx The SSL context to configure.
 * @param cert_file Path to the server certificate (or chain).
 * @param key_file Path to the server private key.
 * @param ca_file  Optional: path to the CA cert used to verify the client (enables mTLS).
 */
void configure_context(SSL_CTX *ctx, const char *cert_file, const char *key_file, const char *ca_file) {
    // Explicitly set signature algorithms supported by OpenSSL 3.5.0 natively.
    // Includes:
    // - ML-DSA-44, 65, 87 (native PQC)
    // - RSA (PSS/PKCS1)
    // - ECDSA (P-256, P-384)
    // - Ed25519
    const char *sigalgs = "mldsa44:mldsa65:mldsa87:"
                          "rsa_pss_rsae_sha256:rsa_pkcs1_sha256:rsa_pss_rsae_sha384:rsa_pkcs1_sha384:rsa_pss_rsae_sha512:rsa_pkcs1_sha512:"
                          "ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:"
                          "ed25519";

    if (!SSL_CTX_set1_sigalgs_list(ctx, sigalgs)) {
         fprintf(stderr, "Failed to set signature algorithms\n");
         ERR_print_errors_fp(stderr);
    }

    // Load server certificate
    if (SSL_CTX_use_certificate_chain_file(ctx, cert_file) <= 0) {
        fprintf(stderr, "Error loading certificate chain from %s\n", cert_file);
        ERR_print_errors_fp(stderr);
        exit(EXIT_FAILURE);
    }

    // Load server private key
    if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) <= 0) {
        fprintf(stderr, "Error loading private key from %s\n", key_file);
        ERR_print_errors_fp(stderr);
        exit(EXIT_FAILURE);
    }

    // mTLS: if a CA file is provided, require and verify the client's certificate
    if (ca_file) {
        if (!SSL_CTX_load_verify_locations(ctx, ca_file, NULL)) {
            fprintf(stderr, "Error loading CA file for client verification: %s\n", ca_file);
            ERR_print_errors_fp(stderr);
            exit(EXIT_FAILURE);
        }
        // SSL_VERIFY_PEER   -> request a client cert
        // FAIL_IF_NO_PEER_CERT -> abort handshake if client sends no cert
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, NULL);
        printf("mTLS enabled: client certificate required (CA: %s)\n", ca_file);
    }
}

/**
 * @brief Worker function to handle an individual client connection in a separate thread.
 * @param args Pointer to thread_args_t structure.
 * @return Always returns NULL.
 */
void *handle_client(void *args) {
    thread_args_t *targs = (thread_args_t *)args;
    int client = targs->client_sock;
    SSL_CTX *ctx = targs->ctx;
    free(targs); // Free the malloc'd arguments copy

    SSL *ssl = SSL_new(ctx);
    if (!ssl) {
        close(client);
        return NULL;
    }
    
    SSL_set_fd(ssl, client);

    // Perform the TLS handshake (Server side)
    if (SSL_accept(ssl) <= 0) {
        // Handshake failures are expected under heavy load in stress tests
    } else {
        // Handshake successful.
        // For HPS (Handshakes Per Second) benchmarks, tools like s_time -www
        // expect to send a request and receive a response.
        
        // Set a short receive timeout (100ms) to avoid hanging if the client 
        // doesn't send a request (e.g., our latency benchmark client).
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 100000; // 100ms
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));

        char buf[1024];
        int n = SSL_read(ssl, buf, sizeof(buf));
        (void)n; // Discard request content or handle timeout
        
        const char *response = "HTTP/1.0 200 OK\r\nContent-Length: 1\r\n\r\nOK"; 
        SSL_write(ssl, response, strlen(response));
    }

    // Properly shutdown and cleanup the SSL/TCP connection
    SSL_shutdown(ssl);
    SSL_free(ssl);
    close(client);
    return NULL;
}

int main(int argc, char **argv) {
    int sock;
    SSL_CTX *ctx;
    
    // Disable buffering for stdout to ensure logs are captured immediately
    setbuf(stdout, NULL);
    
    // Default values for certificates and key exchange groups
    char *cert_file = "certs/server_cert.pem";
    char *key_file  = "certs/server_key.pem";
    char *ca_file   = NULL;  // When set, enables mTLS (client cert verification)
    char *groups    = "X25519MLKEM768:x25519";
    
    // Parse command line arguments
    // -c: Path to server certificate
    // -k: Path to server private key
    // -a: Path to CA cert used to verify the client (enables mTLS)
    // -g: Key exchange groups (e.g., "X25519MLKEM768:x25519")
    int opt;
    while ((opt = getopt(argc, argv, "c:k:a:g:")) != -1) {
        switch (opt) {
            case 'c':
                cert_file = optarg;
                break;
            case 'k':
                key_file = optarg;
                break;
            case 'a':
                ca_file = optarg;
                break;
            case 'g':
                groups = optarg;
                break;
            default:
                fprintf(stderr, "Usage: %s [-c cert_file] [-k key_file] [-a ca_file] [-g groups_list]\n", argv[0]);
                exit(EXIT_FAILURE);
        }
    }

    // Initialize SSL context
    // OpenSSL 3.5.0 has native ML-KEM and ML-DSA support — no provider loading needed
    ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) {
        perror("Unable to create SSL context");
        exit(EXIT_FAILURE);
    }

    // Apply certificate, signature settings, and optional mTLS client CA
    configure_context(ctx, cert_file, key_file, ca_file);

    // Explicitly set the supported KEM groups (supports PQC and Hybrid)
    // Native OpenSSL 3.5.0 groups: X25519MLKEM768, SecP256r1MLKEM768, x25519, etc.
    if (!SSL_CTX_set1_groups_list(ctx, groups)) {
         fprintf(stderr, "Failed to set groups list to %s\n", groups);
    }
    
    // Enable session caching to support both "New" and "Reused" session benchmarks.
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_SERVER);
    SSL_CTX_set_session_id_context(ctx, (const unsigned char*)"PQC_Bench", 9);

    // TCP Socket setup and binding
    struct sockaddr_in addr;
    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("Unable to create socket");
        exit(EXIT_FAILURE);
    }

    // Allow immediate address reuse for easier debugging and restarts
    int opt_val = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt_val, sizeof(opt_val));

    addr.sin_family = AF_INET;
    addr.sin_port = htons(PORT);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("Unable to bind");
        exit(EXIT_FAILURE);
    }

    // Use a high backlog value to handle high-concurrency bursts
    if (listen(sock, 1024) < 0) {
        perror("Unable to listen");
        exit(EXIT_FAILURE);
    }

    printf("Threaded Server listening on port %d... (Groups: %s)\n", PORT, groups);

    // Main acceptance loop: spawn a detached thread for every incoming connection
    while (1) {
        struct sockaddr_in addr;
        unsigned int len = sizeof(addr);
        int client = accept(sock, (struct sockaddr*)&addr, &len);
        if (client < 0) {
            perror("Unable to accept");
            continue;
        }

        thread_args_t *args = malloc(sizeof(thread_args_t));
        if (!args) {
            perror("Malloc failed");
            close(client);
            continue;
        }
        args->client_sock = client;
        args->ctx = ctx;

        pthread_t tid;
        if (pthread_create(&tid, NULL, handle_client, args) != 0) {
            perror("Failed to create thread");
            free(args);
            close(client);
        } else {
            // Detach the thread so that its resources are automatically reclaimed on finish
            pthread_detach(tid);
        }
    }

    // Standard cleanup (not reached in this infinite loop)
    close(sock);
    SSL_CTX_free(ctx);
    
    return 0;
}
