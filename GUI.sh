Here is the updated script incorporating a modern dark gray hacker theme with vibrant green text, solid background styling, ezSCAP as the title across all GUI dialogs, dropdown menus for benchmark and mode selections, and updated progress bar text:
#!/usr/bin/env bash
set -euo pipefail

# Setup modern gray hacker theme with green font for Zenity/GTK3
GTK_THEME_DIR="/tmp/ezscap-gtk/share/themes/ezscap-dark/gtk-3.0"
mkdir -p "$GTK_THEME_DIR"
cat << 'EOF' > "$GTK_THEME_DIR/gtk.css"
@define-color bg_color #1a1a1a;
@define-color fg_color #00ff00;
@define-color base_color #121212;
@define-color text_color #00ff00;
@define-color selected_bg_color #003300;
@define-color selected_fg_color #00ff00;

window {
    background-color: #1a1a1a;
    color: #00ff00;
}

label, textview, entry, button, list, treeview, checkbutton, combobox {
    color: #00ff00;
    background-color: #1a1a1a;
}

entry, textview text, combobox window {
    background-color: #121212;
    color: #00ff00;
    border: 1px solid #00ff00;
}

button {
    background-color: #262626;
    color: #00ff00;
    border: 1px solid #00ff00;
}

button:hover {
    background-color: #003300;
    color: #00ff00;
}
EOF

export GTK_DATA_PREFIX="/tmp/ezscap-gtk"
export GTK_THEME="ezscap-dark"

# 1. Root, Dependency, & Zenity Checks
if [[ $EUID -ne 0 ]]; then
    zenity --error --title="ezSCAP" --text="This script must be run as root."
    exit 1
fi

if ! command -v oscap &>/dev/null; then
    zenity --error --title="ezSCAP" --text="'oscap' missing.\nRun: dnf install openscap-scanner scap-security-guide"
    exit 1
fi

if ! command -v zenity &>/dev/null; then
    echo "Error: 'zenity' is required for the GUI version." >&2
    exit 1
fi

SSG_FILE="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
if [[ ! -f "$SSG_FILE" ]]; then
    zenity --error --title="ezSCAP" --text="Data stream missing at:\n$SSG_FILE"
    exit 1
fi

# 2. Benchmark Selection via Dropdown Menu
BENCHMARK_CHOICE=$(zenity --forms --title="ezSCAP" \
    --text="Select security benchmark:" \
    --add-combo="Benchmark" --combo-values="DISA STIG|HIPAA|CIS (L2)|PCI-DSS|Custom Profile" \
    --width=450 --height=200 || echo "CANCELLED")

if [[ "$BENCHMARK_CHOICE" == "CANCELLED" || -z "$BENCHMARK_CHOICE" ]]; then
    exit 0
fi

BENCHMARK_CHOICE=$(echo "$BENCHMARK_CHOICE" | tr -d '|')

case "$BENCHMARK_CHOICE" in
    "DISA STIG") PROFILE_ID="xccdf_org.ssgproject.content_profile_stig"; BENCHMARK_NAME="DISA STIG" ;;
    "HIPAA") PROFILE_ID="xccdf_org.ssgproject.content_profile_hipaa"; BENCHMARK_NAME="HIPAA" ;;
    "CIS (L2)") PROFILE_ID="xccdf_org.ssgproject.content_profile_cis"; BENCHMARK_NAME="CIS" ;;
    "PCI-DSS") PROFILE_ID="xccdf_org.ssgproject.content_profile_pci-dss"; BENCHMARK_NAME="PCI-DSS" ;;
    "Custom Profile") 
        PROFILE_ID=$(zenity --entry --title="ezSCAP" --text="Enter full Profile ID:" --entry-text="xccdf_org.ssgproject.content_profile_")
        [[ -z "$PROFILE_ID" ]] && exit 0
        BENCHMARK_NAME="Custom"
        ;;
    *) zenity --error --title="ezSCAP" --text="Invalid choice."; exit 1 ;;
esac

# 3. Scan Mode Selection via Dropdown Menu
MODE_CHOICE=$(zenity --forms --title="ezSCAP" \
    --text="Select scan execution mode:" \
    --add-combo="Scan Mode" --combo-values="Regular Scan (Audit only)|Remediation Scan (Audit AND auto-fix)" \
    --width=450 --height=200 || echo "CANCELLED")

if [[ "$MODE_CHOICE" == "CANCELLED" || -z "$MODE_CHOICE" ]]; then
    exit 0
fi

MODE_CHOICE=$(echo "$MODE_CHOICE" | tr -d '|')

REMEDIATE_FLAG=""
if [[ "$MODE_CHOICE" == "Remediation Scan (Audit AND auto-fix)" ]]; then
    REMEDIATE_FLAG="--remediate"
    zenity --warning --title="ezSCAP" --text="Remediation mode is enabled and will modify system configurations."
elif [[ "$MODE_CHOICE" != "Regular Scan (Audit only)" ]]; then
    zenity --error --title="ezSCAP" --text="Invalid mode choice."
    exit 1
fi

# 4. Path Setup & Real-time Live Progress Execution
XML_PATH=$(zenity --entry --title="ezSCAP" --text="Enter XML results file path:" --entry-text="/var/log/scan-results.xml")
[[ -z "$XML_PATH" ]] && exit 0
mkdir -p "$(dirname "$XML_PATH")"

set +e
# Stream oscap output into Zenity progress bar so it displays live status updates
(
    oscap xccdf eval $REMEDIATE_FLAG --profile "$PROFILE_ID" --results "$XML_PATH" "$SSG_FILE" 2>&1 | while IFS= read -r line; do
        # Lines prefixed with '#' update Zenity's progress text label
        echo "# $line"
    done
) | zenity --progress --title="ezSCAP" --text="Conducting Scan..." --pulsate --auto-close --width=550 --height=160
SCAN_EXIT_CODE=${PIPESTATUS[0]}
set -e

if [[ $SCAN_EXIT_CODE -eq 0 || $SCAN_EXIT_CODE -eq 2 ]]; then
    zenity --info --title="ezSCAP" --text="Scan finished successfully.\nResults saved to: $XML_PATH"
else
    zenity --error --title="ezSCAP" --text="Scan failed with exit code $SCAN_EXIT_CODE."
    exit "$SCAN_EXIT_CODE"
fi

# 5. Optional HTML Report Generation
if zenity --question --title="ezSCAP" --text="Would you like to generate an HTML report?"; then
    HTML_PATH=$(zenity --entry --title="ezSCAP" --text="Enter HTML report file path:" --entry-text="/var/log/scan-report.html")
    if [[ -n "$HTML_PATH" ]]; then
        mkdir -p "$(dirname "$HTML_PATH")"
        if oscap xccdf generate report "$XML_PATH" > "$HTML_PATH"; then
            zenity --info --title="ezSCAP" --text="HTML report successfully generated:\n$HTML_PATH"
        else
            zenity --error --title="ezSCAP" --text="Failed to generate HTML report."
        fi
    fi
fi

# 6. Parse XML Results for Summary Totals
PASSED_COUNT=$(grep -c '<result>pass</result>' "$XML_PATH" || true)
FAILED_COUNT=$(grep -c '<result>fail</result>' "$XML_PATH" || true)
FIXED_COUNT=$(grep -c '<result>fixed</result>' "$XML_PATH" || true)

# 7. Compile Summary Text
SUMMARY_TEXT="Scan Summary ($BENCHMARK_NAME):\n\n• Passed: $PASSED_COUNT\n• Failed: $FAILED_COUNT"
if [[ "$MODE_CHOICE" == "Remediation Scan (Audit AND auto-fix)" ]]; then
    SUMMARY_TEXT+="\n• Fixed: $FIXED_COUNT"
fi

# 8. Extract Failed CCE Numbers if any
FAILED_CCES=""
if [[ "$FAILED_COUNT" -gt 0 ]]; then
    FAILED_CCES=$(python3 - "$XML_PATH" << 'EOF'
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
try:
    tree = ET.parse(xml_path)
    root = tree.getroot()
    
    cce_list = []
    for elem in root.iter():
        if elem.tag.endswith('rule-result'):
            result_elem = elem.find('{*}result')
            if result_elem is not None and result_elem.text == 'fail':
                for ident in elem.iter():
                    if ident.tag.endswith('ident'):
                        sys_attr = ident.get('system', '')
                        if 'cce' in sys_attr.lower() or (ident.text and 'CCE-' in ident.text):
                            cce_list.append(ident.text.strip())
                            break
    print("\n".join(cce_list))
except Exception:
    pass
EOF
)
    if [[ -n "$FAILED_CCES" ]]; then
        SUMMARY_TEXT+="\n\nFailed CCE Numbers:\n$FAILED_CCES"
    fi
fi

# Display Final Summary in a Scrollable Text Box
zenity --text-info --title="ezSCAP" --filename=<(echo -e "$SUMMARY_TEXT") --width=500 --height=400

