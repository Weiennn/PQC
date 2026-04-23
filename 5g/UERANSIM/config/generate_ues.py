import re
import os

def generate_ues(template_file, count):
    if not os.path.exists(template_file):
        print(f"Error: Template file {template_file} not found.")
        return

    with open(template_file, 'r') as f:
        content = f.read()

    # Find the base values using regex
    # supi: 'imsi-999700000000001'
    supi_match = re.search(r"supi: 'imsi-(\d+)'", content)
    # imei: '356938035643803'
    imei_match = re.search(r"imei: '(\d+)'", content)
    # key: '465B5CE8B199B49FAA5F0A2EE238A6BC'
    key_match = re.search(r"key: '([0-9A-F]+)'", content)

    if not supi_match or not imei_match or not key_match:
        print("Could not find SUPI, IMEI or Key in template")
        return

    base_supi_str = supi_match.group(1)
    base_imei_str = imei_match.group(1)
    base_key_str = key_match.group(1)

    base_supi = int(base_supi_str)
    base_imei = int(base_imei_str)
    base_key_int = int(base_key_str, 16)

    # Padding lengths to maintain format
    supi_len = len(base_supi_str)
    imei_len = len(base_imei_str)

    print(f"Generating 9 additional UEs based on {template_file}...")

    for i in range(1, count + 1):
        # Increment values
        new_supi_val = base_supi + i
        new_imei_val = base_imei + i
        new_key_val = base_key_int + i

        # Format strings with leading zeros
        new_supi = str(new_supi_val).zfill(supi_len)
        new_imei = str(new_imei_val).zfill(imei_len)
        new_key = hex(new_key_val)[2:].upper().zfill(32)

        # Replace in content
        new_content = content
        new_content = new_content.replace(f"imsi-{base_supi_str}", f"imsi-{new_supi}")
        new_content = new_content.replace(f"imei: '{base_imei_str}'", f"imei: '{new_imei}'")
        new_content = new_content.replace(f"key: '{base_key_str}'", f"key: '{new_key}'")

        output_file = f"open5gs-ue{i}.yaml"
        # Join with directory of template
        dir_name = os.path.dirname(template_file)
        full_output_path = os.path.join(dir_name, output_file)

        with open(full_output_path, 'w') as f:
            f.write(new_content)
        print(f"  - Created: {output_file} (SUPI: imsi-{new_supi}, IMEI: {new_imei})")

if __name__ == "__main__":
    # Current directory is assumed to be where the config files are or absolute path
    template = "/home/vboxuser/Desktop/PQC/5g/UERANSIM/config/open5gs-ue0.yaml"
    generate_ues(template, 9)
