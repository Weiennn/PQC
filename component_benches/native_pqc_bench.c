#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <openssl/evp.h>
#include <openssl/core_names.h>
#include <openssl/x509.h>
#include <openssl/err.h>

#define ITERATIONS 100

/**
 * Helper to get CPU cycles using the RDTSC instruction.
 */
static uint64_t rdtsc(void) {
    unsigned int lo, hi;
    __asm__ __volatile__ ("rdtsc" : "=a" (lo), "=d" (hi));
    return ((uint64_t)hi << 32) | lo;
}

/**
 * Benchmarks OpenSSL native Key Encapsulation Mechanism (KEM).
 */
void benchmark_native_kem(const char* alg_name) {
    EVP_PKEY_CTX *pctx = NULL, *kctx = NULL, *dctx = NULL;
    EVP_PKEY *pkey = NULL;
    
    // Check if algorithm is available
    pctx = EVP_PKEY_CTX_new_from_name(NULL, alg_name, NULL);
    if (!pctx) {
        printf("    \"%s\": {\"status\": \"disabled\"},\n", alg_name);
        return;
    }

    // EVP_PKEY_keygen_init MUST be called before EVP_PKEY_keygen in OpenSSL 3.x
    if (EVP_PKEY_keygen_init(pctx) <= 0) {
        printf("    \"%s\": {\"status\": \"failed_init\"},\n", alg_name);
        EVP_PKEY_CTX_free(pctx);
        return;
    }

    uint64_t cycles_keygen = 0, cycles_encaps = 0, cycles_decaps = 0;
    double time_keygen = 0, time_encaps = 0, time_decaps = 0;
    
    size_t pub_size = 0, priv_size = 0, ciphertext_size = 0, shared_secret_size_enc = 0, shared_secret_size_dec = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        // --- Key Generation ---
        clock_t start_time = clock();
        uint64_t start_cycles = rdtsc();
        
        if (EVP_PKEY_keygen(pctx, &pkey) <= 0) {
            fprintf(stderr, "Failed to generate keypair for %s\n", alg_name);
            break;
        }

        cycles_keygen += (rdtsc() - start_cycles);
        time_keygen += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // Size of cryptographic objects
        if (i == 0) {
            unsigned char *buf = NULL;
            int len = i2d_PUBKEY(pkey, &buf);
            if (len > 0) {
                pub_size = len;
                OPENSSL_free(buf); buf = NULL;
            } else {
                size_t raw_len = 0;
                if (EVP_PKEY_get_raw_public_key(pkey, NULL, &raw_len) > 0) {
                    pub_size = raw_len;
                } else {
                    pub_size = 0;
                }
            }
            
            len = i2d_PrivateKey(pkey, &buf);
            if (len > 0) {
                priv_size = len;
                OPENSSL_free(buf); buf = NULL;
            } else {
                size_t raw_len = 0;
                if (EVP_PKEY_get_raw_private_key(pkey, NULL, &raw_len) > 0) {
                    priv_size = raw_len;
                } else {
                    priv_size = 0;
                }
            }
        }

        // --- Encapsulation ---
        unsigned char *ciphertext = NULL;
        unsigned char *shared_secret_enc = NULL;

        start_time = clock();
        start_cycles = rdtsc();
        
        kctx = EVP_PKEY_CTX_new(pkey, NULL);
        if (!kctx || EVP_PKEY_encapsulate_init(kctx, NULL) <= 0) {
            fprintf(stderr, "Failed to init encap for %s\n", alg_name);
            break;
        }

        // Size discorvery pattern to determine lengths
        if (EVP_PKEY_encapsulate(kctx, NULL, &ciphertext_size, NULL, &shared_secret_size_enc) <= 0) {
            fprintf(stderr, "Failed to determine encap sizes for %s\n", alg_name);
            break;
        }

        ciphertext = OPENSSL_malloc(ciphertext_size);
        shared_secret_enc = OPENSSL_malloc(shared_secret_size_enc);

        // Perform actual encapsulation
        if (EVP_PKEY_encapsulate(kctx, ciphertext, &ciphertext_size, shared_secret_enc, &shared_secret_size_enc) <= 0) {
            fprintf(stderr, "Failed encapsulation for %s\n", alg_name);
            break;
        }

        cycles_encaps += (rdtsc() - start_cycles);
        time_encaps += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // --- Decapsulation ---
        unsigned char *shared_secret_dec = NULL;

        start_time = clock();
        start_cycles = rdtsc();
    
        dctx = EVP_PKEY_CTX_new(pkey, NULL);
        if (!dctx || EVP_PKEY_decapsulate_init(dctx, NULL) <= 0) {
             fprintf(stderr, "Failed to init decap for %s\n", alg_name);
             break;
        }

        if (EVP_PKEY_decapsulate(dctx, NULL, &shared_secret_size_dec, ciphertext, ciphertext_size) <= 0) {
             fprintf(stderr, "Failed to determine decap size for %s\n", alg_name);
             break;
        }
        
        shared_secret_dec = OPENSSL_malloc(shared_secret_size_dec);
        
        if (EVP_PKEY_decapsulate(dctx, shared_secret_dec, &shared_secret_size_dec, ciphertext, ciphertext_size) <= 0) {
             fprintf(stderr, "Failed decapsulation for %s\n", alg_name);
             break;
        }

        cycles_decaps += (rdtsc() - start_cycles);
        time_decaps += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // Cleanup iter
        OPENSSL_free(ciphertext);
        OPENSSL_free(shared_secret_enc);
        OPENSSL_free(shared_secret_dec);
        EVP_PKEY_CTX_free(kctx); kctx = NULL;
        EVP_PKEY_CTX_free(dctx); dctx = NULL;
        EVP_PKEY_free(pkey); pkey = NULL;
    }
    
    // Final cleanup for alg
    EVP_PKEY_CTX_free(pctx);
    
    // If it failed mid-loop
    if (pkey || kctx || dctx) {
        if(pkey) EVP_PKEY_free(pkey);
        if(kctx) EVP_PKEY_CTX_free(kctx);
        if(dctx) EVP_PKEY_CTX_free(dctx);
        printf("    \"%s\": {\"status\": \"failed_execution\"},\n", alg_name);
        return;
    }

    printf("    \"%s\": {\n", alg_name);
    printf("        \"type\": \"KEM\",\n");
    printf("        \"iterations\": %d,\n", ITERATIONS);
    printf("        \"sizes\": {\"public_key\": %zu, \"secret_key\": %zu, \"ciphertext\": %zu, \"shared_secret\": %zu},\n", 
           pub_size, priv_size, ciphertext_size, shared_secret_size_enc);
    printf("        \"keygen\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_keygen / ITERATIONS, (time_keygen / ITERATIONS) * 1000);
    printf("        \"encaps\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_encaps / ITERATIONS, (time_encaps / ITERATIONS) * 1000);
    printf("        \"decaps\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f}\n", cycles_decaps / ITERATIONS, (time_decaps / ITERATIONS) * 1000);
    printf("    },\n");
}

int main() {
    printf("{\n");
    printf("\"timestamp\": \"%ld\",\n", time(NULL));
    printf("\"results\": {\n");

    // Test OpenSSL 3.5.0 Native ML-KEM
    benchmark_native_kem("ML-KEM-512");
    benchmark_native_kem("ML-KEM-768");
    benchmark_native_kem("ML-KEM-1024");
    benchmark_native_kem("X25519MLKEM768");
    
    printf("    \"_end\": {}\n"); 
    printf("}\n");
    printf("}\n");

    return 0;
}
