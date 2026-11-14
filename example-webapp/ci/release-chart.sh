#!/bin/sh
# Publica o chart da webapp no ChartMuseum com a nova imagem (change gitops-deploy)
# Requer: CHART_DIR, CHARTMUSEUM_URL, IMAGE_TAG; helm instalado.
set -eu
CHART_DIR="${CHART_DIR:?CHART_DIR ausente}"
CHARTMUSEUM_URL="${CHARTMUSEUM_URL:?CHARTMUSEUM_URL ausente}"
IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG ausente}"

# bump de versao patch no Chart.yaml (deterministico)
OLD=$(grep '^version:' "$CHART_DIR/Chart.yaml" | awk '{print $2}')
NEW=$(echo "$OLD" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')
sed -i.bak "s/^version: .*/version: $NEW/" "$CHART_DIR/Chart.yaml" && rm -f "$CHART_DIR/Chart.yaml.bak"
# tag da imagem nova no values.yaml
sed -i.bak "s/^  tag: .*/  tag: $IMAGE_TAG/" "$CHART_DIR/values.yaml" && rm -f "$CHART_DIR/values.yaml.bak"

mkdir -p "$CHART_DIR/dist"
helm package "$CHART_DIR" -d "$CHART_DIR/dist" >/dev/null
TGZ=$(ls "$CHART_DIR/dist/*.tgz" | head -1)
echo "publicando $TGZ no ChartMuseum"
curl -sf --data-binary "@$TGZ" "$CHARTMUSEUM_URL/api/charts" >/dev/null
echo "CHART_VERSION=$NEW"
