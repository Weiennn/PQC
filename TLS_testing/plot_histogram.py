import os
import glob
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

def main():
    # Find the latest latency_finegrained file
    files = glob.glob('/home/vboxuser/Desktop/PQC/latency_finegrained_*.csv')
    if not files:
        print("No latency_finegrained_*.csv files found.")
        return

    latest_file = max(files, key=os.path.getctime)
    print(f"Reading from {latest_file}...")

    df = pd.read_csv(latest_file)

    # Calculate total CPU time
    if 'UserCPU_ms' in df.columns and 'SysCPU_ms' in df.columns:
        df['TotalCPU_ms'] = df['UserCPU_ms'] + df['SysCPU_ms']
    else:
        print("Missing CPU columns")
        return

    if 'SigAlg' not in df.columns:
        print(f"Error: 'SigAlg' column not found in {latest_file}")
        print("Columns found:", df.columns)
        return

    sig_algos = df['SigAlg'].unique()

    # Set the style for seaborn
    sns.set_theme(style="whitegrid")

    for sig in sig_algos:
        plt.figure(figsize=(12, 7))
        
        # Filter for current SigAlg
        subset = df[df['SigAlg'] == sig]
        
        # Create histogram with KDE, grouped by KEM
        sns.histplot(
            data=subset,
            x='TotalCPU_ms',
            hue='KEM',
            element='step',
            stat='density',
            common_norm=False,
            kde=True,
            alpha=0.4,
            linewidth=1.5
        )
        
        plt.title(f'Total CPU Usage Distribution for Signature Algo: {sig}', fontsize=16, pad=15)
        plt.xlabel('Total CPU Usage (ms)', fontsize=14)
        plt.ylabel('Density', fontsize=14)
        plt.xticks(fontsize=12)
        plt.yticks(fontsize=12)
        plt.tight_layout()
        
        # Save plot
        safe_sig_name = sig.replace(':', '_').replace('-', '_')
        filename = f"/home/vboxuser/Desktop/PQC/histogram_cpu_{safe_sig_name}.png"
        plt.savefig(filename, dpi=300, bbox_inches='tight')
        print(f"Saved plot: {filename}")
        plt.close()

if __name__ == "__main__":
    main()
