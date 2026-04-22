import csv
import sys
import os
import glob
import matplotlib.pyplot as plt
import numpy as np

# Try to find the latest CSV if one isn't provided
csv_file = sys.argv[1] if len(sys.argv) > 1 else None
if not csv_file:
    list_of_files = glob.glob('benchmark_summary_*.csv')
    if not list_of_files:
        print("No CSV files found.")
        sys.exit(1)
    csv_file = max(list_of_files, key=os.path.getctime)

print(f"Plotting data from {csv_file}...")

data = {}

# Read data
with open(csv_file, 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        sig = row['SigAlg']
        kem = row['KEM']
        try:
            latency_val = float(row['Latency_ms'])
        except ValueError:
            latency_val = 0.0
        
        if sig not in data:
            data[sig] = {}
        data[sig][kem] = latency_val

# Get ordered signature algorithms (based on appearance in file)
sig_algs = []
with open(csv_file, 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        if row['SigAlg'] not in sig_algs:
            sig_algs.append(row['SigAlg'])

# The user requested specific ordering for the KEMs (Key algos)
kem_order = ['X25519', 'ML-KEM-512', 'ML-KEM-768', 'ML-KEM-1024', 'X25519-ML-KEM-768']

# Setup plotting
x = np.arange(len(sig_algs))  # Label locations
width = 0.15 # Width of the bars

fig, ax = plt.subplots(figsize=(14, 7))

# Distinct colors for each KEM
colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', '#9467bd']

# Plot bars for each KEM algorithm
for i, kem in enumerate(kem_order):
    latency_times = []
    for sig in sig_algs:
        latency_times.append(data.get(sig, {}).get(kem, 0.0))
        
    # Calculate offset for grouped bar effect
    offset = (i - len(kem_order) / 2) * width + width / 2
    offset_x = x + offset
    
    rects = ax.bar(offset_x, latency_times, width, label=kem, color=colors[i % len(colors)])
    # Add labels on top of bars
    ax.bar_label(rects, padding=3, fmt='%.1f', fontsize=8, rotation=90)

# Add text, labels, and customizations
ax.set_ylabel('Latency (ms)')
ax.set_xlabel('Signing Algorithms')
ax.set_title(f'TLS Connection Latency by Signature and KEM Algorithm\n({os.path.basename(csv_file)})')
ax.set_xticks(x)
ax.set_xticklabels(sig_algs)

# Put legend outside the plot area
ax.legend(title='Key Algorithms', bbox_to_anchor=(1.05, 1), loc='upper left')

plt.xticks(rotation=45)
ax.set_axisbelow(True)
ax.yaxis.grid(color='gray', linestyle='dashed', alpha=0.3)

fig.tight_layout()

# Save image instead of showing blocking window, in case it's run unattended
output_file = 'benchmark_Latency_plot.png'
plt.savefig(output_file, dpi=300, bbox_inches='tight')
print(f"Plot saved to {output_file}")
