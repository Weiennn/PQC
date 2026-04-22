#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <oqs/oqs.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/pem.h>
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
 * Benchmarks a Post-Quantum Key Encapsulation Mechanism (KEM) using liboqs.
 */
void benchmark_kem(const char* alg_name) {
    if (!OQS_KEM_alg_is_enabled(alg_name)) {
        printf("    \"%s\": {\"status\": \"disabled\"},\n", alg_name);
        return;
    }

    // OQS_KEM_new: Initializes a KEM structure for the specific algorithm.
    OQS_KEM *kem = OQS_KEM_new(alg_name);
    if (kem == NULL) {
        printf("    \"%s\": {\"status\": \"failed_init\"},\n", alg_name);
        return;
    }

    uint8_t *public_key = malloc(kem->length_public_key);
    uint8_t *secret_key = malloc(kem->length_secret_key);
    uint8_t *ciphertext = malloc(kem->length_ciphertext);
    uint8_t *shared_secret_enc = malloc(kem->length_shared_secret);
    uint8_t *shared_secret_dec = malloc(kem->length_shared_secret);

    uint64_t cycles_keygen = 0, cycles_encaps = 0, cycles_decaps = 0;
    double time_keygen = 0, time_encaps = 0, time_decaps = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        // --- Key Generation ---
        clock_t start_time = clock();
        uint64_t start_cycles = rdtsc();
        // OQS_KEM_keypair: Generates a public key and a secret key.
        OQS_KEM_keypair(kem, public_key, secret_key);
        cycles_keygen += (rdtsc() - start_cycles);
        time_keygen += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // --- Encapsulation ---
        start_time = clock();
        start_cycles = rdtsc();
        // OQS_KEM_encaps: Uses the public key to generate a random shared secret and an encrypted version (ciphertext).
        OQS_KEM_encaps(kem, ciphertext, shared_secret_enc, public_key);
        cycles_encaps += (rdtsc() - start_cycles);
        time_encaps += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // --- Decapsulation ---
        start_time = clock();
        start_cycles = rdtsc();
        // OQS_KEM_decaps: Uses the secret key to recover the shared secret from the ciphertext.
        OQS_KEM_decaps(kem, shared_secret_dec, ciphertext, secret_key);
        cycles_decaps += (rdtsc() - start_cycles);
        time_decaps += (double)(clock() - start_time) / CLOCKS_PER_SEC;
    }

    printf("    \"%s\": {\n", alg_name);
    printf("        \"type\": \"KEM\",\n");
    printf("        \"iterations\": %d,\n", ITERATIONS);
    printf("        \"sizes\": {\"public_key\": %zu, \"secret_key\": %zu, \"ciphertext\": %zu, \"shared_secret\": %zu},\n", 
           kem->length_public_key, kem->length_secret_key, kem->length_ciphertext, kem->length_shared_secret);
    printf("        \"keygen\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_keygen / ITERATIONS, (time_keygen / ITERATIONS) * 1000);
    printf("        \"encaps\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_encaps / ITERATIONS, (time_encaps / ITERATIONS) * 1000);
    printf("        \"decaps\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f}\n", cycles_decaps / ITERATIONS, (time_decaps / ITERATIONS) * 1000);
    printf("    },\n");

    // OQS_KEM_free: Cleans up the KEM structure.
    OQS_KEM_free(kem);
    free(public_key);
    free(secret_key);
    free(ciphertext);
    free(shared_secret_enc);
    free(shared_secret_dec);
}

/**
 * Benchmarks a Post-Quantum Digital Signature algorithm using liboqs.
 */
void benchmark_sig(const char* alg_name) {
    if (!OQS_SIG_alg_is_enabled(alg_name)) {
        printf("    \"%s\": {\"status\": \"disabled\"},\n", alg_name);
        return;
    }

    // OQS_SIG_new: Initializes a Signature structure for the specific algorithm.
    OQS_SIG *sig = OQS_SIG_new(alg_name);
    if (sig == NULL) {
        printf("    \"%s\": {\"status\": \"failed_init\"},\n", alg_name);
        return;
    }

    uint8_t *public_key = malloc(sig->length_public_key);
    uint8_t *secret_key = malloc(sig->length_secret_key);
    uint8_t *message = (uint8_t*)"BenchmarkMessage";
    size_t message_len = strlen((char*)message);
    uint8_t *signature = malloc(sig->length_signature);
    size_t signature_len;

    uint64_t cycles_keygen = 0, cycles_sign = 0, cycles_verify = 0;
    double time_keygen = 0, time_sign = 0, time_verify = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        // --- Key Generation ---
        clock_t start_time = clock();
        uint64_t start_cycles = rdtsc();
        // OQS_SIG_keypair: Generates a public verification key and a secret signing key.
        OQS_SIG_keypair(sig, public_key, secret_key);
        cycles_keygen += (rdtsc() - start_cycles);
        time_keygen += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // --- Signing ---
        start_time = clock();
        start_cycles = rdtsc();
        // OQS_SIG_sign: Creates a digital signature for the message using the secret key.
        OQS_SIG_sign(sig, signature, &signature_len, message, message_len, secret_key);
        cycles_sign += (rdtsc() - start_cycles);
        time_sign += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // --- Verification ---
        start_time = clock();
        start_cycles = rdtsc();
        // OQS_SIG_verify: Validates the signature using the public key and the original message.
        OQS_SIG_verify(sig, message, message_len, signature, signature_len, public_key);
        cycles_verify += (rdtsc() - start_cycles);
        time_verify += (double)(clock() - start_time) / CLOCKS_PER_SEC;
    }

    printf("    \"%s\": {\n", alg_name);
    printf("        \"type\": \"SIG\",\n");
    printf("        \"iterations\": %d,\n", ITERATIONS);
    printf("        \"sizes\": {\"public_key\": %zu, \"secret_key\": %zu, \"signature\": %zu},\n", 
           sig->length_public_key, sig->length_secret_key, sig->length_signature);
    printf("        \"keygen\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_keygen / ITERATIONS, (time_keygen / ITERATIONS) * 1000);
    printf("        \"sign\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_sign / ITERATIONS, (time_sign / ITERATIONS) * 1000);
    printf("        \"verify\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f}\n", cycles_verify / ITERATIONS, (time_verify / ITERATIONS) * 1000);
    printf("    },\n");

    // OQS_SIG_free: Cleans up the Signature structure.
    OQS_SIG_free(sig);
    free(public_key);
    free(secret_key);
    free(signature);
}

/**
 * Benchmarks Classical Key Exchange (Diffie-Hellman) using OpenSSL's EVP API.
 * For X25519, we treat it like a KEM to allow comparison.
 */
void benchmark_classical_kem_x25519() {
    const char* alg_name = "X25519";
    EVP_PKEY_CTX *pctx, *kctx;
    EVP_PKEY *pkey = NULL, *peerkey = NULL;
    size_t priv_len, pub_len, ct_len, ss_len;
    
    // Key Sizes for X25519 (standardized)
    priv_len = 32;
    pub_len = 32;
    ct_len = 32; // In ECDH, the "ciphertext" we transmit is just the ephemeral public key.
    ss_len = 32;

    uint64_t cycles_keygen = 0, cycles_encaps = 0, cycles_decaps = 0;
    double time_keygen = 0, time_encaps = 0, time_decaps = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        // --- Key Generation ---
        clock_t start_time = clock();
        uint64_t start_cycles = rdtsc();
        // EVP_PKEY_CTX_new_id: Creates a context for a specific algorithm (X25519).
        pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, NULL);
        if (!pctx) { fprintf(stderr, "Failed ctx\n"); exit(1); }
        // EVP_PKEY_keygen_init/EVP_PKEY_keygen: Standard OpenSSL pattern for generating a keypair.
        EVP_PKEY_keygen_init(pctx);
        if (EVP_PKEY_keygen(pctx, &pkey) <= 0) { fprintf(stderr, "Failed keygen\n"); exit(1); }
        cycles_keygen += (rdtsc() - start_cycles);
        time_keygen += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // --- "Encapsulation" (Generate ephemeral key and shared secret) ---
        start_time = clock();
        start_cycles = rdtsc();
        kctx = EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, NULL);
        EVP_PKEY_keygen_init(kctx);
        EVP_PKEY_keygen(kctx, &peerkey);
        // EVP_PKEY_derive: Modern OpenSSL way to perform Key Agreement (e.g., Diffie-Hellman).
        EVP_PKEY_derive_init(kctx);
        EVP_PKEY_derive_set_peer(kctx, pkey);
        size_t out_ss_len = ss_len;
        unsigned char ss[32];
        EVP_PKEY_derive(kctx, ss, &out_ss_len);
        cycles_encaps += (rdtsc() - start_cycles);
        time_encaps += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // --- "Decapsulation" ---
        start_time = clock();
        start_cycles = rdtsc();
        EVP_PKEY_CTX *dctx = EVP_PKEY_CTX_new(pkey, NULL);
        EVP_PKEY_derive_init(dctx);
        EVP_PKEY_derive_set_peer(dctx, peerkey);
        out_ss_len = ss_len;
        EVP_PKEY_derive(dctx, ss, &out_ss_len);
        cycles_decaps += (rdtsc() - start_cycles);
        time_decaps += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // Cleanup resources
        EVP_PKEY_free(pkey); pkey = NULL;
        EVP_PKEY_free(peerkey); peerkey = NULL;
        EVP_PKEY_CTX_free(pctx); pctx = NULL;
        EVP_PKEY_CTX_free(kctx); kctx = NULL;
        EVP_PKEY_CTX_free(dctx); dctx = NULL;
    }

    printf("    \"%s\": {\n", alg_name);
    printf("        \"type\": \"KEM\",\n");
    printf("        \"iterations\": %d,\n", ITERATIONS);
    printf("        \"sizes\": {\"public_key\": %zu, \"secret_key\": %zu, \"ciphertext\": %zu, \"shared_secret\": %zu},\n", 
           pub_len, priv_len, ct_len, ss_len);
    printf("        \"keygen\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_keygen / ITERATIONS, (time_keygen / ITERATIONS) * 1000);
    printf("        \"encaps\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_encaps / ITERATIONS, (time_encaps / ITERATIONS) * 1000);
    printf("        \"decaps\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f}\n", cycles_decaps / ITERATIONS, (time_decaps / ITERATIONS) * 1000);
    printf("    },\n");
}

/**
 * Benchmarks Classical Digital Signatures (RSA or ECDSA) using OpenSSL's EVP API.
 */
void benchmark_classical_sig(const char* alg_name, int pkey_id) {
    EVP_PKEY *pkey = NULL;
    EVP_PKEY_CTX *pctx = NULL;
    unsigned char sig[1024];
    size_t sig_len;
    unsigned char msg[] = "BenchmarkMessage";
    size_t msg_len = sizeof(msg);

    uint64_t cycles_keygen = 0, cycles_sign = 0, cycles_verify = 0;
    double time_keygen = 0, time_sign = 0, time_verify = 0;

    size_t pub_size = 0, priv_size = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        // --- Key Generation ---
        clock_t start_time = clock();
        uint64_t start_cycles = rdtsc();
        
        if (pkey_id == EVP_PKEY_EC) {
             // For ECDSA, we must first generate/select the curve parameters.
             pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);
             EVP_PKEY_paramgen_init(pctx);
             // Select the P-256 curve (industry standard).
             EVP_PKEY_CTX_set_ec_paramgen_curve_nid(pctx, NID_X9_62_prime256v1);
             EVP_PKEY *params = NULL;
             EVP_PKEY_paramgen(pctx, &params);
             EVP_PKEY_CTX_free(pctx);
             // Use those parameters to generate the specific key.
             pctx = EVP_PKEY_CTX_new(params, NULL);
             EVP_PKEY_keygen_init(pctx);
             EVP_PKEY_keygen(pctx, &pkey);
             EVP_PKEY_free(params);
        } else {
             pctx = EVP_PKEY_CTX_new_id(pkey_id, NULL);
             EVP_PKEY_keygen_init(pctx);
             // Set RSA specifically to 3072 bits (comparable to PQC security levels).
             if (pkey_id == EVP_PKEY_RSA) EVP_PKEY_CTX_set_rsa_keygen_bits(pctx, 3072);
             EVP_PKEY_keygen(pctx, &pkey);
        }
        cycles_keygen += (rdtsc() - start_cycles);
        time_keygen += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        if (i == 0) {
            // Measure raw key sizes by converting them to binary (DER) format.
            unsigned char *buf = NULL;
            // i2d_PUBKEY: Internal to DER format for public keys.
            pub_size = i2d_PUBKEY(pkey, &buf);
            OPENSSL_free(buf); buf = NULL;
            // i2d_PrivateKey: Internal to DER format for private keys.
            priv_size = i2d_PrivateKey(pkey, &buf);
            OPENSSL_free(buf);
        }

        // --- Signing ---
        start_time = clock();
        start_cycles = rdtsc();
        sig_len = sizeof(sig);
        // EVP_MD_CTX: A context for digest/hashing operations.
        EVP_MD_CTX *mctx = EVP_MD_CTX_new();
        // EVP_DigestSignInit/EVP_DigestSign: Performs hash + signature in one streamlined process.
        EVP_DigestSignInit(mctx, NULL, EVP_sha256(), NULL, pkey);
        EVP_DigestSign(mctx, sig, &sig_len, msg, msg_len);
        cycles_sign += (rdtsc() - start_cycles);
        time_sign += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        // --- Verification ---
        start_time = clock();
        start_cycles = rdtsc();
        EVP_MD_CTX *vctx = EVP_MD_CTX_new();
        // EVP_DigestVerifyInit/EVP_DigestVerify: Streamlined hash + signature verification.
        EVP_DigestVerifyInit(vctx, NULL, EVP_sha256(), NULL, pkey);
        EVP_DigestVerify(vctx, sig, sig_len, msg, msg_len);
        cycles_verify += (rdtsc() - start_cycles);
        time_verify += (double)(clock() - start_time) / CLOCKS_PER_SEC;

        EVP_PKEY_free(pkey); pkey = NULL;
        EVP_PKEY_CTX_free(pctx); pctx = NULL;
        EVP_MD_CTX_free(mctx);
        EVP_MD_CTX_free(vctx);
    }

    printf("    \"%s\": {\n", alg_name);
    printf("        \"type\": \"SIG\",\n");
    printf("        \"iterations\": %d,\n", ITERATIONS);
    printf("        \"sizes\": {\"public_key\": %zu, \"secret_key\": %zu, \"signature\": %zu},\n", 
           pub_size, priv_size, sig_len);
    printf("        \"keygen\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_keygen / ITERATIONS, (time_keygen / ITERATIONS) * 1000);
    printf("        \"sign\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f},\n", cycles_sign / ITERATIONS, (time_sign / ITERATIONS) * 1000);
    printf("        \"verify\": {\"mean_cycles\": %lu, \"mean_ms\": %.3f}\n", cycles_verify / ITERATIONS, (time_verify / ITERATIONS) * 1000);
    printf("    },\n");
}

int main() {
    printf("{\n");
    printf("\"timestamp\": \"%ld\",\n", time(NULL));
    printf("\"results\": {\n");

    // Classical benchmarks (using OpenSSL)
    benchmark_classical_kem_x25519();
    benchmark_classical_sig("RSA-3072", EVP_PKEY_RSA);
    // benchmark_classical_sig("ECDSA-P256", EVP_PKEY_EC);

    // Post-Quantum KEMs (using liboqs)
    for (size_t i = 0; i < OQS_KEM_alg_count(); i++) {
        const char *alg = OQS_KEM_alg_identifier(i);
        if (strstr(alg, "ML-KEM")) {
            benchmark_kem(alg);
        }
    }

    // Post-Quantum Signatures (using liboqs)
    for (size_t i = 0; i < OQS_SIG_alg_count(); i++) {
        const char *alg = OQS_SIG_alg_identifier(i);
        if (strstr(alg, "ML-DSA")) {
            benchmark_sig(alg);
        }
    }
    
    // Quick hack to close JSON correctly by adding a dummy "end" object.
    printf("    \"_end\": {}\n"); 
    printf("}\n");
    printf("}\n");

    return 0;
}
