STATUS=0

# check message length
if compgen -G $GITHUB_WORKSPACE/*/messages >/dev/null; then
for message in $GITHUB_WORKSPACE/*/messages/*; do
len=$(wc -m < $message)
echo -e "$message\t$len"
if ((($len < 1)) && [ ! -e ${message/messages/embeds} ] ) || (($len > 2000)); then
    echo "::error file=$message::Length of message ($len) out of allowed bounds."
    STATUS=1
fi
done
fi

# verify embed formatting
if compgen -G $GITHUB_WORKSPACE/*/embeds >/dev/null; then
for embed in $GITHUB_WORKSPACE/*/embeds/*; do
error=$(
    set -o pipefail
    { jq -ncj --slurpfile embeds $embed '{embeds:$embeds}' |
    perl -e '$json = <>; $json =~ s/<\{\{ (.+?) \}\}>/`cat $1 | jq -sR | head -c -3 | tail -c +2`/ge; print $json' |
    jq; } 2>&1
)
if [[ "$?" != "0" ]]; then
    echo "::error file=$embed::$error"
    STATUS=1
fi
done
fi

# verify all webhooks have associated secrets
readarray DEFINED_WEBHOOKS < <(yq '.jobs.update-webhooks.steps[] | select(.name == "Execute webhooks").env' .github/workflows/webhooks.yml)
for webhook in $GITHUB_WORKSPACE/*/; do
webhook=$(basename "$webhook")
if ! printf "%s\n" "${DEFINED_WEBHOOKS[@]}" | grep --quiet "^${webhook}_WEBHOOK"; then
    echo "::error ::$webhook missing secret in \`webhooks.yml\`."
    STATUS=1
fi
done

exit $STATUS