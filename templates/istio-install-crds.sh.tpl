#!/bin/bash
# Script to install Istio CRDs in chunks to prevent timeout issues

echo "Installing Istio CRDs for version ${version}..."

# Create a temporary directory for CRD chunking
TEMP_DIR=$(mktemp -d)
CRD_URL="https://raw.githubusercontent.com/istio/istio/refs/tags/${version}/manifests/charts/base/files/crd-all.gen.yaml"

# Download the CRDs
echo "Downloading CRDs from $CRD_URL"
curl -sSL $CRD_URL > $TEMP_DIR/crd-all.yaml

# Split the CRDs into multiple files (one CRD per file)
echo "Splitting CRDs into individual files..."
cd $TEMP_DIR
csplit -z -f crd- crd-all.yaml '/^---$/' '{*}' > /dev/null

# Apply each CRD separately with retries
echo "Applying CRDs with retries..."
for crd in crd-*; do
  # Some empty files might be created, skip them
  if [ -s "$crd" ]; then
    echo "Applying $crd"
    for i in {1..3}; do
      if kubectl apply --server-side -f $crd; then
        echo "Successfully applied $crd"
        break
      else
        echo "Failed to apply $crd, retry $i/3"
        sleep 3
        if [ $i -eq 3 ]; then
          echo "WARNING: Failed to apply $crd after 3 attempts"
        fi
      fi
    done
  fi
done

echo "All Istio CRDs installation completed"
rm -rf $TEMP_DIR