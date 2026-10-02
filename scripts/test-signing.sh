#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
signing_test_dir=$(mktemp -d "$PWD/.build/signing-test.XXXXXX")
trap 'rm -rf "$signing_test_dir"' EXIT
print 'int main(void) { return 0; }' > "$signing_test_dir/first.c"
print 'int main(void) { return 1; }' > "$signing_test_dir/second.c"
/usr/bin/cc "$signing_test_dir/first.c" -o "$signing_test_dir/first"
/usr/bin/cc "$signing_test_dir/second.c" -o "$signing_test_dir/second"
for candidate in first second; do
    ./scripts/local-signing.sh --sign "$signing_test_dir/$candidate"
    /usr/bin/codesign --verify --strict "$signing_test_dir/$candidate"
    /usr/bin/codesign -d -r- "$signing_test_dir/$candidate" 2>&1 \
        | /usr/bin/sed -n -E 's/^#? *designated => //p' > "$signing_test_dir/$candidate.requirement"
    /usr/bin/codesign -d --verbose=4 "$signing_test_dir/$candidate" 2>&1 \
        | /usr/bin/awk -F= '/^CDHash=/ {print $2}' > "$signing_test_dir/$candidate.hash"
done
[[ -s "$signing_test_dir/first.requirement" ]] || { echo "FAIL: designated requirement was missing." >&2; exit 1; }
/usr/bin/cmp -s "$signing_test_dir/first.requirement" "$signing_test_dir/second.requirement"
[[ -s "$signing_test_dir/first.hash" ]] || { echo "FAIL: code hash was missing." >&2; exit 1; }
if /usr/bin/cmp -s "$signing_test_dir/first.hash" "$signing_test_dir/second.hash"; then
    echo "FAIL: signing check must use different code hashes." >&2
    exit 1
fi
echo "PASS: different compiled binaries have valid signatures and the same certificate-bound signing requirement."
