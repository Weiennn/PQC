import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import json
import glob
import os

data = {}

# Find all json benchmark files in the current directory
json_files = glob.glob('bench_*.json')

# Process files and keep the most recent data for each KEM algorithm
for f in json_files:
    try:
        with open(f, 'r') as file:
            file_data = json.load(file)
            timestamp = int(file_data.get('timestamp', 0))
            results = file_data.get('results', {})
            
            for alg, metrics in results.items():
                if alg == '_end':
                    continue
                # We only want KEMs for latency/size comparison
                if metrics.get('type') != 'KEM':
                    continue
                
                if alg not in data or data[alg]['timestamp'] < timestamp:
                    if 'sizes' in metrics and 'keygen' in metrics and 'encaps' in metrics and 'decaps' in metrics:
                        data[alg] = {
                            'timestamp': timestamp,
                            'sizes': metrics['sizes'],
                            'keygen': metrics['keygen']['mean_ms'],
                            'encaps': metrics['encaps']['mean_ms'],
                            'decaps': metrics['decaps']['mean_ms']
                        }
    except Exception as e:
        print(f"Error reading {f}: {e}")

# Preferred order for the plotting
preferred_order = ["X25519", "ML-KEM-512", "ML-KEM-768", "ML-KEM-1024", "X25519MLKEM768"]
algorithms = []
for alg in preferred_order:
    if alg in data:
        algorithms.append(alg)
for alg in data.keys():
    if alg not in algorithms:
        algorithms.append(alg)

# --- Plot 1: Latency ---
keygen_latency = [data[alg]['keygen'] for alg in algorithms]
encaps_latency = [data[alg]['encaps'] for alg in algorithms]
decaps_latency = [data[alg]['decaps'] for alg in algorithms]

x = np.arange(len(algorithms))
width = 0.25

plt.figure(figsize=(10, 6))
plt.bar(x - width, keygen_latency, width, label='Keygen')
plt.bar(x, encaps_latency, width, label='Encaps')
plt.bar(x + width, decaps_latency, width, label='Decaps')

plt.xlabel('Algorithm')
plt.ylabel('Mean Latency (ms)')
plt.title('KEM Latency Comparison')
plt.xticks(x, algorithms)
plt.legend()
plt.grid(axis='y', linestyle='--', alpha=0.7)
plt.tight_layout()
plt.savefig('latency_comparison.png')
plt.close()

# --- Plot 2: Sizes ---
pk_size = [data[alg]['sizes']['public_key'] for alg in algorithms]
sk_size = [data[alg]['sizes']['secret_key'] for alg in algorithms]
ct_size = [data[alg]['sizes']['ciphertext'] for alg in algorithms]

width = 0.2

plt.figure(figsize=(12, 6))
plt.bar(x - 1.5*width, pk_size, width, label='Public Key')
plt.bar(x - 0.5*width, sk_size, width, label='Secret Key')
plt.bar(x + 0.5*width, ct_size, width, label='Ciphertext')

plt.xlabel('Algorithm')
plt.ylabel('Size (bytes)')
plt.title('Cryptographic Object Sizes')
plt.xticks(x, algorithms)
plt.legend()
plt.grid(axis='y', linestyle='--', alpha=0.7)
plt.tight_layout()
plt.savefig('object_sizes.png')
plt.close()

# Save data to CSV for user reference
latency_df = pd.DataFrame({
    'Algorithm': algorithms,
    'Keygen (ms)': keygen_latency,
    'Encaps (ms)': encaps_latency,
    'Decaps (ms)': decaps_latency
})

sizes_df = pd.DataFrame({
    'Algorithm': algorithms,
    'Public Key (bytes)': pk_size,
    'Secret Key (bytes)': sk_size,
    'Ciphertext (bytes)': ct_size,
})

latency_df.to_csv('kem_latency_data.csv', index=False)
sizes_df.to_csv('kem_sizes_data.csv', index=False)