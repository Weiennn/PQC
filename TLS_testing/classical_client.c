/**
 * @file classical_client.c
 * @brief A TLS client implementation using classical cryptographic algorithms for benchmarking.
 * 
 * This client is designed to connect to the PQC-enabled server but specifically 
 * requests classical Key Encapsulation Mechanisms (KEM) like X25519. 
 * It measures handshake latency, CPU usage, and data throughput for comparison 
 * against Post-Quantum Cryptography (PQC) methods.
 * Built against OpenSSL 3.5.0 which provides both classical and PQC algorithms natively.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/resource.h>
#include <arpa/inet.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <getopt.h>

#define PORT 4433
#define DATA_SIZE (1024 * 1024) // 1MB for throughput test

/**
 * @brief Helper function to get the current time in milliseconds.
 * @return Current time in ms since epoch.
 */
double get_time_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

int main(int argc, char **argv) {
    int sock;
    SSL_CTX *ctx;
    SSL *ssl;
    char *buf = malloc(DATA_SIZE);
    struct rusage usage_start, usage_end;

    char *ca_file = NULL;
    char *host_ip = "127.0.0.1";
    
    // Parse command line arguments
    // -C: Path to CA certificate for server verification
    // -H: Server IP address (defaults to localhost)
    int opt;
    while ((opt = getopt(argc, argv, "C:H:")) != -1) {
        switch (opt) {
            case 'C':
                ca_file = optarg;
                break;
            case 'H':
                host_ip = optarg;
                break;
            default:
                fprintf(stderr, "Usage: %s [-C ca_file] [-H host_ip]\n", argv[0]);
                exit(EXIT_FAILURE);
        }
    }

    // Create a new SSL context for TLS client
    // OpenSSL 3.5.0 provides all algorithms natively — no provider loading needed
    ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        perror("Unable to create SSL context");
        ERR_print_errors_fp(stderr);
        exit(EXIT_FAILURE);
    }
    
    // Configure peer verification if a CA file is provided
    if (ca_file) {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
        if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) {
            fprintf(stderr, "Failed to load CA file: %s\n", ca_file);
            ERR_print_errors_fp(stderr);
            exit(EXIT_FAILURE);
        }
    } else {
        // Warning: Disabling verification in production is insecure
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    }

    // Force the use of classical X25519 for key exchange
    // This allows us to compare classical performance against PQC algorithms
    if (!SSL_CTX_set1_groups_list(ctx, "x25519")) {
         fprintf(stderr, "Failed to set groups list\n");
         ERR_print_errors_fp(stderr);
    }

    // Standard TCP socket setup
    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("Unable to create socket");
        exit(EXIT_FAILURE);
    }

    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(PORT);
    addr.sin_addr.s_addr = inet_addr(host_ip);

    // Connect to the server
    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("Unable to connect");
        exit(EXIT_FAILURE);
    }

    // Create SSL object and link to the socket
    ssl = SSL_new(ctx);
    SSL_set_fd(ssl, sock);

    // Set Server Name Indication (SNI) and host for verification
    SSL_set_tlsext_host_name(ssl, "localhost");
    if (ca_file) {
        SSL_set1_host(ssl, "localhost");
    }

    // Capture baseline CPU usage and start time
    getrusage(RUSAGE_SELF, &usage_start);
    double start_hs = get_time_ms();

    // Perform the TLS Handshake
    if (SSL_connect(ssl) <= 0) {
        ERR_print_errors_fp(stderr);
    } else {
        // Handshake successful, record metrics
        double end_hs = get_time_ms();
        getrusage(RUSAGE_SELF, &usage_end);

        double hs_latency = end_hs - start_hs;
        double user_cpu = (usage_end.ru_utime.tv_sec - usage_start.ru_utime.tv_sec) * 1000.0 +
                          (usage_end.ru_utime.tv_usec - usage_start.ru_utime.tv_usec) / 1000.0;
        double sys_cpu = (usage_end.ru_stime.tv_sec - usage_start.ru_stime.tv_sec) * 1000.0 +
                         (usage_end.ru_stime.tv_usec - usage_start.ru_stime.tv_usec) / 1000.0;

        // Print metrics for the benchmarking scripts to parse
        printf("CLASSICAL_METRIC_HANDSHAKE_MS: %.3f\n", hs_latency);
        printf("CLASSICAL_METRIC_USER_CPU_MS: %.3f\n", user_cpu);
        printf("CLASSICAL_METRIC_SYS_CPU_MS: %.3f\n", sys_cpu);

        // Verify that we actually negotiated a classical group
        int curve_id = SSL_get_negotiated_group(ssl);
        printf("Negotiated Group Name: %s\n", SSL_group_to_name(ssl, curve_id));

        // Start throughput test: Receive 1MB of data from the server
        double start_tp = get_time_ms();
        size_t total_received = 0;
        while (total_received < DATA_SIZE) {
            int bytes = SSL_read(ssl, buf, DATA_SIZE - total_received);
            if (bytes <= 0) break;
            total_received += bytes;
        }
        double end_tp = get_time_ms();
        double tp_time_s = (end_tp - start_tp) / 1000.0;
        double throughput_mbps = (total_received / (1024.0 * 1024.0)) / tp_time_s;

        printf("CLASSICAL_METRIC_THROUGHPUT_MBPS: %.3f\n", throughput_mbps);
    }

    // Cleanup resources
    SSL_free(ssl);
    close(sock);
    SSL_CTX_free(ctx);
    free(buf);
    
    return 0;
}
