# TangoDisplay — Dev Notes

## GitHub Releases

Create releases via the GitHub API using the token stored in the macOS keychain:

```bash
TOKEN=$(security find-internet-password -s github.com -w)
```

**Step 1 — Create the release:**
```bash
RELEASE=$(curl -s -X POST \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/repos/richardsladetdj-creator/TangoDisplay/releases \
  -d "{\"tag_name\":\"vX.Y.Z\",\"name\":\"vX.Y.Z\",\"body\":\"release notes\",\"draft\":false,\"prerelease\":false}")

UPLOAD_URL=$(echo "$RELEASE" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['upload_url'].split('{')[0])")
```

**Step 2 — Upload the zip asset:**
```bash
curl -s -X POST \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Content-Type: application/zip" \
  --data-binary @TangoDisplay-vX.Y.Z-universal.zip \
  "${UPLOAD_URL}?name=TangoDisplay-vX.Y.Z-universal.zip"
```

## Release workflow

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Install.sh`
2. Commit and push
3. Run `bash Install.sh` to build the universal binary and install
4. Zip: `ditto -c -k --sequesterRsrc --keepParent TangoDisplay.app TangoDisplay-vX.Y.Z-universal.zip`
5. Create GitHub release and upload zip via API (above)
