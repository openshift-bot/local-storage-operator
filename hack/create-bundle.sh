#!/bin/sh

# A hackish script to build bundle and file-based catalog images for the given images.
# The output is available in opm-bundle directory.

set -o nounset
set -o pipefail

if [ "$#" -ne "4" ]; then
    echo "Usage: $0 <input_operator_image> <input_diskmaker_image> <output_bundle_image> <output_index_image>"
    exit 1
fi

DEFAULT_TOOL_BIN=$(which podman 2>/dev/null || which docker 2>/dev/null)
if [ "$?" -ne "0" ]; then
	echo "Error: No suitable container manipulation tool (podman, docker) found in \$PATH" 1>&2
	exit 1
fi
TOOL_BIN=${TOOL_BIN:-$DEFAULT_TOOL_BIN}

OPM_BIN=$(which opm 2>/dev/null)
if [ "$?" -ne "0" ]; then
	echo "Error: opm is not found in \$PATH" 1>&2
	exit 1
fi

set -o errexit

OPERATOR_IMAGE=$1
DISKMAKER_IMAGE=$2
BUNDLE_IMAGE=$3
INDEX_IMAGE=$4

# Prepare output dir
[ ! -d opm-bundle ] || rm -r opm-bundle # start clean
mkdir -p opm-bundle
pushd opm-bundle
cp -r -v ../config/* .

MANIFEST=manifests/stable/local-storage-operator.clusterserviceversion.yaml
BUNDLE_NAME=$(sed -n 's/^[[:space:]]*name:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' $MANIFEST | head -n 1)
SKIP_RANGE=$(sed -n 's/^[[:space:]]*olm\.skipRange:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' $MANIFEST)

if [ -z "$BUNDLE_NAME" ]; then
	echo "Error: Unable to determine bundle name from $MANIFEST" 1>&2
	exit 1
fi

# Replace images in the manifest - error prone, needs to be in sync with image-references.
sed -i.bak -e "s~quay.io/openshift/origin-local-storage-operator:latest~$OPERATOR_IMAGE~" \
	-e "s~quay.io/openshift/origin-local-storage-diskmaker:latest~$DISKMAKER_IMAGE~" \
	$MANIFEST
rm $MANIFEST.bak

# Build the bundle and push it
$TOOL_BIN build -t $BUNDLE_IMAGE -f bundle.Dockerfile .
$TOOL_BIN push $BUNDLE_IMAGE

# Generate a file-based catalog with the development-only preview channel.
CATALOG_DIR=catalog
CATALOG=$CATALOG_DIR/catalog.yaml
mkdir -p $CATALOG_DIR
cat > $CATALOG <<EOF
---
schema: olm.package
name: local-storage-operator
defaultChannel: preview
---
schema: olm.channel
package: local-storage-operator
name: preview
entries:
  - name: $BUNDLE_NAME
EOF

if [ -n "$SKIP_RANGE" ]; then
	printf '    skipRange: "%s"\n' "$SKIP_RANGE" >> $CATALOG
fi

$OPM_BIN render $BUNDLE_IMAGE --output yaml >> $CATALOG
$OPM_BIN validate $CATALOG_DIR
$OPM_BIN generate dockerfile $CATALOG_DIR

# Build the catalog image and push it
$TOOL_BIN build -t $INDEX_IMAGE -f $CATALOG_DIR.Dockerfile .
$TOOL_BIN push $INDEX_IMAGE


echo
echo --------------------
echo "File-based catalog image created"
echo "Copy following snippet to apply it to your cluster"
echo

# Show oc apply -f - <<EOF to copy-paste into shell
cat <<REAL_EOF
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: local-storage
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $INDEX_IMAGE
EOF
REAL_EOF

echo

popd
