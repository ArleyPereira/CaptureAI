#!/bin/bash
# Instala a ÚNICA cópia oficial em /Applications/CaptureAI.app e reassina.
# O Xcode ainda gera o .app em DerivedData (necessário para o build), mas
# removemos esse caminho do Launch Services para o Spotlight não listar dois.
set -euo pipefail

SRC="${BUILT_PRODUCTS_DIR:?}/${FULL_PRODUCT_NAME:?}"
DEST="/Applications/CaptureAI.app"
ENTITLEMENTS="${SRCROOT:?}/CaptureAI/CaptureAI.entitlements"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "$SRC" ]]; then
  echo "error: app não encontrado em: $SRC" >&2
  exit 1
fi

rm -rf "$DEST"
/usr/bin/ditto "$SRC" "$DEST"

IDENTITY=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -z "${IDENTITY}" ]]; then
  echo "error: identidade Apple Development não encontrada" >&2
  exit 1
fi

# Reassinar é necessário: a cópia em /Applications precisa de assinatura válida
# para o launchd abrir o app (erro 163 se estiver sem assinatura).
if [[ -f "$ENTITLEMENTS" ]]; then
  /usr/bin/codesign --force --sign "${IDENTITY}" --entitlements "$ENTITLEMENTS" --timestamp=none "$DEST"
else
  /usr/bin/codesign --force --sign "${IDENTITY}" --timestamp=none "$DEST"
fi

/usr/bin/codesign --verify --deep --strict "$DEST"

# Mantém só /Applications visível no Spotlight / “Abrir”.
# DerivedData continua existindo no disco (artefato do Xcode), mas sem registro.
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
fi

echo "CaptureAI instalado (única app registrada): $DEST (${IDENTITY})"
