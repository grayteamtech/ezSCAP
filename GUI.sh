Please edit the following code to make the style of the GUI a modern gray hacker color with green font and have the title of each GUI display saying ezSCAP: #!/usr/bin/env bash
set -euo pipefail

# 1. Root, Dependency, & Zenity Checks
if [[ $EUID -ne 0 ]]; then
    zenity --error --title="Error" --text="This script must be run as root."
    exit 1
fi

if ! command -v oscap &>/dev/null; then
    zenity --error --title="Error" --text="'oscap' missing.\nRun: dnf install openscap-scanner scap-security-guide"
    exit 1
fi

if ! command -v zenity &>/dev/null; then
    echo "Error: 'zenity' is required for the GUI version." >&2
    exit 1
fi

SSG_FILE="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
if [[ ! -f "$SSG_FILE" ]]; then
    zenity --error --title="Error" --text="Data stream missing at:\n$SSG_FILE"
    exit 1
fi

# 2. Benchmark Selection via GUI Radio List
BENCHMARK_CHOICE=$(zenity --list --title="OpenSCAP Scanner" \
    --text="Select security benchmark:" \
    --column="Select" --column="ID" --column="Benchmark Name" \
    --radiolist TRUE "1" "DISA STIG" \
    FALSE "2" "HIPAA" \
    FALSE "3" "CIS (L2)" \
    FALSE "4" "PCI-DSS" \
    FALSE "5" "Custom Profile" \
    --width=450 --height=300 || echo "CANCELLED")

if [[ "$BENCHMARK_CHOICE" == "CANCELLED" || -z "$BENCHMARK_CHOICE" ]]; then
    exit 0
fi

case "$BENCHMARK_CHOICE" in
    1) PROFILE_ID="xccdf_org.ssgproject.content_profile_stig"; BENCHMARK_NAME="DISA STIG" ;;
    2) PROFILE_ID="xccdf_org.ssgproject.content_profile_hipaa"; BENCHMARK_NAME="HIPAA" ;;
    3) PROFILE_ID="xccdf_org.ssgproject.content_profile_cis"; BENCHMARK_NAME="CIS" ;;
    4) PROFILE_ID="xccdf_org.ssgproject.content_profile_pci-dss"; BENCHMARK_NAME="PCI-DSS" ;;
    5) 
        PROFILE_ID=$(zenity --entry --title="Custom Profile" --text="Enter full Profile ID:" --entry-text="xccdf_org.ssgproject.content_profile_")
        [[ -z "$PROFILE_ID" ]] && exit 0
        BENCHMARK_NAME="Custom"
        ;;
    *) zenity --error --title="Error" --text="Invalid choice."; exit 1 ;;
esac

# 3. Scan Mode Selection
MODE_CHOICE=$(zenity --list --title="Scan Mode" \
    --text="Select scan execution mode:" \
    --column="Select" --column="ID" --column="Mode Description" \
    --radiolist TRUE "1" "Regular Scan (Audit only)" \
    FALSE "2" "Remediation Scan (Audit AND auto-fix)" \
    --width=450 --height=240 || echo "CANCELLED")

if [[ "$MODE_CHOICE" == "CANCELLED" || -z "$MODE_CHOICE" ]]; then
    exit 0
fi

REMEDIATE_FLAG=""
if [[ "$MODE_CHOICE" == "2" ]]; then
    REMEDIATE_FLAG="--remediate"
    zenity --warning --title="Warning" --text="Remediation mode is enabled and will modify system configurations."
elif [[ "$MODE_CHOICE" != "1" ]]; then
    zenity --error --title="Error" --text="Invalid mode choice."
    exit 1
fi

# 4. Path Setup & Real-time Live Progress Execution
XML_PATH=$(zenity --entry --title="Results Path" --text="Enter XML results file path:" --entry-text="/var/log/scan-results.xml")
[[ -z "$XML_PATH" ]] && exit 0
mkdir -p "$(dirname "$XML_PATH")"

set +e
# Stream oscap output into Zenity progress bar so it displays live status updates
(
    oscap xccdf eval $REMEDIATE_FLAG --profile "$PROFILE_ID" --results "$XML_PATH" "$SSG_FILE" 2>&1 | while IFS= read -r line; do
        # Lines prefixed with '#' update Zenity's progress text label
        echo "# $line"
    done
) | zenity --progress --title="OpenSCAP Scanner" --text="Initializing $BENCHMARK_NAME scan..." --pulsate --auto-close --width=550 --height=160
SCAN_EXIT_CODE=${PIPESTATUS[0]}
set -e

if [[ $SCAN_EXIT_CODE -eq 0 || $SCAN_EXIT_CODE -eq 2 ]]; then
    zenity --info --title="Scan Complete" --text="Scan finished successfully.\nResults saved to: $XML_PATH"
else
    zenity --error --title="Scan Error" --text="Scan failed with exit code $SCAN_EXIT_CODE."
    exit "$SCAN_EXIT_CODE"
fi

# 5. Optional HTML Report Generation
if zenity --question --title="HTML Report" --text="Would you like to generate an HTML report?"; then
    HTML_PATH=$(zenity --entry --title="HTML Report Path" --text="Enter HTML report file path:" --entry-text="/var/log/scan-report.html")
    if [[ -n "$HTML_PATH" ]]; then
        mkdir -p "$(dirname "$HTML_PATH")"
        if oscap xccdf generate report "$XML_PATH" > "$HTML_PATH"; then
            zenity --info --title="Report Generated" --text="HTML report successfully generated:\n$HTML_PATH"
        else
            zenity --error --title="Error" --text="Failed to generate HTML report."
        fi
    fi
fi

# 6. Parse XML Results for Summary Totals
PASSED_COUNT=$(grep -c '<result>pass</result>' "$XML_PATH" || true)
FAILED_COUNT=$(grep -c '<result>fail</result>' "$XML_PATH" || true)
FIXED_COUNT=$(grep -c '<result>fixed</result>' "$XML_PATH" || true)

# 7. Compile Summary Text
SUMMARY_TEXT="Scan Summary ($BENCHMARK_NAME):\n\n• Passed: $PASSED_COUNT\n• Failed: $FAILED_COUNT"
if [[ "$MODE_CHOICE" == "2" ]]; then
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
zenity --text-info --title="Scan Results Summary" --filename=<(echo -e "$SUMMARY_TEXT") --width=500 --height=400
