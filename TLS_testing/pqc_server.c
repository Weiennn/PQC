/**
 * @file pqc_server.c
 * @brief A hybrid TLS server implementation supporting Post-Quantum Cryptography (PQC).
 * 
 * This server uses OpenSSL 3.5.0's native PQC support for both classical 
 * (X25519) and Post-Quantum (ML-KEM, ML-DSA) algorithms. It is designed 
 * to be backward compatible with classical clients while offering PQC 
 * security to modern clients.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <getopt.h>

#define PORT 4433

/**
 * @brief Configures the SSL context with certificates, keys, and supported signature algorithms.
 * @param ctx The SSL context to configure.
 * @param cert_file Path to the server certificate (or chain).
 * @param key_file Path to the server private key.
 */
void configure_context(SSL_CTX *ctx, const char *cert_file, const char *key_file) {
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
}

int main(int argc, char **argv) {
    int sock;
    SSL_CTX *ctx;
    
    // Default values for certificates and key exchange groups
    char *cert_file = "certs/server_cert.pem";
    char *key_file = "certs/server_key.pem";
    char *groups = "X25519MLKEM768:x25519";
    
    // Parse command line arguments
    // -c: Path to certificate
    // -k: Path to private key
    // -g: Key exchange groups (e.g., "X25519MLKEM768:x25519")
    int opt;
    while ((opt = getopt(argc, argv, "c:k:g:")) != -1) {
        switch (opt) {
            case 'c':
                cert_file = optarg;
                break;
            case 'k':
                key_file = optarg;
                break;
            case 'g':
                groups = optarg;
                break;
            default:
                fprintf(stderr, "Usage: %s [-c cert_file] [-k key_file] [-g groups_list]\n", argv[0]);
                exit(EXIT_FAILURE);
        }
    }

    // Initialize SSL context
    // OpenSSL 3.5.0 has native ML-KEM and ML-DSA support — no provider loading needed
    ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) {
        perror("Unable to create SSL context");
        ERR_print_errors_fp(stderr);
        exit(EXIT_FAILURE);
    }

    // Apply certificate and signature settings
    configure_context(ctx, cert_file, key_file);

    // Explicitly set the supported KEM (Key Encapsulation Mechanism) groups.
    // This allows the server to support hybrid handshakes.
    // Native OpenSSL 3.5.0 groups: X25519MLKEM768, SecP256r1MLKEM768, x25519, etc.
    if (!SSL_CTX_set1_groups_list(ctx, groups)) {
         fprintf(stderr, "Failed to set groups list to %s\n", groups);
         ERR_print_errors_fp(stderr);
    }

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

    if (listen(sock, 1) < 0) {
        perror("Unable to listen");
        exit(EXIT_FAILURE);
    }

    printf("Server listening on port %d... (Groups: %s)\n", PORT, groups);

    // Main connection acceptance loop
    while (1) {
        struct sockaddr_in addr;
        unsigned int len = sizeof(addr);
        int client = accept(sock, (struct sockaddr*)&addr, &len);
        if (client < 0) {
            perror("Unable to accept");
            exit(EXIT_FAILURE);
        }

        SSL *ssl = SSL_new(ctx);
        SSL_set_fd(ssl, client);

        // Perform the TLS handshake (Server side)
        if (SSL_accept(ssl) <= 0) {
            ERR_print_errors_fp(stderr);
        } else {
            printf("SSL connection established using ciphertext: %s\n", SSL_get_cipher(ssl));
            
            // Log the negotiated KEM group to verify if PQC or Classical was used
            int curve_id = SSL_get_negotiated_group(ssl);
            const char *curve_name = SSL_group_to_name(ssl, curve_id);
            printf("Negotiated Group ID: %d\n", curve_id);
            printf("Negotiated Group Name: %s\n", curve_name ? curve_name : "UNKNOWN");
            
            // Send a greeting message
            const char *msg = "Hello from PQC Hybrid Server!";
            SSL_write(ssl, msg, strlen(msg));

            // Throughput test: Send 1MB of data to the client
            char *big_buf = malloc(1024 * 1024);
            memset(big_buf, 'A', 1024 * 1024);
            int total_sent = 0;
            while (total_sent < 1024 * 1024) {
                int sent = SSL_write(ssl, big_buf + total_sent, 1024 * 1024 - total_sent);
                if (sent <= 0) break;
                total_sent += sent;
            }
            free(big_buf);
        }

        // Cleanup connection
        SSL_shutdown(ssl);
        SSL_free(ssl);
        close(client);
    }

    // Standard cleanup (not reached in this infinite loop)
    close(sock);
    SSL_CTX_free(ctx);
    return 0;
}
